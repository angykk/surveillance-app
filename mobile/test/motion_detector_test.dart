import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/motion/motion_detector.dart';
import 'package:mobile/motion/motion_label.dart';

/// Stands in for the OpenCV worker: sees motion in any frame whose first
/// byte is non-zero, labelled by that byte minus one (1 is plain motion, 3 a
/// person), and ignores anything else it's sent (e.g. a reset). It can see
/// people only if it was given a model.
void _fakeWorker(WorkerStart start) {
  final (responses, model) = start;
  final requests = ReceivePort();
  responses.send((requests.sendPort, model != null));
  requests.listen((message) {
    if (message is! (int, TransferableTypedData)) return;
    final (id, data) = message;
    final first = data.materialize().asUint8List().first;
    responses.send((id, first != 0, first == 0 ? 0 : first - 1));
  });
}

Future<Uint8List?> _fakeModel() async => Uint8List(1);

MotionDetector _detector({Future<Uint8List?> Function() loadModel = _fakeModel}) =>
    MotionDetector(worker: _fakeWorker, loadModel: loadModel);

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
    final detector = _detector();
    expect(await detector.canSeePeople, isTrue);
    expect(await detector.detect(Uint8List.fromList([1])), (motion: true, label: MotionLabel.motion));
    expect(await detector.detect(Uint8List.fromList([3])), (motion: true, label: MotionLabel.person));
    expect(await detector.detect(Uint8List.fromList([0])), (motion: false, label: MotionLabel.motion));
    await detector.reset();
    expect((await detector.detect(Uint8List.fromList([1]))).motion, isTrue);
    detector.dispose();
  });

  test('without a model it still sees motion, but not people', () async {
    final detector = _detector(loadModel: () async => null);
    expect(await detector.canSeePeople, isFalse);
    expect((await detector.detect(Uint8List.fromList([1]))).motion, isTrue);
    detector.dispose();
  });

  test('disposing before the isolate has started still stops it', () async {
    final detector = _detector();
    detector.dispose();
    await detector.ready.timeout(const Duration(seconds: 2));
    expect(await _dies(detector.isolate!), isTrue);
  });

  test('detect and reset after an early dispose return instead of hanging', () async {
    final detector = _detector();
    detector.dispose();
    expect((await detector.detect(Uint8List.fromList([1])).timeout(const Duration(seconds: 2))).motion, isFalse);
    await detector.reset().timeout(const Duration(seconds: 2));
  });

  test('disposing after start stops the isolate and answers pending frames', () async {
    final detector = _detector();
    await detector.ready;
    final isolate = detector.isolate!;
    expect(await _alive(isolate), isTrue);
    detector.dispose();
    expect(await _dies(isolate), isTrue);
  });
}
