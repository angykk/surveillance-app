import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Background-subtraction motion detector.
///
/// Feed it successive camera frames (JPEG/PNG-encoded bytes, as returned by
/// `MediaStreamTrack.captureFrame()`) via [detect]. It maintains a running
/// MOG2 background model and reports whether the latest frame contains a
/// foreground blob large enough to count as motion, filtering out sensor
/// noise and minor lighting changes.
class MotionDetector {
  MotionDetector({
    this.minContourArea = 1500,
    this.warmupFrames = 10,
  })  : _bgSubtractor = cv.BackgroundSubtractorMOG2.create(
          history: 300,
          varThreshold: 40,
          detectShadows: false,
        ),
        _dilateKernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));

  /// Minimum foreground contour area (in pixels) to count as motion, rather
  /// than noise.
  final double minContourArea;

  /// MOG2 starts with an empty background model, so its first several frames
  /// read as "all foreground". Discard detections until it has stabilized.
  final int warmupFrames;

  final cv.BackgroundSubtractorMOG2 _bgSubtractor;
  final cv.Mat _dilateKernel;
  int _framesSeen = 0;

  bool detect(Uint8List encodedFrame) {
    final frame = cv.imdecode(encodedFrame, cv.IMREAD_COLOR);
    final foregroundMask = _bgSubtractor.apply(frame);
    frame.dispose();
    _framesSeen++;

    final (_, thresholded) = cv.threshold(foregroundMask, 200, 255, cv.THRESH_BINARY);
    foregroundMask.dispose();

    final dilated = cv.dilate(thresholded, _dilateKernel);
    thresholded.dispose();

    final (contours, hierarchy) = cv.findContours(
      dilated,
      cv.RETR_EXTERNAL,
      cv.CHAIN_APPROX_SIMPLE,
    );
    dilated.dispose();
    hierarchy.dispose();

    final hasMotion = _framesSeen > warmupFrames &&
        contours.any((contour) => cv.contourArea(contour) >= minContourArea);
    contours.dispose();

    return hasMotion;
  }

  void dispose() {
    _bgSubtractor.dispose();
    _dilateKernel.dispose();
  }
}
