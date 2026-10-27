import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'motion_label.dart';
import 'person_detector.dart';

/// What one frame showed: whether anything moved and, if it did, the most
/// important thing in the picture ([MotionLabel.motion] for nobody).
typedef FrameCheck = ({bool motion, MotionLabel label});

const _noMotion = (motion: false, label: MotionLabel.motion);

/// Two-stage motion detector.
///
/// Feed it successive camera frames (JPEG/PNG-encoded bytes, as returned by
/// `MediaStreamTrack.captureFrame()`) via [detect]. It maintains a running
/// MOG2 background model and reports whether the latest frame contains a
/// foreground blob large enough to count as motion, filtering out sensor
/// noise and minor lighting changes. Only when something moved does it run
/// the much heavier [PersonDetector] on the frame, to say whether that was a
/// person (or a pet), so a still scene costs no more than before.
///
/// The work runs on its own isolate: decoding and processing a frame every
/// second on the UI isolate made the camera screen stutter, and froze it once
/// a warm, throttled phone took longer than a second per frame.
class MotionDetector {
  /// [worker] stands in for the OpenCV worker in tests, and [loadModel]
  /// for reading the person detector's model from the asset bundle.
  MotionDetector({
    @visibleForTesting void Function(WorkerStart start) worker = _workerMain,
    @visibleForTesting Future<Uint8List?> Function() loadModel = _loadBundledModel,
  }) {
    _ready = _start(worker, loadModel);
  }

  late final Future<void> _ready;
  Isolate? _isolate;
  final _handshake = Completer<(SendPort, bool)?>();
  SendPort? _requests;
  bool _canSeePeople = false;
  final _responses = ReceivePort();
  final _pending = <int, Completer<FrameCheck>>{};
  int _nextId = 0;
  bool _disposed = false;

  Future<void> _start(void Function(WorkerStart) worker, Future<Uint8List?> Function() loadModel) async {
    _responses.listen((message) {
      if (message is (SendPort, bool)) {
        if (!_handshake.isCompleted) _handshake.complete(message);
      } else if (message is (int, bool, int)) {
        _pending.remove(message.$1)?.complete((motion: message.$2, label: MotionLabel.values[message.$3]));
      }
    });
    final model = await loadModel();
    final isolate = await Isolate.spawn(
      worker,
      (_responses.sendPort, model == null ? null : TransferableTypedData.fromList([model])),
      debugName: 'motion-detector',
    );
    _isolate = isolate;
    // Disposed while the isolate was starting: [dispose] had nothing to
    // kill yet, so the isolate would have run on, unused, for good.
    if (_disposed) {
      isolate.kill(priority: Isolate.immediate);
      return;
    }
    final handshake = await _handshake.future;
    if (handshake == null) return;
    _requests = handshake.$1;
    _canSeePeople = handshake.$2;
  }

  @visibleForTesting
  Future<void> get ready => _ready;

  @visibleForTesting
  Isolate? get isolate => _isolate;

  /// Whether the person detector loaded. Without it every [FrameCheck] says
  /// [MotionLabel.motion], so a camera set to people only would never open
  /// an event; it has to fall back to any motion instead.
  Future<bool> get canSeePeople async {
    await _ready;
    return _canSeePeople;
  }

  /// Whether [encodedFrame] shows motion against the frames before it, and
  /// who or what is in it if so.
  Future<FrameCheck> detect(Uint8List encodedFrame) async {
    await _ready;
    if (_disposed) return _noMotion;
    final id = _nextId++;
    final result = Completer<FrameCheck>();
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
      pending.complete(_noMotion);
    }
    _pending.clear();
  }
}

const _resetRequest = 'reset';

/// What the worker isolate starts with: where to send its answers, and the
/// person detector's model (null if it couldn't be read).
typedef WorkerStart = (SendPort responses, TransferableTypedData? model);

const _modelAsset = 'assets/models/yolox_nano.onnx';

Future<Uint8List?> _loadBundledModel() async {
  try {
    final data = await rootBundle.load(_modelAsset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (e) {
    debugPrint('Loading the person detector failed: $e');
    return null;
  }
}

void _workerMain(WorkerStart start) {
  final (responses, model) = start;
  PersonDetector? people;
  if (model != null) {
    try {
      people = PersonDetector(model.materialize().asUint8List());
    } catch (e) {
      debugPrint('Loading the person detector failed: $e');
    }
  }
  final requests = ReceivePort();
  responses.send((requests.sendPort, people != null));
  var detector = _Mog2Detector();
  requests.listen((message) {
    if (message == _resetRequest) {
      detector.dispose();
      detector = _Mog2Detector();
      return;
    }
    final (id, data) = message as (int, TransferableTypedData);
    var motion = false;
    var label = MotionLabel.motion;
    try {
      final encodedFrame = data.materialize().asUint8List();
      motion = detector.detect(encodedFrame);
      if (motion && people != null) label = _whoIsIn(people, encodedFrame);
    } catch (_) {
      // Best-effort: an undecodable frame just counts as no motion.
    }
    responses.send((id, motion, label.index));
  });
}

MotionLabel _whoIsIn(PersonDetector people, Uint8List encodedFrame) {
  final watch = Stopwatch()..start();
  // Half size (640x360 from 720p) is still more than the model's input.
  final frame = cv.imdecode(encodedFrame, cv.IMREAD_REDUCED_COLOR_2);
  try {
    return people.detect(frame);
  } finally {
    frame.dispose();
    if (kDebugMode) debugPrint('Person detection took ${watch.elapsedMilliseconds} ms');
  }
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
