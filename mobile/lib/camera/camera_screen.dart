import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../api/api_client.dart';
import '../api/motion_api.dart';
import '../config.dart';
import '../motion/motion_detector.dart';
import '../webrtc/signaling_client.dart';
import 'device_credentials.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.credentials, required this.onUnpaired, required this.onSwitchMode});

  final DeviceCredentials credentials;

  /// Called when the server refuses this camera's device token — it was
  /// removed from its household in Viewer Mode — so the caller can clear
  /// the stale credentials and return to pairing.
  final VoidCallback onUnpaired;

  /// Stops the camera and returns to the mode picker. There's deliberately
  /// no back button: an unattended camera shouldn't be one tap from off.
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

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  final _localRenderer = RTCVideoRenderer();
  final _motionDetector = MotionDetector();
  late final _motionApi = MotionApi(ApiClient.forDevice(AppConfig.serverUrl, widget.credentials.token));
  late final SignalingClient _signaling;
  late DeviceCredentials _credentials = widget.credentials;

  MediaStream? _localStream;
  Timer? _motionTimer;
  bool _motionCheckInFlight = false;
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
    _connectSignaling();
    _setup();
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
    });
    _signaling.socket.on('connect_error', (data) {
      if (SignalingClient.refusalReason(data) == 'device_revoked') {
        widget.onUnpaired();
      } else if (mounted) {
        setState(() => _connectionProblem = 'Can\'t reach the server — retrying…');
      }
    });
    _signaling.socket.on('peer-joined', (_) => _startStreamingToViewer());
    _signaling.socket.on('peer-left', (_) => _stopStreamingToViewer());
    _signaling.socket.on('answer', _handleAnswer);
    _signaling.socket.on('icecandidate', _signaling.addRemoteIceCandidate);
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
    } else if (state == AppLifecycleState.resumed && _localStream == null) {
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

    await _localRenderer.initialize();

    try {
      final stream = await navigator.mediaDevices.getUserMedia({
        'video': true,
        'audio': true,
      });
      _localStream = stream;
      _localRenderer.srcObject = stream;
    } catch (e) {
      setState(() {
        _status = _Status.error;
        _errorMessage = e.toString();
      });
      return;
    }

    if (!mounted) return;
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
    final stream = _localStream;
    if (stream == null || stream.getVideoTracks().isEmpty) return;

    _motionCheckInFlight = true;
    try {
      final frame = await stream.getVideoTracks().first.captureFrame();
      final motionDetected = _motionDetector.detect(frame.asUint8List());

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

  /// Reports motion to the server and records a clip of it. The event id the
  /// clip belongs to comes back in `motion-start`'s ack, long before the clip
  /// is finished.
  Future<void> _startMotion() async {
    final stream = _localStream;
    if (stream == null || _motionActive) return;
    setState(() => _motionActive = true);

    final dir = await getTemporaryDirectory();
    final clip = _Clip(File('${dir.path}/motion-${DateTime.now().millisecondsSinceEpoch}.mp4'));
    _clip = clip;
    _signaling.socket.emitWithAck('motion-start', null, ack: (data) {
      if (data is Map) clip.eventId = data['id'] as String?;
    });
    await clip.recorder.start(
      clip.file.path,
      videoTrack: stream.getVideoTracks()[0],
      audioChannel: RecorderAudioChannel.INPUT,
    );
  }

  Future<void> _endMotion() async {
    if (!_motionActive) return;
    _signaling.socket.emit('motion-end');
    if (mounted) setState(() => _motionActive = false);

    final clip = _clip;
    _clip = null;
    if (clip == null) return;
    await clip.recorder.stop();
    _uploadClip(clip);
  }

  /// Best-effort: a clip whose upload fails, or whose event id never arrived
  /// (e.g. the socket was down when motion started), is dropped, and its
  /// event just shows in the timeline without one. The local file is only a
  /// staging copy, so it's removed either way.
  Future<void> _uploadClip(_Clip clip) async {
    try {
      final eventId = clip.eventId;
      if (eventId != null) await _motionApi.uploadClip(eventId, clip.file);
    } catch (e) {
      debugPrint('Clip upload failed: $e');
    } finally {
      try {
        await clip.file.delete();
      } catch (_) {}
    }
  }

  Future<void> _startStreamingToViewer() async {
    final stream = _localStream;
    final signaling = _signaling;
    if (stream == null) return;

    final pc = await signaling.createConnection();
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    signaling.socket.emit('offer', {'sdp': offer.sdp, 'type': offer.type});
  }

  Future<void> _stopStreamingToViewer() async {
    await _signaling.resetConnection();
    if (mounted) {
      setState(() => _isLiveToViewer = false);
    }
  }

  Future<void> _handleAnswer(dynamic data) async {
    final signaling = _signaling;
    final pc = signaling.pc;
    if (pc == null) return;
    if (pc.signalingState != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      return;
    }

    await pc.setRemoteDescription(RTCSessionDescription(data['sdp'], data['type']));
    await signaling.flushPendingIceCandidates();
    if (mounted) setState(() => _isLiveToViewer = true);
  }

  /// Releases the camera and drops the signaling connection while the app is
  /// backgrounded. Only disconnects the socket (rather than disposing it) so
  /// its listeners survive for `_setup` to reconnect with on resume.
  Future<void> _teardown() async {
    _motionTimer?.cancel();
    _motionTimer = null;
    if (_motionActive) await _endMotion();
    await _signaling.resetConnection();
    _signaling.socket.disconnect();
    // Detach the renderer before disposing the stream it's showing — doing
    // it the other way round throws "Got exception for
    // RTCVideoRenderer::setSrcObject: null" trying to detach from a stream
    // whose native tracks are already gone.
    _clearLocalRenderer();
    await _localStream?.dispose();
    _localStream = null;
    if (mounted) setState(() {});
  }

  /// The renderer can already be disposed by the time an async teardown gets
  /// here (e.g. the widget was torn down mid-teardown), which makes the
  /// plain `srcObject` setter throw synchronously — swallow that rather than
  /// crash on what's just a redundant cleanup.
  void _clearLocalRenderer() {
    if (!mounted) return;
    try {
      _localRenderer.srcObject = null;
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _motionDetector.dispose();
    _localRenderer.dispose();
    _teardown();
    _signaling.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _status == _Status.ready;
    return Scaffold(
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
        return RTCVideoView(_localRenderer, mirror: false, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover);
    }
  }
}

enum _SettingsAction { rename, switchMode }

/// A clip being recorded for one motion event.
class _Clip {
  _Clip(this.file);

  final File file;
  final recorder = MediaRecorder();

  /// Set from the server's `motion-start` ack; null until then.
  String? eventId;
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
