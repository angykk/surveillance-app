import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Manages recorded clip files on local storage: where they live, how
/// they're named, and basic listing/deletion.
class RecordingManager {
  static const _dirName = 'recordings';

  Future<Directory> getRecordingsDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, _dirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _timestampedFileName() {
    final now = DateTime.now();
    final stamp = DateFormat('yyyy-MM-dd_HH-mm-ss').format(now);
    return 'clip_$stamp.mp4';
  }

  /// Reserves a timestamped destination for a new recording. The recorder
  /// writes directly to this path, so unlike a plugin that hands back a
  /// finished temp file, there's nothing to move afterwards.
  Future<File> newRecordingFile() async {
    final dir = await getRecordingsDirectory();
    return File(p.join(dir.path, _timestampedFileName()));
  }

  Future<List<File>> listRecordings() async {
    final dir = await getRecordingsDirectory();
    final entries = await dir.list().toList();
    final files = entries.whereType<File>().where((f) => f.path.endsWith('.mp4')).toList();
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }

  Future<void> deleteRecording(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
  }
}
