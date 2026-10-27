import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'motion_label.dart';

/// Finds people (and cats and dogs) in a frame with YOLOX-Nano, a small
/// COCO object detector (Apache-2.0), run through OpenCV's DNN module.
///
/// It's only run on frames the background-subtraction stage has already
/// flagged as moving, so it costs nothing while the scene is still.
class PersonDetector {
  /// [model] is the bytes of `assets/models/yolox_nano.onnx`.
  PersonDetector(Uint8List model) : _net = cv.Net.fromBytes('onnx', model);

  /// The model's square input size, in pixels.
  static const inputSize = 416;

  /// Minimum objectness × class score for a box to count.
  static const minScore = 0.5;

  static const _personClass = 0;
  static const _catClass = 15;
  static const _dogClass = 16;

  /// Pixel value of the letterbox padding, as YOLOX was trained with.
  static const _padValue = 114.0;
  static const _strides = [8, 16, 32];
  static const _classCount = 80;

  final cv.Net _net;

  /// The most important thing in [frame], a decoded BGR image: a person,
  /// else a pet, else [MotionLabel.motion] for nobody.
  MotionLabel detect(cv.Mat frame) {
    final input = _letterbox(frame);
    // YOLOX takes BGR in 0–255 with no normalisation.
    final blob = cv.blobFromImage(input);
    input.dispose();
    _net.setInput(blob);
    blob.dispose();
    final output = _net.forward();
    final rows = output.total ~/ (5 + _classCount);
    final values = output.data.buffer.asFloat32List(output.data.offsetInBytes, output.total);
    final found = _mostImportant(values, rows);
    output.dispose();
    return found;
  }

  /// Scales [frame] to fit [inputSize] and pads the bottom/right, keeping
  /// its aspect ratio, so people aren't squashed out of shape.
  static cv.Mat _letterbox(cv.Mat frame) {
    final ratio = math.min(inputSize / frame.rows, inputSize / frame.cols);
    final width = (frame.cols * ratio).round();
    final height = (frame.rows * ratio).round();
    final resized = cv.resize(frame, (width, height), interpolation: cv.INTER_LINEAR);
    final padded = cv.copyMakeBorder(
      resized,
      0,
      inputSize - height,
      0,
      inputSize - width,
      cv.BORDER_CONSTANT,
      value: cv.Scalar.all(_padValue),
    );
    resized.dispose();
    return padded;
  }

  /// Reads the raw output rows (`cx, cy, w, h, objectness, 80 class scores`
  /// per anchor). Only scores are needed, not boxes: the question is
  /// whether anyone is in the frame, not where, so no box decoding or NMS.
  static MotionLabel _mostImportant(Float32List values, int rows) {
    assert(rows == _anchorCount, 'unexpected YOLOX output size $rows');
    var found = MotionLabel.motion;
    const stride = 5 + _classCount;
    for (var row = 0; row < rows; row++) {
      final base = row * stride;
      final objectness = values[base + 4];
      if (objectness < minScore) continue;
      if (objectness * values[base + 5 + _personClass] >= minScore) {
        return MotionLabel.person;
      } else if (objectness * math.max(values[base + 5 + _catClass], values[base + 5 + _dogClass]) >= minScore) {
        found = MotionLabel.pet;
      }
    }
    return found;
  }

  static final _anchorCount = _strides.fold(0, (sum, s) => sum + (inputSize ~/ s) * (inputSize ~/ s));

  void dispose() => _net.dispose();
}
