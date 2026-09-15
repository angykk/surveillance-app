import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../recording/camera_recordings_screen.dart';
import '../recording/recording_manager.dart';
import '../recording/recordings_screen.dart';
import '../webrtc/signaling_client.dart';
import 'camera_list_screen.dart';

/// Watches a single camera over an already-connected [SignalingClient] that
/// the caller (CameraListScreen) owns — this screen pairs with `camera` via
/// a `watch-camera` event rather than opening its own socket, so switching
/// cameras doesn't mean reconnecting to the server each time.
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({
    super.key,
    required this.signaling,
    required this.camera,
    required this.serverUrl,
  });

  final SignalingClient signaling;
  final CameraInfo camera;
  final String serverUrl;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  final _remoteRenderer = RTCVideoRenderer();
  final _recordingManager = RecordingManager();

  MediaStream? _remoteStream;
  MediaRecorder? _mediaRecorder;
  String _status = 'Connecting…';
  bool _isLive = false;
  bool _isRecording = false;

  SignalingClient get _signaling => widget.signaling;

  // socket_io_client removes listeners by identity, so anonymous closures
  // passed straight to `.on()` couldn't be unregistered in dispose — these
  // fields hold the exact closures used for both `.on()` and `.off()`.
  late final void Function(dynamic) _onConnect;
  late final void Function(dynamic) _onDisconnect;
  late final void Function(dynamic) _onPeerLeft;
  late final void Function(dynamic) _onOffer;

  @override
  void initState() {
    super.initState();
    _remoteRenderer.initialize();

    _onConnect = (_) {
      if (mounted) setState(() => _status = 'Waiting for ${widget.camera.name}…');
      _watchCamera();
    };
    // Fires when this viewer's own connection drops (briefly, before
    // socket_io_client's automatic reconnect kicks in).
    _onDisconnect = (_) => _resetToWaiting('Disconnected — reconnecting…');
    // Fires when the *camera* disconnects while this viewer stays connected
    // to the signaling server.
    _onPeerLeft = (_) => _resetToWaiting('${widget.camera.name} disconnected');
    _onOffer = _handleOffer;

    _signaling.socket.on('connect', _onConnect);
    _signaling.socket.on('disconnect', _onDisconnect);
    _signaling.socket.on('peer-left', _onPeerLeft);
    _signaling.socket.on('offer', _onOffer);
    _signaling.socket.on('icecandidate', _signaling.addRemoteIceCandidate);

    if (_signaling.socket.connected) {
      _watchCamera();
    } else {
      _signaling.socket.connect();
    }
  }

  void _watchCamera() {
    setState(() => _status = 'Waiting for ${widget.camera.name}…');
    _signaling.socket.emit('watch-camera', {'camera_id': widget.camera.id});
  }

  /// Drops any stale peer connection/recording and returns to the waiting
  /// state, so a disconnect never leaves the viewer stuck on a frozen frame.
  Future<void> _resetToWaiting(String status) async {
    if (_isRecording) {
      await _mediaRecorder?.stop();
      _mediaRecorder = null;
      _isRecording = false;
    }
    // Detach the renderer from the stream *before* closing the peer
    // connection below — closing it invalidates the remote stream's native
    // tracks, and detaching from an already-invalidated stream is what
    // throws "Got exception for RTCVideoRenderer::setSrcObject: null".
    _clearRenderer();
    _remoteStream = null;
    await _signaling.resetConnection();
    if (mounted) {
      setState(() {
        _isLive = false;
        _status = status;
      });
    }
  }

  /// The renderer can already be disposed by the time an async disconnect
  /// handler gets here (e.g. the widget was torn down mid-teardown), which
  /// makes the plain `srcObject` setter throw synchronously — swallow that
  /// rather than crash on what's just a redundant cleanup.
  void _clearRenderer() {
    if (!mounted) return;
    try {
      _remoteRenderer.srcObject = null;
    } catch (_) {}
  }

  Future<void> _handleOffer(dynamic data) async {
    final pc = await _signaling.createConnection();

    pc.onTrack = (RTCTrackEvent event) {
      if (event.track.kind != 'video' || event.streams.isEmpty) return;
      setState(() {
        _remoteStream = event.streams.first;
        _remoteRenderer.srcObject = _remoteStream;
        _isLive = true;
        _status = 'Live';
      });
    };

    await pc.setRemoteDescription(RTCSessionDescription(data['sdp'], data['type']));
    await _signaling.flushPendingIceCandidates();

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _signaling.socket.emit('answer', {'sdp': answer.sdp, 'type': answer.type});
  }

  Future<void> _toggleRecording() async {
    final stream = _remoteStream;
    if (stream == null) return;

    if (_isRecording) {
      await _mediaRecorder?.stop();
      _mediaRecorder = null;
      setState(() => _isRecording = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Recording saved')),
      );
    } else {
      final file = await _recordingManager.newRecordingFile();
      final recorder = MediaRecorder();
      await recorder.start(
        file.path,
        videoTrack: stream.getVideoTracks()[0],
        // OUTPUT captures the incoming remote audio, not this device's mic.
        audioChannel: RecorderAudioChannel.OUTPUT,
      );
      _mediaRecorder = recorder;
      setState(() => _isRecording = true);
    }
  }

  @override
  void dispose() {
    if (_isRecording) {
      _mediaRecorder?.stop();
    }
    _signaling.socket.off('connect', _onConnect);
    _signaling.socket.off('disconnect', _onDisconnect);
    _signaling.socket.off('peer-left', _onPeerLeft);
    _signaling.socket.off('offer', _onOffer);
    _signaling.socket.off('icecandidate', _signaling.addRemoteIceCandidate);
    if (_signaling.socket.connected) {
      _signaling.socket.emit('stop-watching');
    }
    _signaling.resetConnection();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.camera.name} — $_status'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_outlined),
            tooltip: '${widget.camera.name} recordings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CameraRecordingsScreen(
                  serverUrl: widget.serverUrl,
                  cameraId: widget.camera.id,
                  cameraName: widget.camera.name,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.video_library_outlined),
            tooltip: 'Recordings made on this device',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RecordingsScreen()),
            ),
          ),
        ],
      ),
      body: _isLive
          ? Stack(
              fit: StackFit.expand,
              children: [
                RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
                if (_isRecording)
                  const Positioned(top: 16, left: 16, child: _RecIndicator()),
              ],
            )
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.videocam_off_outlined, size: 48, color: Colors.grey),
                    const SizedBox(height: 16),
                    Text(_status, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () {
                        if (_signaling.socket.connected) {
                          _watchCamera();
                        } else {
                          _signaling.socket.connect();
                        }
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            ),
      floatingActionButton: _isLive
          ? FloatingActionButton.extended(
              onPressed: _toggleRecording,
              backgroundColor: _isRecording ? Colors.red : null,
              icon: Icon(_isRecording ? Icons.stop : Icons.fiber_manual_record),
              label: Text(_isRecording ? 'Stop' : 'Record'),
            )
          : null,
    );
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
          Text('REC', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
