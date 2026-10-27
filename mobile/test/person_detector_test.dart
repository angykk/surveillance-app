import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/motion/motion_label.dart';
import 'package:mobile/motion/person_detector.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

void main() {
  late PersonDetector detector;

  setUpAll(() => detector = PersonDetector(File('assets/models/yolox_nano.onnx').readAsBytesSync()));
  tearDownAll(() => detector.dispose());

  MotionLabel detectIn(String fixture) {
    final frame = cv.imread('test/fixtures/$fixture');
    final watch = Stopwatch()..start();
    final found = detector.detect(frame);
    // ignore: avoid_print
    print('$fixture: $found in ${watch.elapsedMilliseconds} ms');
    frame.dispose();
    return found;
  }

  test('finds the person in a photo of one', () {
    expect(detectIn('person.jpg'), MotionLabel.person);
  });

  test('finds no one in a photo of fruit', () {
    expect(detectIn('no_person.jpg'), MotionLabel.motion);
  });
}
