import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/motion/motion_detector.dart';

/// Stands in for the OpenCV worker: sees motion in any frame whose first
/// byte is non-zero, and ignores anything else it's sent (e.g. a reset).
void _fakeWorker(SendPort responses) {
  final requests = ReceivePort();
  responses.send(requests.sendPort);
  requests.listen((message) {
    if (message is! (int, TransferableTypedData)) return;
    final (id, data) = message;
    responses.send((id, data.materialize().asUint8List().first != 0));
  });
}

/// Whether [isolate] answers a ping within [wait].
Future<bool> _alive(Isolate isolate, {Duration wait = const Duration(seconds: 5)}) async {
  final pong = ReceivePort();
  isolate.ping(pong.sendPort, response: true);
  final answered = await pong.first.then((_) => true).timeout(wait, onTimeout: () => false);
  pong.close();
  return answered;
}

/// Whether [isolate] stops answering pings soon. A kill doesn't land
/// instantly, so a ping sent just after it may still be answered.
Future<bool> _dies(Isolate isolate) async {
  for (var i = 0; i < 10; i++) {
    if (!await _alive(isolate, wait: const Duration(milliseconds: 300))) return true;
  }
  return false;
}

void main() {
  test('detect returns the worker\'s answer', () async {
    final detector = MotionDetector(worker: _fakeWorker);
    expect(await detector.detect(Uint8List.fromList([1])), isTrue);
    expect(await detector.detect(Uint8List.fromList([0])), isFalse);
    await detector.reset();
    expect(await detector.detect(Uint8List.fromList([1])), isTrue);
    detector.dispose();
  });

  test('disposing before the isolate has started still stops it', () async {
    final detector = MotionDetector(worker: _fakeWorker);
    detector.dispose();
    await detector.ready.timeout(const Duration(seconds: 2));
    expect(await _dies(detector.isolate!), isTrue);
  });

  test('detect and reset after an early dispose return instead of hanging', () async {
    final detector = MotionDetector(worker: _fakeWorker);
    detector.dispose();
    expect(await detector.detect(Uint8List.fromList([1])).timeout(const Duration(seconds: 2)), isFalse);
    await detector.reset().timeout(const Duration(seconds: 2));
  });

  test('disposing after start stops the isolate and answers pending frames', () async {
    final detector = MotionDetector(worker: _fakeWorker);
    await detector.ready;
    final isolate = detector.isolate!;
    expect(await _alive(isolate), isTrue);
    detector.dispose();
    expect(await _dies(isolate), isTrue);
  });
}
