import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Turns a captured frame (PNG/JPEG bytes from `captureFrame`) into the
/// small JPEG a motion event shows on the viewer's timeline, or null if the
/// frame can't be decoded.
///
/// Runs on a short-lived isolate, since decoding a full frame on the UI
/// isolate is what used to make the camera screen stutter (see
/// [MotionDetector]). It's once per motion event, so the isolate's startup
/// cost doesn't matter.
Future<Uint8List?> encodeThumbnail(Uint8List frame) => Isolate.run(() => encodeThumbnailSync(frame));

/// Half-size (640x360 from 720p), which stays sharp in the timeline on a
/// high-density screen while keeping the file to a few tens of KB.
@visibleForTesting
Uint8List? encodeThumbnailSync(Uint8List frame) => _encodeJpeg(frame, cv.IMREAD_REDUCED_COLOR_2, 70);

Uint8List? _encodeJpeg(Uint8List frame, int decodeFlags, int quality) {
  final image = cv.imdecode(frame, decodeFlags);
  try {
    if (image.isEmpty) return null;
    final params = cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, quality]);
    final (ok, jpeg) = cv.imencode('.jpg', image, params: params);
    params.dispose();
    return ok ? jpeg : null;
  } finally {
    image.dispose();
  }
}

/// Turns a captured frame into a full-size JPEG for a snapshot a viewer
/// asked for, or null if the frame can't be decoded. Kept under the
/// signaling server's message limit (1 MB, base64-encoded) at 720p.
Future<Uint8List?> encodeSnapshot(Uint8List frame) => Isolate.run(() => _encodeJpeg(frame, cv.IMREAD_COLOR, 85));
