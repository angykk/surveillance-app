import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Background-subtraction motion detector.
///
/// Feed it successive camera frames (JPEG/PNG-encoded bytes, as returned by
/// `MediaStreamTrack.captureFrame()`) via [detect]. It maintains a running
/// MOG2 background model and reports whether the latest frame contains a
/// foreground blob large enough to count as motion, filtering out sensor
/// noise and minor lighting changes.
///
/// The work runs on its own isolate: decoding and processing a frame every
/// second on the UI isolate made the camera screen stutter, and froze it once
/// a warm, throttled phone took longer than a second per frame.
class MotionDetector {
  /// [worker] stands in for the OpenCV worker in tests.
  MotionDetector({@visibleForTesting void Function(SendPort responses) worker = _workerMain}) {
    _ready = _start(worker);
  }

  late final Future<void> _ready;
  Isolate? _isolate;
  final _handshake = Completer<SendPort?>();
  SendPort? _requests;
  final _responses = ReceivePort();
  final _pending = <int, Completer<bool>>{};
  int _nextId = 0;
  bool _disposed = false;

  Future<void> _start(void Function(SendPort) worker) async {
    _responses.listen((message) {
      if (message is SendPort) {
        if (!_handshake.isCompleted) _handshake.complete(message);
      } else if (message is (int, bool)) {
        _pending.remove(message.$1)?.complete(message.$2);
      }
    });
    final isolate = await Isolate.spawn(worker, _responses.sendPort, debugName: 'motion-detector');
    _isolate = isolate;
    // Disposed while the isolate was starting: [dispose] had nothing to
    // kill yet, so the isolate would have run on, unused, for good.
    if (_disposed) {
      isolate.kill(priority: Isolate.immediate);
      return;
    }
    _requests = await _handshake.future;
  }

  @visibleForTesting
  Future<void> get ready => _ready;

  @visibleForTesting
  Isolate? get isolate => _isolate;

  /// Whether [encodedFrame] shows motion against the frames before it.
  Future<bool> detect(Uint8List encodedFrame) async {
    await _ready;
    if (_disposed) return false;
    final id = _nextId++;
    final result = Completer<bool>();
    _pending[id] = result;
    _requests!.send((id, TransferableTypedData.fromList([encodedFrame])));
    return result.future;
  }

  /// Forgets the learned background and restarts the warmup. Call whenever
  /// the camera is reopened: a fresh camera spends its first moments settling
  /// exposure, white balance and focus, and against the old camera's
  /// background those frames read as motion across the whole picture.
  Future<void> reset() async {
    await _ready;
    if (_disposed) return;
    _requests!.send(_resetRequest);
  }

  void dispose() {
    _disposed = true;
    // The isolate's OpenCV objects go with it.
    _isolate?.kill(priority: Isolate.immediate);
    _responses.close();
    // The handshake can't arrive on the closed port; don't leave [_ready]
    // waiting on it forever.
    if (!_handshake.isCompleted) _handshake.complete(null);
    for (final pending in _pending.values) {
      pending.complete(false);
    }
    _pending.clear();
  }
}

const _resetRequest = 'reset';

void _workerMain(SendPort responses) {
  final requests = ReceivePort();
  responses.send(requests.sendPort);
  var detector = _Mog2Detector();
  requests.listen((message) {
    if (message == _resetRequest) {
      detector.dispose();
      detector = _Mog2Detector();
      return;
    }
    final (id, data) = message as (int, TransferableTypedData);
    var motion = false;
    try {
      motion = detector.detect(data.materialize().asUint8List());
    } catch (_) {
      // Best-effort: an undecodable frame just counts as no motion.
    }
    responses.send((id, motion));
  });
}

class _Mog2Detector {
  _Mog2Detector()
      : _bgSubtractor = cv.BackgroundSubtractorMOG2.create(
          history: 300,
          varThreshold: 40,
          detectShadows: false,
        ),
        _dilateKernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));

  /// Minimum foreground contour area (in pixels of the quarter-size frame)
  /// to count as motion, rather than noise. About 1500 pixels at 720p.
  static const minContourArea = 100.0;

  /// MOG2 starts with an empty background model, so its first several frames
  /// read as "all foreground". Discard detections until it has stabilized.
  static const warmupFrames = 10;

  final cv.BackgroundSubtractorMOG2 _bgSubtractor;
  final cv.Mat _dilateKernel;
  int _framesSeen = 0;

  bool detect(Uint8List encodedFrame) {
    // A quarter-size grayscale frame is plenty to see movement, and makes
    // the background model 48 times less work than full-size color.
    final frame = cv.imdecode(encodedFrame, cv.IMREAD_REDUCED_GRAYSCALE_4);
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
