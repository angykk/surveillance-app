import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:video_player/video_player.dart';

import '../api/api_client.dart';
import '../api/motion_api.dart';
import '../signaling/signaling_client.dart';
import 'app_theme.dart';
import 'camera_list_screen.dart';
import 'clip_actions.dart';
import 'motion_timeline.dart';
import 'shared_widgets.dart';

/// Width of the motion timeline beside the video in landscape.
const _timelinePanelWidth = 320.0;

/// Watches a single camera over an already-connected [SignalingClient] that
/// the caller (CameraListScreen) owns — this screen pairs with `camera` via
/// a `watch-camera` event rather than opening its own socket, so switching
/// cameras doesn't mean reconnecting to the server each time. The server
/// answers with a grant for the camera's LiveKit room, which carries the
/// video itself.
///
/// The feed is horizontal (cameras run in landscape), so in portrait it sits
/// at the top as a 16:9 panel with the camera's motion timeline below; in
/// landscape the video takes the screen with the timeline as a side panel.
/// Tapping an event with a clip plays it in the video panel in place of the
/// live feed, until "Back to live". A clip can be shared from its row or
/// while it plays, and owners and admins ([canManage]) can delete it. Offline cameras open here too: the
/// timeline and clips still work, and the stream starts by itself once the
/// camera comes back online.
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({
    super.key,
    required this.signaling,
    required this.camera,
    required this.motionApi,
    required this.canManage,
  });

  final SignalingClient signaling;
  final CameraInfo camera;
  final MotionApi motionApi;

  /// Whether the user is an owner or admin of the camera's household, so
  /// can delete its events.
  final bool canManage;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  late CameraInfo _camera = widget.camera;

  /// The camera's LiveKit room while watching, and the tracks it's sending.
  Room? _room;
  EventsListener<RoomEvent>? _roomListener;
  VideoTrack? _videoTrack;
  RemoteAudioTrack? _audioTrack;

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
  late final void Function(dynamic) _onRoster;
  late final void Function(dynamic) _onMotion;
  late final void Function(dynamic) _onMotionDeleted;

  @override
  void initState() {
    super.initState();
    _onConnect = (_) {
      if (_camera.online) _watchCamera();
    };
    // Fires when this viewer's own connection drops (briefly, before
    // socket_io_client's automatic reconnect kicks in).
    _onDisconnect = (_) => _resetToWaiting('Disconnected — reconnecting…');
    // Fires when the *camera* disconnects while this viewer stays connected
    // to the signaling server.
    _onPeerLeft = (_) => _resetToWaiting(_camera.online ? '${_camera.name} disconnected' : _offlineStatus());
    _onRoster = _handleRoster;
    _onMotion = _handleMotion;
    _onMotionDeleted = (data) {
      final map = data as Map;
      if (map['camera_id'] == _camera.id) _removeEvent(map['id'] as String);
    };

    _signaling.socket.on('connect', _onConnect);
    _signaling.socket.on('disconnect', _onDisconnect);
    _signaling.socket.on('peer-left', _onPeerLeft);
    _signaling.socket.on('cameras-list', _onRoster);
    _signaling.socket.on('motion', _onMotion);
    _signaling.socket.on('motion-deleted', _onMotionDeleted);

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
    _signaling.socket.emitWithAck('watch-camera', {'camera_id': _camera.id}, ack: (data) {
      // No grant means the camera can't be watched; `peer-left` handles that.
      final grant = StreamGrant.fromJson(data);
      if (grant != null && mounted && _watching) _joinRoom(grant);
    });
  }

  Future<void> _joinRoom(StreamGrant grant) async {
    await _leaveRoom();
    final room = Room();
    final listener = room.createListener()
      ..on<TrackSubscribedEvent>((event) {
        if (_room != room || !mounted) return;
        final track = event.track;
        if (track is VideoTrack) {
          setState(() {
            _videoTrack = track;
            _isLive = true;
            _status = 'Live';
          });
        } else if (track is RemoteAudioTrack) {
          _audioTrack = track;
          _setLiveAudio(_clipEvent == null);
        }
      })
      // The camera stopped publishing but may still be around (e.g.
      // reconnecting); `peer-left` covers it going away for good.
      ..on<TrackUnsubscribedEvent>((event) {
        if (_room != room || !mounted || event.track != _videoTrack) return;
        setState(() {
          _videoTrack = null;
          _isLive = false;
          _status = 'Waiting for ${_camera.name}…';
        });
      })
      // E.g. LiveKit unreachable, or the room closed because the camera
      // was removed.
      ..on<RoomDisconnectedEvent>((_) {
        if (_room == room) _resetToWaiting('Live stream disconnected');
      });
    _room = room;
    _roomListener = listener;

    try {
      await room.connect(grant.url, grant.token);
    } catch (e) {
      debugPrint('Joining LiveKit room failed: $e');
      if (_room == room) _resetToWaiting('Could not connect to the live stream');
    }
  }

  /// Leaves the camera's room, if in one, without touching the UI.
  Future<void> _leaveRoom() async {
    final room = _room;
    final listener = _roomListener;
    _room = null;
    _roomListener = null;
    _videoTrack = null;
    _audioTrack = null;
    await listener?.dispose();
    await room?.disconnect();
    await room?.dispose();
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
      final controller = VideoPlayerController.networkUrl(await widget.motionApi.clipUrl(event.id));
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

  void _shareEvent(MotionEvent event, BuildContext origin) => shareClip(
        context,
        motionApi: widget.motionApi,
        event: event,
        cameraName: _camera.name,
        origin: origin,
      );

  Future<void> _deleteEvent(MotionEvent event) async {
    if (!await confirmDeleteEvent(context)) return;
    try {
      await widget.motionApi.deleteEvent(event.id);
      // Other viewers hear about it over the socket; this one needn't wait.
      _removeEvent(event.id);
    } catch (e) {
      if (!mounted) return;
      final message = e is ApiException && e.statusCode == 409
          ? 'Still recording — try again once the motion ends.'
          : 'Could not delete event: $e';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Drops a deleted event, and its clip if that's what's playing.
  void _removeEvent(String eventId) {
    if (!mounted) return;
    if (_clipEvent?.id == eventId) _backToLive();
    setState(() => _events = _events.where((e) => e.id != eventId).toList());
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
    final track = _audioTrack;
    if (track == null) return;
    enabled ? track.enable() : track.disable();
  }

  static List<MotionEvent> _upsert(List<MotionEvent> events, MotionEvent event) =>
      [event, ...events.where((e) => e.id != event.id)]..sort((a, b) => b.startedAt.compareTo(a.startedAt));

  String _offlineStatus() {
    final lastSeen = _camera.lastSeenAt;
    return lastSeen == null ? 'Offline' : 'Offline · last seen ${_timeAgo(lastSeen)}';
  }

  /// Leaves the camera's room and returns to the waiting state, so a
  /// disconnect never leaves the viewer stuck on a frozen frame.
  Future<void> _resetToWaiting(String status) async {
    _watching = false;
    if (mounted) {
      // Take the video off screen before the room (and its track) goes.
      setState(() {
        _videoTrack = null;
        _isLive = false;
        _status = status;
      });
      await WidgetsBinding.instance.endOfFrame;
    }
    await _leaveRoom();
  }

  @override
  void dispose() {
    _signaling.socket.off('connect', _onConnect);
    _signaling.socket.off('disconnect', _onDisconnect);
    _signaling.socket.off('peer-left', _onPeerLeft);
    _signaling.socket.off('cameras-list', _onRoster);
    _signaling.socket.off('motion', _onMotion);
    _signaling.socket.off('motion-deleted', _onMotionDeleted);
    if (_signaling.socket.connected) {
      _signaling.socket.emit('stop-watching');
    }
    _leaveRoom();
    _clipPlayer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The State (and so the LiveKit room) is the same in
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
      onShare: _shareEvent,
      onDelete: widget.canManage ? _deleteEvent : null,
    );
  }

  /// The live feed (or the camera's status while there isn't one), or a
  /// motion clip in its place. In landscape there's no app bar, so the back
  /// button and camera name are overlaid on the video instead.
  Widget _buildVideo({required bool landscape}) {
    return ColoredBox(
      color: AppColors.black,
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
          else if (_isLive && _videoTrack != null)
            VideoTrackRenderer(_videoTrack!, fit: VideoViewFit.contain, mirrorMode: VideoViewMirrorMode.off)
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
                    OverlayButton(
                      icon: Icons.arrow_back,
                      tooltip: 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 8),
                  ],
                  // The pills wrap onto a second line rather than overflow
                  // when they don't fit beside the buttons, e.g. a clip
                  // playing during motion on a narrow portrait screen.
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (landscape)
                          OverlayPill(padding: _pillPadding, 
                            child: Text(
                              _camera.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: AppColors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                        if (_clipEvent != null)
                          OverlayPill(padding: _pillPadding, 
                            icon: const Icon(Icons.history, color: AppColors.white, size: 14),
                            child: Text(
                              'Clip · ${DateFormat.jm().format(_clipEvent!.startedAt)}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: AppColors.white, fontWeight: FontWeight.bold),
                            ),
                          )
                        else if (_isLive)
                          const OverlayPill(padding: _pillPadding, 
                            icon: Icon(Icons.circle, color: AppColors.lightRed, size: 10),
                            child: Text(
                              'LIVE',
                              style: TextStyle(color: AppColors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                        if (_motionNow)
                          const OverlayPill(padding: _pillPadding, 
                            icon: PulsingDot(color: AppColors.taupe, size: 10),
                            child: Text(
                              'Motion now',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: AppColors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_clipEvent != null) ...[
                    Builder(
                      builder: (buttonContext) => OverlayButton(
                        icon: Icons.ios_share,
                        tooltip: 'Share clip',
                        onPressed: () => _shareEvent(_clipEvent!, buttonContext),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (widget.canManage) ...[
                      OverlayButton(
                        icon: Icons.delete_outline,
                        tooltip: 'Delete event',
                        onPressed: () => _deleteEvent(_clipEvent!),
                      ),
                      const SizedBox(width: 8),
                    ],
                    FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: AppColors.overlay, foregroundColor: AppColors.white),
                      onPressed: _backToLive,
                      icon: const Icon(Icons.sensors),
                      label: const Text('Back to live'),
                    ),
                    if (landscape) const SizedBox(width: 8),
                  ],
                  if (landscape)
                    OverlayButton(
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
    if (controller == null) return const Center(child: CircularProgressIndicator(color: AppColors.white));
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        if (!value.isInitialized) return const Center(child: CircularProgressIndicator(color: AppColors.white));
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
                color: AppColors.overlay,
                child: Row(
                  children: [
                    IconButton(
                      color: AppColors.white,
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
                        colors: VideoProgressColors(
                          playedColor: AppColors.white,
                          bufferedColor: AppColors.white.withValues(alpha: 0.3),
                          backgroundColor: AppColors.white.withValues(alpha: 0.12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        '${_mmss(value.position)} / ${_mmss(value.duration)}',
                        style: TextStyle(color: AppColors.white.withValues(alpha: 0.7)),
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

/// Pills over the viewer's video are a little smaller than the camera
/// phone's: they share the frame with the motion timeline.
const _pillPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 6);

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder({required this.status, required this.offline, this.onRetry});

  final String status;
  final bool offline;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return MessageView(
      icon: offline ? Icons.videocam_off_outlined : Icons.videocam_outlined,
      iconSize: 40,
      iconColor: AppColors.white.withValues(alpha: 0.55),
      message: status,
      textColor: AppColors.white.withValues(alpha: 0.7),
      padding: const EdgeInsets.fromLTRB(24, 56, 24, 16),
      actionSpacing: 8,
      action: onRetry == null
          ? null
          : TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: AppColors.white),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
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
