import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import '../api/motion_api.dart';
import '../webrtc/signaling_client.dart';
import 'camera_list_screen.dart';
import 'motion_timeline.dart';

/// Width of the motion timeline beside the video in landscape.
const _timelinePanelWidth = 320.0;

/// Watches a single camera over an already-connected [SignalingClient] that
/// the caller (CameraListScreen) owns — this screen pairs with `camera` via
/// a `watch-camera` event rather than opening its own socket, so switching
/// cameras doesn't mean reconnecting to the server each time.
///
/// The feed is horizontal (cameras run in landscape), so in portrait it sits
/// at the top as a 16:9 panel with the camera's motion timeline below; in
/// landscape the video takes the screen with the timeline as a side panel.
/// Tapping an event with a clip plays it in the video panel in place of the
/// live feed, until "Back to live". Offline cameras open here too: the
/// timeline and clips still work, and the stream starts by itself once the
/// camera comes back online.
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.signaling, required this.camera, required this.motionApi});

  final SignalingClient signaling;
  final CameraInfo camera;
  final MotionApi motionApi;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  final _remoteRenderer = RTCVideoRenderer();

  late CameraInfo _camera = widget.camera;
  MediaStream? _remoteStream;
  String _status = 'Connecting…';
  bool _isLive = false;

  /// Whether a `watch-camera` is outstanding or answered, so a roster update
  /// arriving right after one doesn't send a second.
  bool _watching = false;

  List<MotionEvent> _events = [];
  bool _eventsLoading = true;
  String? _eventsError;

  /// Landscape only: the timeline panel can be hidden for full-width video.
  bool _showTimeline = true;

  /// The event whose clip is showing in place of the live feed, if any.
  MotionEvent? _clipEvent;
  VideoPlayerController? _clipPlayer;

  SignalingClient get _signaling => widget.signaling;

  bool get _motionNow => _events.any((e) => e.ongoing);

  // socket_io_client removes listeners by identity, so anonymous closures
  // passed straight to `.on()` couldn't be unregistered in dispose — these
  // fields hold the exact closures used for both `.on()` and `.off()`.
  late final void Function(dynamic) _onConnect;
  late final void Function(dynamic) _onDisconnect;
  late final void Function(dynamic) _onPeerLeft;
  late final void Function(dynamic) _onOffer;
  late final void Function(dynamic) _onRoster;
  late final void Function(dynamic) _onMotion;

  @override
  void initState() {
    super.initState();
    _remoteRenderer.initialize();

    _onConnect = (_) {
      if (_camera.online) _watchCamera();
    };
    // Fires when this viewer's own connection drops (briefly, before
    // socket_io_client's automatic reconnect kicks in).
    _onDisconnect = (_) => _resetToWaiting('Disconnected — reconnecting…');
    // Fires when the *camera* disconnects while this viewer stays connected
    // to the signaling server.
    _onPeerLeft = (_) => _resetToWaiting(_camera.online ? '${_camera.name} disconnected' : _offlineStatus());
    _onOffer = _handleOffer;
    _onRoster = _handleRoster;
    _onMotion = _handleMotion;

    _signaling.socket.on('connect', _onConnect);
    _signaling.socket.on('disconnect', _onDisconnect);
    _signaling.socket.on('peer-left', _onPeerLeft);
    _signaling.socket.on('offer', _onOffer);
    _signaling.socket.on('icecandidate', _signaling.addRemoteIceCandidate);
    _signaling.socket.on('cameras-list', _onRoster);
    _signaling.socket.on('motion', _onMotion);

    if (!_signaling.socket.connected) {
      _signaling.socket.connect();
    } else if (_camera.online) {
      _watchCamera();
    } else {
      _status = _offlineStatus();
    }
    _loadEvents();
  }

  void _watchCamera() {
    _watching = true;
    setState(() => _status = 'Waiting for ${_camera.name}…');
    _signaling.socket.emit('watch-camera', {'camera_id': _camera.id});
  }

  void _retry() {
    if (!_signaling.socket.connected) {
      _signaling.socket.connect();
    } else if (_camera.online) {
      _watchCamera();
    }
  }

  /// Keeps this screen's copy of the camera current, and starts watching as
  /// soon as an offline camera comes back.
  void _handleRoster(dynamic data) {
    final cameras = (data as List).cast<Map>().map(CameraInfo.fromJson);
    final camera = cameras.where((c) => c.id == _camera.id).firstOrNull;
    if (!mounted) return;
    if (camera == null) {
      // Removed from its household while being watched.
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _camera = camera;
      if (!camera.online && !_isLive) _status = _offlineStatus();
    });
    if (camera.online && !_watching) _watchCamera();
  }

  void _handleMotion(dynamic data) {
    final event = MotionEvent.fromJson(data as Map);
    if (event.cameraId != _camera.id || !mounted) return;
    setState(() => _events = _upsert(_events, event));
  }

  Future<void> _loadEvents() async {
    setState(() {
      _eventsLoading = true;
      _eventsError = null;
    });
    try {
      final events = await widget.motionApi.events(_camera.id);
      if (!mounted) return;
      setState(() {
        // Merge rather than replace, so a live event that arrived while
        // this was loading isn't lost.
        _events = events.fold(_events, _upsert);
        _eventsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _eventsError = 'Could not load motion history: $e';
        _eventsLoading = false;
      });
    }
  }

  Future<void> _playClip(MotionEvent event) async {
    if (_clipEvent?.id == event.id) return;
    _backToLive();
    setState(() => _clipEvent = event);
    _setLiveAudio(false);
    try {
      final controller = VideoPlayerController.networkUrl(
        widget.motionApi.clipUrl(event.id),
        httpHeaders: await widget.motionApi.clipHeaders(),
      );
      // Another clip may have been picked (or the screen closed) meanwhile.
      if (!mounted || _clipEvent?.id != event.id) {
        controller.dispose();
        return;
      }
      setState(() => _clipPlayer = controller);
      await controller.initialize();
      if (!mounted || _clipPlayer != controller) return;
      controller.play();
    } catch (e) {
      if (!mounted || _clipEvent?.id != event.id) return;
      _backToLive();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not play clip: $e')));
    }
  }

  void _backToLive() {
    final player = _clipPlayer;
    _clipPlayer = null;
    player?.dispose();
    _setLiveAudio(true);
    if (mounted) setState(() => _clipEvent = null);
  }

  /// The live stream keeps running under a clip, so going back is instant;
  /// this keeps its audio from talking over the clip's.
  void _setLiveAudio(bool enabled) {
    for (final track in _remoteStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  static List<MotionEvent> _upsert(List<MotionEvent> events, MotionEvent event) =>
      [event, ...events.where((e) => e.id != event.id)]..sort((a, b) => b.startedAt.compareTo(a.startedAt));

  String _offlineStatus() {
    final lastSeen = _camera.lastSeenAt;
    return lastSeen == null ? 'Offline' : 'Offline · last seen ${_timeAgo(lastSeen)}';
  }

  /// Drops any stale peer connection and returns to the waiting state, so a
  /// disconnect never leaves the viewer stuck on a frozen frame.
  Future<void> _resetToWaiting(String status) async {
    _watching = false;
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
        _setLiveAudio(_clipEvent == null);
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

  @override
  void dispose() {
    _signaling.socket.off('connect', _onConnect);
    _signaling.socket.off('disconnect', _onDisconnect);
    _signaling.socket.off('peer-left', _onPeerLeft);
    _signaling.socket.off('offer', _onOffer);
    _signaling.socket.off('icecandidate', _signaling.addRemoteIceCandidate);
    _signaling.socket.off('cameras-list', _onRoster);
    _signaling.socket.off('motion', _onMotion);
    if (_signaling.socket.connected) {
      _signaling.socket.emit('stop-watching');
    }
    _signaling.resetConnection();
    _remoteRenderer.dispose();
    _clipPlayer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The State (and so the peer connection and renderer) is the same in
    // both layouts, so rotating never interrupts the stream.
    return OrientationBuilder(
      builder: (context, orientation) =>
          orientation == Orientation.landscape ? _buildLandscape(context) : _buildPortrait(context),
    );
  }

  Widget _buildPortrait(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_camera.name)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(aspectRatio: 16 / 9, child: _buildVideo(landscape: false)),
          Expanded(child: _buildTimeline()),
        ],
      ),
    );
  }

  Widget _buildLandscape(BuildContext context) {
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _buildVideo(landscape: true)),
          if (_showTimeline)
            SizedBox(
              width: _timelinePanelWidth,
              child: SafeArea(left: false, child: _buildTimeline()),
            ),
        ],
      ),
    );
  }

  Widget _buildTimeline() {
    return MotionTimeline(
      events: _events,
      loading: _eventsLoading,
      error: _eventsError,
      onRefresh: _loadEvents,
      selectedId: _clipEvent?.id,
      onSelect: _playClip,
    );
  }

  /// The live feed (or the camera's status while there isn't one), or a
  /// motion clip in its place. In landscape there's no app bar, so the back
  /// button and camera name are overlaid on the video instead.
  Widget _buildVideo({required bool landscape}) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_clipEvent != null)
            SafeArea(
              top: false,
              right: !(landscape && _showTimeline),
              bottom: landscape,
              child: _ClipView(controller: _clipPlayer),
            )
          else if (_isLive)
            RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
          else
            _VideoPlaceholder(
              status: _status,
              offline: !_camera.online,
              onRetry: _camera.online || !_signaling.socket.connected ? _retry : null,
            ),
          SafeArea(
            right: !(landscape && _showTimeline),
            bottom: landscape,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (landscape) ...[
                    _OverlayButton(
                      icon: Icons.arrow_back,
                      tooltip: 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: _Pill(
                        child: Text(
                          _camera.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (_clipEvent != null) ...[
                    _Pill(
                      icon: const Icon(Icons.history, color: Colors.white, size: 14),
                      child: Text(
                        'Clip · ${DateFormat.jm().format(_clipEvent!.startedAt)}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ] else if (_isLive) ...[
                    const _Pill(
                      icon: Icon(Icons.circle, color: Colors.redAccent, size: 10),
                      child: Text(
                        'LIVE',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (_motionNow)
                    const _Pill(
                      icon: PulsingDot(color: Colors.orange, size: 10),
                      child: Text(
                        'Motion now',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                  const Spacer(),
                  if (_clipEvent != null) ...[
                    FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
                      onPressed: _backToLive,
                      icon: const Icon(Icons.sensors),
                      label: const Text('Back to live'),
                    ),
                    if (landscape) const SizedBox(width: 8),
                  ],
                  if (landscape)
                    _OverlayButton(
                      icon: _showTimeline ? Icons.fullscreen : Icons.view_sidebar_outlined,
                      tooltip: _showTimeline ? 'Hide timeline' : 'Show timeline',
                      onPressed: () => setState(() => _showTimeline = !_showTimeline),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A motion clip with play/pause and a scrubbable progress bar.
class _ClipView extends StatelessWidget {
  const _ClipView({required this.controller});

  /// Null while the clip's request is still being set up.
  final VideoPlayerController? controller;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (controller == null) return const Center(child: CircularProgressIndicator());
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        if (!value.isInitialized) return const Center(child: CircularProgressIndicator());
        final finished = value.position >= value.duration;
        return Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(aspectRatio: value.aspectRatio, child: VideoPlayer(controller)),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: Colors.black45,
                child: Row(
                  children: [
                    IconButton(
                      color: Colors.white,
                      icon: Icon(value.isPlaying ? Icons.pause : (finished ? Icons.replay : Icons.play_arrow)),
                      onPressed: () {
                        if (value.isPlaying) {
                          controller.pause();
                        } else if (finished) {
                          controller.seekTo(Duration.zero).then((_) => controller.play());
                        } else {
                          controller.play();
                        }
                      },
                    ),
                    Expanded(
                      child: VideoProgressIndicator(
                        controller,
                        allowScrubbing: true,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        '${_mmss(value.position)} / ${_mmss(value.duration)}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

String _mmss(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder({required this.status, required this.offline, this.onRetry});

  final String status;
  final bool offline;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 56, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(offline ? Icons.videocam_off_outlined : Icons.videocam_outlined, size: 40, color: Colors.white54),
            const SizedBox(height: 12),
            Text(
              status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A translucent rounded label for text over the video.
class _Pill extends StatelessWidget {
  const _Pill({required this.child, this.icon});

  final Widget child;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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

String _timeAgo(DateTime time) {
  final elapsed = DateTime.now().difference(time);
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
  if (elapsed.inDays < 1) return '${elapsed.inHours}h ago';
  return '${elapsed.inDays}d ago';
}
