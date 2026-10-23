import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import 'recordings_api.dart';

/// Lists motion clips a specific camera has uploaded to the server, with
/// streamed playback — this is what makes a camera's recordings reachable
/// from Viewer Mode, as opposed to [RecordingsScreen] which only shows
/// clips saved locally on the current device.
class CameraRecordingsScreen extends StatefulWidget {
  const CameraRecordingsScreen({
    super.key,
    required this.api,
    required this.cameraId,
    required this.cameraName,
    required this.canDelete,
  });

  final RecordingsApi api;
  final String cameraId;
  final String cameraName;

  /// Only household owners/admins can delete; the server enforces this too.
  final bool canDelete;

  @override
  State<CameraRecordingsScreen> createState() => _CameraRecordingsScreenState();
}

class _CameraRecordingsScreenState extends State<CameraRecordingsScreen> {
  RecordingsApi get _api => widget.api;
  List<RemoteRecording> _recordings = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final recordings = await _api.listRecordings(widget.cameraId);
      if (!mounted) return;
      setState(() {
        _recordings = recordings;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load recordings: $e';
        _loading = false;
      });
    }
  }

  Future<void> _delete(RemoteRecording recording) async {
    try {
      await _api.deleteRecording(recording.id);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.cameraName} Recordings'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        ElevatedButton(onPressed: _refresh, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : _recordings.isEmpty
                  ? const Center(child: Text('No recordings yet.'))
                  : ListView.builder(
                      itemCount: _recordings.length,
                      itemBuilder: (context, index) {
                        final recording = _recordings[index];
                        final sizeMb = recording.sizeBytes / (1024 * 1024);
                        return ListTile(
                          leading: const Icon(Icons.movie_outlined),
                          title: Text(DateFormat('MMM d, y  h:mm a').format(recording.createdAt)),
                          subtitle: Text('${sizeMb.toStringAsFixed(1)} MB'),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => _RemotePlaybackScreen(
                                api: _api,
                                recordingId: recording.id,
                              ),
                            ),
                          ),
                          trailing: widget.canDelete
                              ? IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _delete(recording),
                                )
                              : null,
                        );
                      },
                    ),
    );
  }
}

class _RemotePlaybackScreen extends StatefulWidget {
  final RecordingsApi api;
  final String recordingId;
  const _RemotePlaybackScreen({required this.api, required this.recordingId});

  @override
  State<_RemotePlaybackScreen> createState() => _RemotePlaybackScreenState();
}

class _RemotePlaybackScreenState extends State<_RemotePlaybackScreen> {
  // Created once the auth headers are in hand, since clips are only served
  // to members of the camera's household.
  VideoPlayerController? _controller;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final headers = await widget.api.fileHeaders();
      if (!mounted) return;
      final controller = VideoPlayerController.networkUrl(
        widget.api.fileUrl(widget.recordingId),
        httpHeaders: headers,
      );
      _controller = controller;
      await controller.initialize();
      if (!mounted) return;
      setState(() => _ready = true);
      controller.play();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not play recording: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playback')),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              )
            : _ready
                ? AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio,
                    child: VideoPlayer(_controller!),
                  )
                : const CircularProgressIndicator(),
      ),
      floatingActionButton: _ready
          ? FloatingActionButton(
              onPressed: () {
                final controller = _controller!;
                setState(() {
                  controller.value.isPlaying ? controller.pause() : controller.play();
                });
              },
              child: Icon(_controller!.value.isPlaying ? Icons.pause : Icons.play_arrow),
            )
          : null,
    );
  }
}
