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
import '../ui/app_theme.dart';
import '../ui/rename_dialog.dart';
import '../ui/shared_widgets.dart';
import '../signaling/signaling_client.dart';
import 'clip_upload_queue.dart';
import 'device_credentials.dart';
import 'serial_task.dart';
import 'thumbnail.dart';

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

/// How long after dropping out of its LiveKit room the camera asks the
/// server to rejoin, so a room that can't be joined at all isn't retried in
/// a tight loop.
const _rejoinDelay = Duration(seconds: 3);

/// The rear lens: an unattended camera faces the room, not a person holding
/// the phone.
const _cameraCaptureOptions =
    CameraCaptureOptions(cameraPosition: CameraPosition.back, params: VideoParametersPresets.h720_169);

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  final _motionDetector = MotionDetector();
  late final _clipQueue = ClipUploadQueue(MotionApi(ApiClient.forDevice(AppConfig.serverUrl, widget.credentials.token)));
  Timer? _clipRetryTimer;
  late final SignalingClient _signaling;
  late DeviceCredentials _credentials = widget.credentials;

  /// Opens the camera; see [_setup].
  late final _setupTask = SerialTask(_runSetup);

  /// The camera and mic, opened once in [_setup] and shared by the preview,
  /// motion detection, clip recording and (while watched) publishing, so
  /// nothing has to fight over the hardware.
  LocalVideoTrack? _videoTrack;
  LocalAudioTrack? _audioTrack;

  /// This camera's LiveKit room, joined only while someone is watching.
  Room? _room;
  EventsListener<RoomEvent>? _roomListener;

  /// The last queued stream start/stop; see [_inStreamOrder].
  Future<void> _streamOps = Future.value();

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
    _signaling.socket.on('disconnect', (reason) {
      // The server forgets which cameras are streaming when one drops off,
      // and viewers re-request the stream once it's back, so leave the room.
      _inStreamOrder(_stopStreaming);
      // socket_io_client only reconnects by itself after a dropped
      // connection, not one the server ended. The server ends it when this
      // camera is removed from its household, and the `device_revoked`
      // refusal that unpairs it only arrives on a reconnect.
      if (SignalingClient.serverEndedConnection(reason) && !_disposed && _videoTrack != null) {
        _signaling.socket.connect();
      }
    });
    _signaling.socket.on('connect_error', (data) {
      if (SignalingClient.refusalReason(data) == 'device_revoked') {
        widget.onUnpaired();
      } else if (mounted) {
        setState(() => _connectionProblem = 'Can\'t reach the server — retrying…');
      }
    });
    _signaling.socket.on('stream-start', (data) {
      final grant = StreamGrant.fromJson(data);
      if (grant != null) _inStreamOrder(() => _startStreaming(grant));
    });
    _signaling.socket.on('stream-stop', (_) => _inStreamOrder(_stopStreaming));
    // Renamed from Viewer Mode (or by this phone, which is a no-op).
    _signaling.socket.on('renamed', (data) {
      final name = data is Map ? data['name'] : null;
      if (name is String) _applyName(name);
    });
  }

  Future<void> _showRenameDialog() async {
    final newName = await showRenameCameraDialog(context, current: _credentials.name);
    if (newName == null) return;

    // The server pushes the new name to viewers' rosters itself, so this
    // doesn't need a reconnect.
    try {
      await _credentials.rename(AppConfig.serverUrl, newName);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rename failed: $e')));
      return;
    }
    await _applyName(newName);
  }

  /// Shows and saves this camera's new name.
  Future<void> _applyName(String name) async {
    if (name == _credentials.name) return;
    final updated = _credentials.withName(name);
    await updated.save();
    if (mounted && !_disposed) setState(() => _credentials = updated);
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
    final confirmed = await showConfirmDialog(
      context,
      title: 'Stop this camera?',
      message: 'This phone will stop streaming and recording motion, and go back to the mode picker. '
          'It stays paired, so choosing Camera Mode again picks up where it left off.',
      confirmLabel: 'Stop camera',
    );
    if (confirmed) widget.onSwitchMode();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _teardown();
    } else if (state == AppLifecycleState.resumed && _videoTrack == null) {
      _setup();
    }
  }

  /// Opens the camera and mic and starts motion checks. Runs one at a time:
  /// a permission pop-up sends the app to `inactive` and back, and each
  /// return asks for setup again, as do auto-restart and Retry. Overlapping
  /// runs leaked a camera track, doubled the motion timer, and on Android
  /// threw "A request for permissions is already running". A [_teardown]
  /// during a run makes it stale, so it doesn't start the camera in the
  /// background.
  Future<void> _setup() => _setupTask.run();

  Future<void> _runSetup(bool Function() isCurrent) async {
    // Asked for again while a run that succeeded was going.
    if (_videoTrack != null || _disposed) return;
    if (mounted) setState(() => _status = _Status.initializing);

    final cameraStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();
    if (!mounted || _disposed || !isCurrent()) return;
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

    final (LocalVideoTrack, LocalAudioTrack) tracks;
    try {
      tracks = await _openTracks();
    } catch (e) {
      if (isCurrent()) _showStartError(e);
      return;
    }
    final (video, audio) = tracks;
    if (!mounted || _disposed || !isCurrent()) {
      await video.stop();
      await audio.stop();
      return;
    }
    _videoTrack = video;
    _audioTrack = audio;

    _stalledCaptures = 0;
    _motionDetector.reset();
    setState(() => _status = _Status.ready);
    _signaling.socket.connect();
    _motionTimer?.cancel();
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
      } catch (_) {
        // A stopped track fails its grabs outright rather than timing out,
        // and needs the same restart.
        if (++_stalledCaptures >= _stallsBeforeRestart) _restartCamera();
        return;
      }
      _stalledCaptures = 0;
      final frameBytes = frame.asUint8List();
      final motionDetected = await _motionDetector.detect(frameBytes);
      if (_videoTrack != track) return;

      if (motionDetected) {
        _lastMotionAt = DateTime.now();
        if (!_motionActive) await _startMotion(frameBytes);
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

  /// Reports motion to the server and records a clip of it, with [frame]
  /// (the one the motion was seen in) as the event's thumbnail. The event id
  /// they belong to comes back in `motion-start`'s ack, long before the clip
  /// is finished.
  Future<void> _startMotion(Uint8List frame) async {
    final track = _videoTrack;
    if (track == null || _motionActive) return;
    setState(() => _motionActive = true);

    final file = await _clipQueue.newRecordingFile();
    // A teardown while waiting has already ended this motion (with no clip
    // to stop), and is stopping the track this would record.
    if (!_motionActive || _videoTrack != track) {
      if (_motionActive && mounted && !_disposed) setState(() => _motionActive = false);
      return;
    }
    final clip = _Clip(file);
    _clip = clip;
    _signaling.socket.emitWithAck('motion-start', null, ack: (data) {
      if (!clip.eventId.isCompleted) clip.eventId.complete(data is Map ? data['id'] as String? : null);
    });
    unawaited(_queueThumbnail(clip, frame));
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
    // A recorder that fails to stop must not take down its caller: in
    // [_teardown] that left streaming, the socket and the camera running.
    try {
      await clip.recorder.stop();
    } catch (e) {
      debugPrint('Stopping clip recording failed: $e');
      await _clipQueue.discard(clip.file);
      return;
    }
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

  /// Shrinks [frame] into the event's thumbnail and queues it for upload.
  /// Best-effort: an event without one just shows a placeholder.
  Future<void> _queueThumbnail(_Clip clip, Uint8List frame) async {
    try {
      final results = await Future.wait([
        encodeThumbnail(frame),
        clip.eventId.future.timeout(_eventIdTimeout, onTimeout: () => null),
      ]);
      final jpeg = results[0] as Uint8List?;
      final eventId = results[1] as String?;
      if (jpeg != null && eventId != null) await _clipQueue.addThumbnail(jpeg, eventId);
    } catch (e) {
      debugPrint('Making a motion thumbnail failed: $e');
    }
  }

  /// Runs stream starts and stops one at a time, in the order they arrive.
  /// Leaving a room takes a moment, and the old room's cleanup unpublishes
  /// the same camera track a new room is publishing, so a viewer who backs
  /// out and straight back in (`stream-stop` then `stream-start`) got no
  /// video when the two overlapped.
  Future<void> _inStreamOrder(Future<void> Function() op) {
    final next = _streamOps.then((_) => op()).catchError((Object e) {
      debugPrint('Stream start/stop failed: $e');
    });
    _streamOps = next;
    return next;
  }

  /// Joins this camera's LiveKit room and publishes the already-running
  /// camera and mic, once the server says someone wants to watch.
  Future<void> _startStreaming(StreamGrant grant) async {
    // Leaving an old room may reopen the camera and mic, so read the tracks
    // only afterwards: before, this published the old, stopped ones.
    await _stopStreaming();
    final video = _videoTrack;
    final audio = _audioTrack;
    if (video == null || audio == null) return;

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
      ..on<RoomDisconnectedEvent>((_) => _onRoomLost(room));
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
      if (_room == room) {
        await _stopStreaming();
        _reportStreamEnded();
      }
    }
  }

  /// The room dropped out from under the camera (LiveKit gave up
  /// reconnecting), rather than being left on purpose: [_stopStreaming]
  /// stops listening before it leaves.
  void _onRoomLost(Room room) {
    _inStreamOrder(() async {
      if (_room != room) return;
      debugPrint('Lost the LiveKit room; asking to rejoin');
      await _stopStreaming();
      _reportStreamEnded();
    });
  }

  /// Tells the server this camera is out of its room. Otherwise it still
  /// counts the camera as streaming and never sends another `stream-start`,
  /// leaving viewers waiting. A still-watched camera gets a fresh grant (the
  /// old token expires after 10 minutes, so it can't just reconnect).
  void _reportStreamEnded() {
    Future<void>.delayed(_rejoinDelay, () {
      // Back in a room by now, or offline (the server resets streaming
      // state on reconnect anyway).
      if (_disposed || _room != null || !_signaling.socket.connected) return;
      _signaling.socket.emit('stream-ended');
    });
  }

  /// LIVE shows while at least one viewer is in the room.
  void _updateLive() {
    final live = _room?.remoteParticipants.isNotEmpty ?? false;
    if (mounted && !_disposed && live != _isLiveToViewer) setState(() => _isLiveToViewer = live);
  }

  /// Leaves the room (if in one), then reopens the camera and mic if leaving
  /// stopped them; [_teardown], which stops them anyway, skips that.
  Future<void> _stopStreaming({bool reopenCamera = true}) async {
    final room = _room;
    final listener = _roomListener;
    _room = null;
    _roomListener = null;
    _updateLive();
    if (room == null) return;
    await listener?.dispose();
    await room.disconnect();
    await room.dispose();
    if (reopenCamera) await _reopenCameraIfStopped();
  }

  /// Leaving a room disposes the tracks LiveKit published there, which stops
  /// them despite `stopLocalTrackOnUnpublish: false`. Left alone, the preview
  /// froze on its last frame, motion frame grabs failed, and the next
  /// `stream-start` couldn't publish them ("track is null"). So swap in
  /// freshly opened ones.
  Future<void> _reopenCameraIfStopped() async {
    final oldVideo = _videoTrack;
    final oldAudio = _audioTrack;
    if (_disposed || oldVideo == null || oldAudio == null) return;
    if (oldVideo.isActive && oldAudio.isActive) return;

    // The clip in progress was recording the old track.
    if (_motionActive) await _endMotion();
    await _releaseTracks();

    try {
      final (video, audio) = await _openTracks();
      _videoTrack = video;
      _audioTrack = audio;
    } catch (e) {
      _showStartError(e);
      return;
    }
    _stalledCaptures = 0;
    _motionDetector.reset();
    if (mounted && !_disposed) setState(() {});
  }

  /// Releases the camera and drops the signaling connection while the app is
  /// backgrounded. Only disconnects the socket (rather than disposing it) so
  /// its listeners survive for `_setup` to reconnect with on resume.
  Future<void> _teardown() async {
    _setupTask.cancel();
    _motionTimer?.cancel();
    _motionTimer = null;
    if (_motionActive) await _endMotion();
    await _inStreamOrder(() => _stopStreaming(reopenCamera: false));
    _signaling.socket.disconnect();
    await _releaseTracks();
  }

  /// Opens the camera and mic. If either won't open, throws, leaving
  /// neither open.
  static Future<(LocalVideoTrack, LocalAudioTrack)> _openTracks() async {
    final video = await LocalVideoTrack.createCameraTrack(_cameraCaptureOptions);
    try {
      return (video, await LocalAudioTrack.create());
    } catch (_) {
      await video.stop();
      rethrow;
    }
  }

  /// Stops the camera and mic, taking the preview off screen first so it
  /// isn't showing a track as it stops.
  Future<void> _releaseTracks() async {
    final video = _videoTrack;
    final audio = _audioTrack;
    _videoTrack = null;
    _audioTrack = null;
    if (mounted && !_disposed) {
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
    }
    await video?.stop();
    await audio?.stop();
  }

  void _showStartError(Object e) {
    if (!mounted || _disposed) return;
    setState(() {
      _status = _Status.error;
      _errorMessage = e.toString();
    });
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
        backgroundColor: AppColors.black,
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
                        OverlayButton(icon: Icons.settings_outlined, tooltip: 'Settings', onPressed: _showSettings),
                        const SizedBox(width: 8),
                        Flexible(
                          child: OverlayPill(
                            child: Text(
                              _credentials.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: AppColors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        if (ready && _isLiveToViewer) ...[
                          const SizedBox(width: 8),
                          const OverlayPill(
                            icon: Icon(Icons.wifi_tethering, color: AppColors.lightRed, size: 14),
                            child: Text(
                              'LIVE',
                              style: TextStyle(color: AppColors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                        if (ready && _connectionProblem != null) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: OverlayPill(
                              icon: Icon(Icons.cloud_off, color: AppColors.white.withValues(alpha: 0.7), size: 14),
                              child: Text(_connectionProblem!, style: TextStyle(color: AppColors.white.withValues(alpha: 0.7))),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const Spacer(),
                    if (ready && _motionActive)
                      const OverlayPill(
                        icon: Icon(Icons.directions_run, color: AppColors.taupe, size: 14),
                        child: Text(
                          'MOTION · REC',
                          style: TextStyle(color: AppColors.white, fontWeight: FontWeight.bold),
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
        return const Center(child: CircularProgressIndicator(color: AppColors.white));
      case _Status.permissionDenied:
        return _message(
          icon: Icons.no_photography,
          message: _permissionPermanentlyDenied
              ? 'Camera and microphone access was denied. Enable them for this app in Settings, then come back.'
              : 'Camera and microphone permissions are required to run this device as a camera.',
          actionLabel: _permissionPermanentlyDenied ? 'Open Settings' : 'Retry',
          onAction: _permissionPermanentlyDenied ? openAppSettings : _setup,
        );
      case _Status.error:
        return _message(
          icon: Icons.error_outline,
          message: _errorMessage ?? 'Something went wrong starting the camera.',
          actionLabel: 'Retry',
          onAction: _setup,
        );
      case _Status.ready:
        final track = _videoTrack;
        if (track == null) return const SizedBox.shrink();
        return VideoTrackRenderer(track, fit: VideoViewFit.cover, mirrorMode: VideoViewMirrorMode.off);
    }
  }
}

/// A message over the black camera background, clear of the controls
/// floating at the top.
Widget _message({
  required IconData icon,
  required String message,
  required String actionLabel,
  required VoidCallback onAction,
}) =>
    MessageView(
      icon: icon,
      message: message,
      textColor: AppColors.white,
      padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
      action: ElevatedButton(onPressed: onAction, child: Text(actionLabel)),
    );

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

