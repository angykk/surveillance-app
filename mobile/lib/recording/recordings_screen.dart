import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import 'recording_manager.dart';

/// Lists locally saved recordings with basic play/delete controls. Opened
/// from Viewer Mode, where clips of the incoming camera stream are recorded.
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key});

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  final _manager = RecordingManager();
  List<File> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final files = await _manager.listRecordings();
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  Future<void> _delete(File file) async {
    await _manager.deleteRecording(file);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? const Center(child: Text('No recordings yet.'))
              : ListView.builder(
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    final file = _files[index];
                    final modified = file.statSync().modified;
                    final sizeMb = file.statSync().size / (1024 * 1024);
                    return ListTile(
                      leading: const Icon(Icons.movie_outlined),
                      title: Text(DateFormat('MMM d, y  h:mm a').format(modified)),
                      subtitle: Text('${sizeMb.toStringAsFixed(1)} MB'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => _PlaybackScreen(file: file)),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(file),
                      ),
                    );
                  },
                ),
    );
  }
}

class _PlaybackScreen extends StatefulWidget {
  final File file;
  const _PlaybackScreen({required this.file});

  @override
  State<_PlaybackScreen> createState() => _PlaybackScreenState();
}

class _PlaybackScreenState extends State<_PlaybackScreen> {
  late final VideoPlayerController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(widget.file)
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        _controller.play();
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playback')),
      body: Center(
        child: _ready
            ? AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              )
            : const CircularProgressIndicator(),
      ),
      floatingActionButton: _ready
          ? FloatingActionButton(
              onPressed: () {
                setState(() {
                  _controller.value.isPlaying ? _controller.pause() : _controller.play();
                });
              },
              child: Icon(_controller.value.isPlaying ? Icons.pause : Icons.play_arrow),
            )
          : null,
    );
  }
}
