import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../motion/motion_detector.dart';
import '../recording/recording_manager.dart';
import '../recording/recordings_api.dart';
import '../recording/recordings_screen.dart';
import '../webrtc/signaling_client.dart';
import 'camera_identity.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

enum _Status { initializing, ready, permissionDenied, error }

/// How often a frame is grabbed from the local track and checked for motion.
const _motionCheckInterval = Duration(seconds: 1);

/// Once motion stops, keep recording for this long before cutting the clip —
/// covers brief gaps so a single event isn't split into several tiny files.
const _recordingCooldown = Duration(seconds: 8);

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  final _localRenderer = RTCVideoRenderer();
  final _recordingManager = RecordingManager();
  final _motionDetector = MotionDetector();
  late final _recordingsApi = RecordingsApi(dotenv.env['SERVER_IP']!);

  // Not created until the persisted camera identity has loaded (registering
  // with the server needs a stable camera_id), so this starts null rather
  // than `late final` — everything that touches it must go through `?.` or
  // an early-return null check.
  SignalingClient? _signaling;
  CameraIdentity? _identity;

  MediaStream? _localStream;
  MediaRecorder? _mediaRecorder;
  File? _currentRecordingFile;
  Timer? _motionTimer;
  bool _motionCheckInFlight = false;
  DateTime? _lastMotionAt;

  _Status _status = _Status.initializing;
  String _viewerStatus = 'Connecting to signaling server…';
  String? _errorMessage;
  bool _permissionPermanentlyDenied = false;
  bool _isLiveToViewer = false;
  bool _isRecording = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    final identity = await CameraIdentity.load();
    if (!mounted) return;
    setState(() => _identity = identity);
    _connectSignaling(identity);
    await _setup();

    // Nudge for a real name right away, before this camera ever shows up in
    // a viewer's picker under the generic default — that's what made
    // same-named cameras indistinguishable there.
    if (identity.isUnnamed && mounted) await _showRenameDialog(firstRun: true);
  }

  /// Creates the signaling socket for the given identity and registers its
  /// listeners. Registered once per socket instance: `_setup` re-connects on
  /// every resume, but socket_io_client keeps listeners across disconnects,
  /// so registering them here (rather than in `_setup`) avoids piling up
  /// duplicates. Called again on rename, which needs a fresh socket since
  /// `camera_name` is sent as a connect-time query param.
  void _connectSignaling(CameraIdentity identity) {
    final signaling = SignalingClient(
      dotenv.env['SERVER_IP']!,
      role: 'camera',
      extraQuery: {'camera_id': identity.id, 'camera_name': identity.name},
    );
    _signaling = signaling;

    signaling.socket.on('connect', (_) {
      if (mounted) setState(() => _viewerStatus = 'Waiting for a viewer…');
    });
    signaling.socket.on('peer-joined', (_) => _startStreamingToViewer());
    signaling.socket.on('peer-left', (_) => _stopStreamingToViewer());
    signaling.socket.on('answer', _handleAnswer);
    signaling.socket.on('icecandidate', signaling.addRemoteIceCandidate);
  }

  Future<void> _renameCamera(String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;

    await CameraIdentity.saveName(trimmed);
    final identity = CameraIdentity(id: _identity!.id, name: trimmed, isUnnamed: false);
    if (!mounted) return;
    setState(() => _identity = identity);

    // camera_name only takes effect at connect time, so the rename has to
    // reconnect with a fresh socket rather than just relabeling in place.
    await _stopStreamingToViewer();
    _signaling?.dispose();
    _connectSignaling(identity);
    _signaling?.socket.connect();
  }

  Future<void> _showRenameDialog({bool firstRun = false}) async {
    final controller = TextEditingController(text: firstRun ? '' : (_identity?.name ?? ''));
    final newName = await showDialog<String>(
      context: context,
      barrierDismissible: !firstRun,
      builder: (context) => AlertDialog(
        title: Text(firstRun ? 'Name this camera' : 'Camera name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. Front Door'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          if (!firstRun)
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
    _signaling?.socket.connect();
    _motionTimer = Timer.periodic(_motionCheckInterval, (_) => _checkForMotion());
  }

  /// Grabs a still frame off the local track and runs it through the motion
  /// detector, independent of whether a viewer is connected — this is what
  /// lets Camera Mode record on its own. Skips a tick rather than queuing if
  /// the previous check (frame capture + OpenCV) hasn't finished yet.
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
        if (!_isRecording) await _startMotionRecording();
      } else if (_isRecording) {
        final last = _lastMotionAt;
        if (last != null && DateTime.now().difference(last) >= _recordingCooldown) {
          await _stopMotionRecording();
        }
      }
    } catch (_) {
      // Best-effort: a failed capture/detect just skips this tick.
    } finally {
      _motionCheckInFlight = false;
    }
  }

  Future<void> _startMotionRecording() async {
    final stream = _localStream;
    if (stream == null || _isRecording) return;

    final file = await _recordingManager.newRecordingFile();
    final recorder = MediaRecorder();
    await recorder.start(
      file.path,
      videoTrack: stream.getVideoTracks()[0],
      audioChannel: RecorderAudioChannel.INPUT,
    );
    _mediaRecorder = recorder;
    _currentRecordingFile = file;
    if (mounted) setState(() => _isRecording = true);
  }

  Future<void> _stopMotionRecording() async {
    await _mediaRecorder?.stop();
    _mediaRecorder = null;
    if (mounted) setState(() => _isRecording = false);

    final file = _currentRecordingFile;
    _currentRecordingFile = null;
    if (file != null) _uploadRecording(file);
  }

  /// Pushes a finished clip to the server so Viewer Mode can browse it, on
  /// top of the local copy `RecordingManager` already keeps — the local copy
  /// stays put either way, so a failed/offline upload never loses the clip,
  /// it just means it's only visible in this device's own Recordings list
  /// until the next successful upload.
  Future<void> _uploadRecording(File file) async {
    final identity = _identity;
    if (identity == null) return;
    try {
      await _recordingsApi.uploadRecording(
        file: file,
        cameraId: identity.id,
        cameraName: identity.name,
      );
    } catch (e) {
      debugPrint('Recording upload failed, keeping local copy only: $e');
    }
  }

  Future<void> _startStreamingToViewer() async {
    final stream = _localStream;
    final signaling = _signaling;
    if (stream == null || signaling == null) return;

    final pc = await signaling.createConnection();
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    signaling.socket.emit('offer', {'sdp': offer.sdp, 'type': offer.type});
    if (mounted) setState(() => _viewerStatus = 'Viewer connected — streaming');
  }

  Future<void> _stopStreamingToViewer() async {
    await _signaling?.resetConnection();
    if (mounted) {
      setState(() {
        _isLiveToViewer = false;
        _viewerStatus = 'Waiting for a viewer…';
      });
    }
  }

  Future<void> _handleAnswer(dynamic data) async {
    final signaling = _signaling;
    final pc = signaling?.pc;
    if (signaling == null || pc == null) return;
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
    if (_isRecording) await _stopMotionRecording();
    await _signaling?.resetConnection();
    _signaling?.socket.disconnect();
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
    _motionDetector.dispose();
    _localRenderer.dispose();
    _teardown();
    _signaling?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = _status == _Status.ready
        ? '${_identity?.name ?? 'Camera'} — $_viewerStatus'
        : _identity?.name ?? 'Camera Mode';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Rename camera',
            onPressed: _identity == null ? null : _showRenameDialog,
          ),
          IconButton(
            icon: const Icon(Icons.video_library_outlined),
            tooltip: 'Recordings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RecordingsScreen()),
            ),
          ),
        ],
      ),
      body: _buildBody(),
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
        return Stack(
          fit: StackFit.expand,
          children: [
            RTCVideoView(
              _localRenderer,
              mirror: false,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
            if (_isRecording)
              const Positioned(top: 16, left: 16, child: _RecIndicator()),
            if (_isLiveToViewer)
              const Positioned(top: 16, right: 16, child: _LiveIndicator()),
          ],
        );
    }
  }
}

class _RecIndicator extends StatelessWidget {
  const _RecIndicator();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, color: Colors.red, size: 12),
          SizedBox(width: 6),
          Text('MOTION · REC', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _LiveIndicator extends StatelessWidget {
  const _LiveIndicator();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_tethering, color: Colors.greenAccent, size: 14),
          SizedBox(width: 6),
          Text('LIVE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      ),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
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
