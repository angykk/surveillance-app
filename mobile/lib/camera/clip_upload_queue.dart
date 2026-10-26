import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api/api_client.dart';
import '../api/motion_api.dart';

/// Motion clips and thumbnails waiting to be uploaded, kept on disk until
/// the server has them, so a dropped connection or a server restart doesn't
/// lose one.
///
/// Each is a file named `<event id>.mp4` (or `.jpg`) in an app-support folder
/// (which, unlike the temp folder, the OS doesn't clear), so the queue
/// survives the app being killed. Uploads go one at a time, oldest first,
/// whenever [drain] runs: after a clip is added, when the camera's socket
/// reconnects, and on a timer.
class ClipUploadQueue {
  /// [folder] stands in for the app-support folder, and [maxBytes] for the
  /// size limit, in tests.
  ClipUploadQueue(
    this._motionApi, {
    @visibleForTesting Future<Directory> Function()? folder,
    @visibleForTesting this.maxBytes = 500 * 1024 * 1024,
  }) : _baseFolder = folder;

  final MotionApi _motionApi;
  final Future<Directory> Function()? _baseFolder;

  /// Past this, the oldest clips are dropped to make room, so a camera that
  /// can't reach the server for days doesn't fill the phone.
  final int maxBytes;

  Directory? _dir;
  bool _draining = false;
  bool _drainAgain = false;

  Future<Directory> _folder() async {
    final existing = _dir;
    if (existing != null) return existing;
    final base = await (_baseFolder ?? getApplicationSupportDirectory)();
    final dir = Directory('${base.path}/pending-clips');
    await dir.create(recursive: true);
    // A clip still being recorded when the app died never got its event id
    // matched up, and may not be a playable file anyway.
    await for (final entity in dir.list()) {
      if (entity is File && _isRecording(entity)) await _delete(entity);
    }
    return _dir = dir;
  }

  /// Where to record a new clip. Hand it to [add] once recording stops, or
  /// [discard] it.
  Future<File> newRecordingFile() async {
    final dir = await _folder();
    // Still .mp4: the platform recorders may go by the extension.
    return File('${dir.path}/$_recordingPrefix${DateTime.now().millisecondsSinceEpoch}.mp4');
  }

  static const _recordingPrefix = 'recording-';

  static bool _isRecording(File file) => file.uri.pathSegments.last.startsWith(_recordingPrefix);

  /// Queues a finished recording for [eventId] and starts uploading.
  Future<void> add(File recording, String eventId) async {
    final dir = await _folder();
    try {
      await recording.rename('${dir.path}/$eventId$_clipExtension');
    } catch (e) {
      debugPrint('Queuing clip for $eventId failed: $e');
      await _delete(recording);
      return;
    }
    unawaited(drain());
  }

  Future<void> discard(File recording) => _delete(recording);

  /// Queues [jpeg] as [eventId]'s thumbnail and starts uploading. It's
  /// written when motion starts, so it goes up ahead of the event's clip.
  Future<void> addThumbnail(Uint8List jpeg, String eventId) async {
    final dir = await _folder();
    try {
      await File('${dir.path}/$eventId$_thumbnailExtension').writeAsBytes(jpeg, flush: true);
    } catch (e) {
      debugPrint('Queuing thumbnail for $eventId failed: $e');
      return;
    }
    unawaited(drain());
  }

  static const _clipExtension = '.mp4';
  static const _thumbnailExtension = '.jpg';

  /// Uploads every queued clip it can, after dropping the oldest if the
  /// queue is over [maxBytes]. Safe to call any time: overlapping calls fold
  /// into the one already running. The size limit is enforced here, between
  /// uploads, rather than in [add], so it can't delete the clip that's
  /// uploading or a file [_queued] is still looking at.
  Future<void> drain() async {
    if (_draining) {
      _drainAgain = true;
      return;
    }
    _draining = true;
    try {
      do {
        _drainAgain = false;
        await _enforceLimit();
        for (final clip in await _queued()) {
          if (!await _upload(clip)) return;
        }
      } while (_drainAgain);
    } catch (e) {
      // Nobody awaits a drain, so an error here would go uncaught.
      debugPrint('Draining clip queue failed: $e');
    } finally {
      _draining = false;
    }
  }

  /// Uploads one clip or thumbnail, removing it once the server has it or
  /// can never take it. Returns false to stop draining (a network or server
  /// problem that will hit the rest of the queue too).
  Future<bool> _upload(File clip) async {
    final name = clip.uri.pathSegments.last;
    final isThumbnail = name.endsWith(_thumbnailExtension);
    final eventId = name.substring(0, name.lastIndexOf('.'));
    try {
      if (isThumbnail) {
        await _motionApi.uploadThumbnail(eventId, clip);
      } else {
        await _motionApi.uploadClip(eventId, clip);
      }
    } on ApiException catch (e) {
      if (!_isPermanent(e.statusCode)) {
        debugPrint('Clip upload for $eventId failed, will retry: $e');
        return false;
      }
      // E.g. the event is gone (retention, or the camera was re-paired) or
      // already has its clip from an earlier try.
      debugPrint('Dropping clip for $eventId: $e');
    } catch (e) {
      debugPrint('Clip upload for $eventId failed, will retry: $e');
      return false;
    }
    await _delete(clip);
    return true;
  }

  /// 4xx answers that retrying can't fix. 401 isn't one: the camera's
  /// token was revoked, and Camera Mode is already unpairing it.
  static bool _isPermanent(int status) =>
      status >= 400 && status < 500 && status != 401 && status != 408 && status != 429;

  /// Queued clips and thumbnails, oldest first. A clip deleted while this looks (e.g. a
  /// [discard], or one the server just took) is left out.
  Future<List<File>> _queued() async {
    final dir = await _folder();
    final modified = <File, DateTime>{};
    await for (final entity in dir.list()) {
      if (entity is! File || _isRecording(entity)) continue;
      if (!entity.path.endsWith(_clipExtension) && !entity.path.endsWith(_thumbnailExtension)) continue;
      try {
        modified[entity] = await entity.lastModified();
      } on FileSystemException {
        continue;
      }
    }
    // On a tie (timestamps can be whole seconds), thumbnails first: they're
    // small, and what a viewer sees first.
    int rank(File f) => f.path.endsWith(_thumbnailExtension) ? 0 : 1;
    return modified.keys.toList()
      ..sort((a, b) {
        final byAge = modified[a]!.compareTo(modified[b]!);
        return byAge != 0 ? byAge : rank(a).compareTo(rank(b));
      });
  }

  Future<void> _enforceLimit() async {
    final files = await _queued();
    var total = 0;
    final sizes = <File, int>{};
    for (final f in files) {
      try {
        total += sizes[f] = await f.length();
      } on FileSystemException {
        sizes[f] = 0;
      }
    }
    for (final f in files) {
      if (total <= maxBytes) break;
      debugPrint('Clip queue over ${maxBytes ~/ (1024 * 1024)} MB, dropping ${f.path}');
      total -= sizes[f]!;
      await _delete(f);
    }
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } catch (_) {}
  }
}
