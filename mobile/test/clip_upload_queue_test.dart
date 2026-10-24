import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/api/api_client.dart';
import 'package:mobile/api/motion_api.dart';
import 'package:mobile/camera/clip_upload_queue.dart';

/// Records uploads, and answers each one with whatever [respond] says.
class _FakeMotionApi implements MotionApi {
  final uploads = <String>[];

  /// Whether each clip's file still existed when its upload finished.
  final existedAtEnd = <String, bool>{};

  Future<void> Function(String eventId) respond = (_) async {};

  @override
  Future<void> uploadClip(String eventId, File file) async {
    uploads.add(eventId);
    try {
      await respond(eventId);
    } finally {
      existedAtEnd[eventId] = file.existsSync();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory base;
  late _FakeMotionApi api;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('clip-queue-test');
    api = _FakeMotionApi();
  });

  tearDown(() => base.delete(recursive: true));

  ClipUploadQueue queue({int maxBytes = 1 << 30}) => ClipUploadQueue(api, folder: () async => base, maxBytes: maxBytes);

  List<String> queuedIds() => Directory('${base.path}/pending-clips')
      .listSync()
      .map((e) => e.uri.pathSegments.last)
      .where((name) => !name.startsWith('recording-'))
      .map((name) => name.replaceAll('.mp4', ''))
      .toList()
    ..sort();

  /// Records a clip of [bytes] bytes, last modified [age] ago.
  Future<File> recording(ClipUploadQueue q, {int bytes = 4, Duration age = Duration.zero}) async {
    final file = await q.newRecordingFile();
    await file.writeAsBytes(List.filled(bytes, 0));
    await file.setLastModified(DateTime.now().subtract(age));
    return file;
  }

  /// Lets the unawaited drain kicked off by `add` run to completion.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  test('uploads queued clips oldest first and removes them once sent', () async {
    final q = queue();
    // Seed the folder directly so both are queued before the first drain.
    await q.newRecordingFile();
    final dir = Directory('${base.path}/pending-clips');
    await File('${dir.path}/newer.mp4').writeAsBytes([0]);
    await File('${dir.path}/older.mp4').writeAsBytes([0]);
    await File('${dir.path}/older.mp4').setLastModified(DateTime.now().subtract(const Duration(hours: 1)));

    await q.drain();
    expect(api.uploads, ['older', 'newer']);
    expect(queuedIds(), isEmpty);
  });

  test('keeps a clip for retry on a 401 or a network error, and stops draining', () async {
    final q = queue();
    api.respond = (_) async => throw ApiException(401, 'revoked');
    await q.add(await recording(q, age: const Duration(minutes: 2)), 'a');
    await settle();
    await q.add(await recording(q), 'b');
    await settle();
    // Each drain stops at the first failure, so 'b' never goes up.
    expect(api.uploads, ['a', 'a']);
    expect(queuedIds(), ['a', 'b']);

    api.respond = (_) async => throw const SocketException('offline');
    await q.drain();
    expect(queuedIds(), ['a', 'b']);
  });

  test('drops a clip the server can never take', () async {
    final q = queue();
    api.respond = (_) async => throw ApiException(404, 'event gone');
    await q.add(await recording(q), 'gone');
    await settle();
    expect(queuedIds(), isEmpty);
  });

  test('drops the oldest clips once over the size limit', () async {
    final q = queue(maxBytes: 10);
    api.respond = (_) async => throw const SocketException('offline');
    await q.add(await recording(q, bytes: 6, age: const Duration(minutes: 3)), 'oldest');
    await settle();
    await q.add(await recording(q, bytes: 6, age: const Duration(minutes: 2)), 'middle');
    await settle();
    await q.add(await recording(q, bytes: 4, age: const Duration(minutes: 1)), 'newest');
    await settle();
    expect(queuedIds(), ['middle', 'newest']);
  });

  test('never deletes the clip that is uploading to make room', () async {
    final q = queue(maxBytes: 10);
    final release = Completer<void>();
    api.respond = (id) => id == 'first' ? release.future : Future.value();

    await q.add(await recording(q, bytes: 8, age: const Duration(minutes: 1)), 'first');
    await settle();
    expect(api.uploads, ['first']);

    // Over the limit while 'first' is still going up: this used to delete
    // 'first' (the oldest) out from under its upload.
    await q.add(await recording(q, bytes: 8), 'second');
    await settle();
    expect(File('${base.path}/pending-clips/first.mp4').existsSync(), isTrue);

    release.complete();
    await settle();
    expect(api.existedAtEnd, {'first': true, 'second': true});
    expect(api.uploads, ['first', 'second']);
    expect(queuedIds(), isEmpty);
  });

  test('a clip discarded while draining is skipped, not an error', () async {
    final q = queue();
    final a = await recording(q, age: const Duration(minutes: 1));
    await q.add(a, 'a');
    await settle();
    final b = await recording(q);
    final release = Completer<void>();
    api.respond = (_) => release.future;
    final drained = q.drain();
    await q.discard(b);
    release.complete();
    await expectLater(drained, completes);
  });

  test('leftover in-progress recordings are cleared on start', () async {
    final dir = Directory('${base.path}/pending-clips')..createSync(recursive: true);
    File('${dir.path}/recording-123.mp4').writeAsBytesSync([0]);
    await queue().drain();
    expect(dir.listSync(), isEmpty);
    expect(api.uploads, isEmpty);
  });
}
