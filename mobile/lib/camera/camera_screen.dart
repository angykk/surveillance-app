import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api/api_client.dart';
import '../api/motion_api.dart';
import '../config.dart';
import '../motion/motion_detector.dart';
import '../webrtc/signaling_client.dart';
import 'clip_upload_queue.dart';
import 'device_credentials.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.credentials, required this.onUnpaired, required this.onSwitchMode});

  final DeviceCredentials credentials;

  /// Called when the server refuses this camera's device token — it was
  /// removed from its household in Viewer Mode — so the caller can clear
  /// the stale credentials and return to pairing.
  final VoidCallback onUnpaired;

  /// Stops the camera and returns to the mode picker. There's deliberately
  /// no back button, and system back asks first: an unattended camera
  /// shouldn't be one tap from off.
  final VoidCallback onSwitchMode;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

enum _Status { initializing, ready, permissionDenied, error }

/// How often a frame is grabbed from the local track and checked for motion.
const _motionCheckInterval = Duration(seconds: 1);

/// Once motion stops, wait this long before reporting it ended — covers
/// brief gaps so one stretch of movement isn't split into several events.
const _motionCooldown = Duration(seconds: 8);

/// A frame capture that hasn't come back by now means the camera has stopped
/// delivering frames (e.g. iOS paused it under thermal pressure).
const _captureTimeout = Duration(seconds: 5);

/// After this many stalled captures in a row, the camera is restarted, since
/// a frozen camera would otherwise sit there frozen until someone notices.
const _stallsBeforeRestart = 2;

/// How long a finished clip waits for its event id (the `motion-start` ack)
/// before it's dropped as belonging to no event.
const _eventIdTimeout = Duration(seconds: 10);

/// How often queued clips are retried while the camera runs, on top of
/// retrying whenever the socket reconnects.
const _clipRetryInterval = Duration(minutes: 2);

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  final _motionDetector = MotionDetector();
  late final _clipQueue = ClipUploadQueue(MotionApi(ApiClient.forDevice(AppConfig.serverUrl, widget.credentials.token)));
  Timer? _clipRetryTimer;
  late final SignalingClient _signaling;
  late DeviceCredentials _credentials = widget.credentials;

  /// The camera and mic, opened once in [_setup] and shared by the preview,
  /// motion detection, clip recording and (while watched) publishing, so
  /// nothing has to fight over the hardware.
  LocalVideoTrack? _videoTrack;
  LocalAudioTrack? _audioTrack;

  /// This camera's LiveKit room, joined only while someone is watching.
  Room? _room;
  EventsListener<RoomEvent>? _roomListener;

  /// Set once [dispose] starts, so async cleanup it kicks off doesn't call
  /// setState on a widget that's going away.
  bool _disposed = false;

  Timer? _motionTimer;
  bool _motionCheckInFlight = false;
  int _stalledCaptures = 0;
  bool _restartingCamera = false;
  DateTime? _lastMotionAt;

  _Status _status = _Status.initializing;
  /// Shown over the preview only while the server can't be reached; when
  /// all is well the screen just shows the feed (plus LIVE while streaming).
  String? _connectionProblem;
  String? _errorMessage;
  bool _permissionPermanentlyDenied = false;
  bool _isLiveToViewer = false;
  bool _motionActive = false;
  _Clip? _clip;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A camera phone sits on a shelf or mount sideways, and viewers lay the
    // feed out as a horizontal video, so this screen only runs in landscape,
    // full-screen.
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Left alone, the phone's auto-lock would sleep the screen after a
    // minute or so, which pauses the app and stops the camera.
    WakelockPlus.enable();
    _connectSignaling();
    _setup();
    // Clips left over from an earlier run (e.g. the app was killed while
    // offline) go up as soon as possible.
    _clipQueue.drain();
    _clipRetryTimer = Timer.periodic(_clipRetryInterval, (_) => _clipQueue.drain());
  }

  /// Creates the signaling socket and registers its listeners. Registered
  /// once: `_setup` re-connects on every resume, but socket_io_client keeps
  /// listeners across disconnects, so registering them here (rather than in
  /// `_setup`) avoids piling up duplicates.
  void _connectSignaling() {
    final token = widget.credentials.token;
    _signaling = SignalingClient(AppConfig.serverUrl, auth: () async => {'device_token': token});

    _signaling.socket.on('connect', (_) {
      if (mounted) setState(() => _connectionProblem = null);
      // Back online, so whatever piled up meanwhile can go.
      _clipQueue.drain();
    });
    // The server forgets which cameras are streaming when one drops off,
    // and viewers re-request the stream once it's back, so leave the room.
    _signaling.socket.on('disconnect', (_) => _stopStreaming());
    _signaling.socket.on('connect_error', (data) {
      if (SignalingClient.refusalReason(data) == 'device_revoked') {
        widget.onUnpaired();
      } else if (mounted) {
        setState(() => _connectionProblem = 'Can\'t reach the server — retrying…');
      }
    });
    _signaling.socket.on('stream-start', (data) {
      final grant = StreamGrant.fromJson(data);
      if (grant != null) _startStreaming(grant);
    });
    _signaling.socket.on('stream-stop', (_) => _stopStreaming());
  }

  Future<void> _renameCamera(String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == _credentials.name) return;

    // The server pushes the new name to viewers' rosters itself, so unlike
    // the old connect-time `camera_name`, this doesn't need a reconnect.
    try {
      await _credentials.rename(AppConfig.serverUrl, trimmed);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rename failed: $e')));
      return;
    }
    final updated = _credentials.withName(trimmed);
    await updated.save();
    if (mounted) setState(() => _credentials = updated);
  }

  Future<void> _showRenameDialog() async {
    final controller = TextEditingController(text: _credentials.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Camera name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. Front Door'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName != null && newName.trim().isNotEmpty) await _renameCamera(newName);
  }

  Future<void> _showSettings() async {
    final action = await showModalBottomSheet<_SettingsAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename camera'),
              onTap: () => Navigator.of(context).pop(_SettingsAction.rename),
            ),
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('Stop camera & switch mode'),
              onTap: () => Navigator.of(context).pop(_SettingsAction.switchMode),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _SettingsAction.rename:
        await _showRenameDialog();
      case _SettingsAction.switchMode:
        await _confirmSwitchMode();
      case null:
        break;
    }
  }

  Future<void> _confirmSwitchMode() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop this camera?'),
        content: const Text(
          'This phone will stop streaming and recording motion, and go back to the mode picker. '
          'It stays paired, so choosing Camera Mode again picks up where it left off.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Stop camera')),
        ],
      ),
    );
    if (confirmed == true) widget.onSwitchMode();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _teardown();
    } else if (state == AppLifecycleState.resumed && _videoTrack == null) {
      _setup();
    }
  }

  Future<void> _setup() async {
    setState(() => _status = _Status.initializing);

    final cameraStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();
    if (!cameraStatus.isGranted || !micStatus.isGranted) {
      setState(() {
        _status = _Status.permissionDenied;
        // iOS only shows the system prompt once; after that, .request() just
        // resolves to permanentlyDenied without any UI, so the only way
        // forward is the Settings app.
        _permissionPermanentlyDenied =
            cameraStatus.isPermanentlyDenied || micStatus.isPermanentlyDenied;
      });
      return;
    }

    LocalVideoTrack? video;
    try {
      video = await LocalVideoTrack.createCameraTrack(
        // The rear lens: an unattended camera faces the room, not a person
        // holding the phone.
        const CameraCaptureOptions(cameraPosition: CameraPosition.back, params: VideoParametersPresets.h720_169),
      );
      final audio = await LocalAudioTrack.create();
      _videoTrack = video;
      _audioTrack = audio;
    } catch (e) {
      await video?.stop();
      setState(() {
        _status = _Status.error;
        _errorMessage = e.toString();
      });
      return;
    }

    if (!mounted) return;
    _stalledCaptures = 0;
    setState(() => _status = _Status.ready);
    _signaling.socket.connect();
    _motionTimer = Timer.periodic(_motionCheckInterval, (_) => _checkForMotion());
  }

  /// Grabs a still frame off the local track and runs it through the motion
  /// detector, independent of whether a viewer is connected. Each stretch of
  /// motion is reported to the server and recorded as a clip, for the
  /// viewers' timeline. Skips a tick rather than queuing if the previous
  /// check (frame capture + OpenCV) hasn't finished yet.
  Future<void> _checkForMotion() async {
    if (_motionCheckInFlight) return;
    final track = _videoTrack;
    if (track == null) return;

    _motionCheckInFlight = true;
    try {
      final ByteBuffer frame;
      try {
        frame = await track.mediaStreamTrack.captureFrame().timeout(_captureTimeout);
      } on TimeoutException {
        if (++_stalledCaptures >= _stallsBeforeRestart) _restartCamera();
        return;
      }
      _stalledCaptures = 0;
      final motionDetected = await _motionDetector.detect(frame.asUint8List());
      if (_videoTrack != track) return;

      if (motionDetected) {
        _lastMotionAt = DateTime.now();
        if (!_motionActive) await _startMotion();
      } else if (_motionActive) {
        final last = _lastMotionAt;
        if (last != null && DateTime.now().difference(last) >= _motionCooldown) {
          await _endMotion();
        }
      }
    } catch (_) {
      // Best-effort: a failed capture/detect just skips this tick.
    } finally {
      _motionCheckInFlight = false;
    }
  }

  /// Reopens the camera after it stopped delivering frames. Tearing down ends
  /// any open motion event and reconnects the socket, as a resume does.
  Future<void> _restartCamera() async {
    if (_restartingCamera || _disposed) return;
    _restartingCamera = true;
    debugPrint('Camera stopped delivering frames; restarting it');
    try {
      await _teardown();
      if (mounted && !_disposed) await _setup();
    } finally {
      _restartingCamera = false;
    }
  }

  /// Reports motion to the server and records a clip of it. The event id the
  /// clip belongs to comes back in `motion-start`'s ack, long before the clip
  /// is finished.
  Future<void> _startMotion() async {
    final track = _videoTrack;
    if (track == null || _motionActive) return;
    setState(() => _motionActive = true);

    final clip = _Clip(await _clipQueue.newRecordingFile());
    _clip = clip;
    _signaling.socket.emitWithAck('motion-start', null, ack: (data) {
      if (!clip.eventId.isCompleted) clip.eventId.complete(data is Map ? data['id'] as String? : null);
    });
    await clip.recorder.start(
      clip.file.path,
      videoTrack: track.mediaStreamTrack,
      audioChannel: rtc.RecorderAudioChannel.INPUT,
    );
  }

  Future<void> _endMotion() async {
    if (!_motionActive) return;
    _signaling.socket.emit('motion-end');
    if (mounted && !_disposed) setState(() => _motionActive = false);

    final clip = _clip;
    _clip = null;
    if (clip == null) return;
    await clip.recorder.stop();
    _queueClip(clip);
  }

  /// Hands a finished clip to the upload queue, which keeps it until the
  /// server has it. A clip whose event id never arrives (the socket was down
  /// when motion started) belongs to no event, so it's dropped.
  Future<void> _queueClip(_Clip clip) async {
    final eventId = await clip.eventId.future.timeout(_eventIdTimeout, onTimeout: () => null);
    if (eventId == null) {
      await _clipQueue.discard(clip.file);
    } else {
      await _clipQueue.add(clip.file, eventId);
    }
  }

  /// Joins this camera's LiveKit room and publishes the already-running
  /// camera and mic, once the server says someone wants to watch.
  Future<void> _startStreaming(StreamGrant grant) async {
    final video = _videoTrack;
    final audio = _audioTrack;
    if (video == null || audio == null) return;
    await _stopStreaming();

    final room = Room(
      roomOptions: const RoomOptions(
        // Leaving the room must not stop the tracks: the preview, motion
        // detection and clip recording keep using them.
        stopLocalTrackOnUnpublish: false,
        // Simulcast would encode extra layers on the phone for no benefit
        // with a handful of viewers.
        defaultVideoPublishOptions: VideoPublishOptions(simulcast: false),
      ),
    );
    final listener = room.createListener()
      ..on<ParticipantConnectedEvent>((_) => _updateLive())
      ..on<ParticipantDisconnectedEvent>((_) => _updateLive())
      ..on<RoomDisconnectedEvent>((_) => _updateLive());
    _room = room;
    _roomListener = listener;

    try {
      await room.connect(grant.url, grant.token);
      // A `stream-stop` (or teardown) may have arrived while connecting.
      if (_room != room) return;
      await room.localParticipant?.publishVideoTrack(video);
      await room.localParticipant?.publishAudioTrack(audio);
      _updateLive();
    } catch (e) {
      debugPrint('Joining LiveKit room failed: $e');
      if (_room == room) await _stopStreaming();
    }
  }

  /// LIVE shows while at least one viewer is in the room.
  void _updateLive() {
    final live = _room?.remoteParticipants.isNotEmpty ?? false;
    if (mounted && !_disposed && live != _isLiveToViewer) setState(() => _isLiveToViewer = live);
  }

  /// Leaves the room (if in one). The local tracks keep running.
  Future<void> _stopStreaming() async {
    final room = _room;
    final listener = _roomListener;
    _room = null;
    _roomListener = null;
    _updateLive();
    await listener?.dispose();
    await room?.disconnect();
    await room?.dispose();
  }

  /// Releases the camera and drops the signaling connection while the app is
  /// backgrounded. Only disconnects the socket (rather than disposing it) so
  /// its listeners survive for `_setup` to reconnect with on resume.
  Future<void> _teardown() async {
    _motionTimer?.cancel();
    _motionTimer = null;
    if (_motionActive) await _endMotion();
    await _stopStreaming();
    _signaling.socket.disconnect();

    final video = _videoTrack;
    final audio = _audioTrack;
    _videoTrack = null;
    _audioTrack = null;
    // Take the preview off screen before stopping the track it's showing.
    if (mounted && !_disposed) {
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
    }
    await video?.stop();
    await audio?.stop();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _clipRetryTimer?.cancel();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _motionDetector.dispose();
    _teardown();
    _signaling.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _status == _Status.ready;
    return PopScope(
      // System back would otherwise close the app and stop the camera; it
      // asks first, like "Stop camera & switch mode" in settings.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmSwitchMode();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _buildBody(),
            // Controls float over the full-bleed preview; SafeArea keeps them
            // clear of a landscape notch or camera cutout.
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _OverlayButton(icon: Icons.settings_outlined, tooltip: 'Settings', onPressed: _showSettings),
                        const SizedBox(width: 8),
                        Flexible(
                          child: _Pill(
                            child: Text(
                              _credentials.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        if (ready && _isLiveToViewer) ...[
                          const SizedBox(width: 8),
                          const _Pill(
                            icon: Icon(Icons.wifi_tethering, color: Colors.greenAccent, size: 14),
                            child: Text(
                              'LIVE',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                        if (ready && _connectionProblem != null) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: _Pill(
                              icon: const Icon(Icons.cloud_off, color: Colors.white70, size: 14),
                              child: Text(_connectionProblem!, style: const TextStyle(color: Colors.white70)),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const Spacer(),
                    if (ready && _motionActive)
                      const _Pill(
                        icon: Icon(Icons.directions_run, color: Colors.orangeAccent, size: 14),
                        child: Text(
                          'MOTION · REC',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_status) {
      case _Status.initializing:
        return const Center(child: CircularProgressIndicator());
      case _Status.permissionDenied:
        return _MessageView(
          icon: Icons.no_photography,
          message: _permissionPermanentlyDenied
              ? 'Camera and microphone access was denied. Enable them for this app in Settings, then come back.'
              : 'Camera and microphone permissions are required to run this device as a camera.',
          retryLabel: _permissionPermanentlyDenied ? 'Open Settings' : 'Retry',
          onRetry: _permissionPermanentlyDenied ? openAppSettings : _setup,
        );
      case _Status.error:
        return _MessageView(
          icon: Icons.error_outline,
          message: _errorMessage ?? 'Something went wrong starting the camera.',
          onRetry: _setup,
        );
      case _Status.ready:
        final track = _videoTrack;
        if (track == null) return const SizedBox.shrink();
        return VideoTrackRenderer(track, fit: VideoViewFit.cover, mirrorMode: VideoViewMirrorMode.off);
    }
  }
}

enum _SettingsAction { rename, switchMode }

/// A clip being recorded for one motion event.
class _Clip {
  _Clip(this.file);

  final File file;
  final recorder = rtc.MediaRecorder();

  /// Completes with the event id from the server's `motion-start` ack (null
  /// if the server refused it).
  final eventId = Completer<String?>();
}

/// A translucent rounded label for text over the camera preview.
class _Pill extends StatelessWidget {
  const _Pill({required this.child, this.icon});

  final Widget child;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[icon!, const SizedBox(width: 6)],
          Flexible(child: child),
        ],
      ),
    );
  }
}

class _OverlayButton extends StatelessWidget {
  const _OverlayButton({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filled(
      style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}

class _MessageView extends StatelessWidget {
  final IconData icon;
  final String message;
  final String retryLabel;
  final VoidCallback? onRetry;

  const _MessageView({
    required this.icon,
    required this.message,
    this.retryLabel = 'Retry',
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    // Scrollable because a landscape phone has little height to spare.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              ElevatedButton(onPressed: onRetry, child: Text(retryLabel)),
            ],
          ],
        ),
      ),
    );
  }
}
