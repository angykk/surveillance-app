import 'dart:collection';

import 'motion_detector.dart';
import 'motion_label.dart';

/// What the camera should do with its motion event after a checked frame.
sealed class MotionStep {
  const MotionStep();
}

/// Nothing changes.
class Hold extends MotionStep {
  const Hold();
}

/// Open an event with [label].
class StartEvent extends MotionStep {
  const StartEvent(this.label);
  final MotionLabel label;
}

/// Raise the open event's label to [label], e.g. a person walked in partway.
class RaiseLabel extends MotionStep {
  const RaiseLabel(this.label);
  final MotionLabel label;
}

/// Close the open event: nothing has moved for [MotionEventGate.cooldown].
class EndEvent extends MotionStep {
  const EndEvent();
}

/// Decides when a camera's motion events open and close, from one
/// [FrameCheck] a second.
///
/// - With [DetectionMode.any], any motion opens an event, as before person
///   detection.
/// - With [DetectionMode.person], an event opens only once a person has
///   been seen in [personFramesToStart] of the last [personWindow] frames,
///   so a single misfire (a coat on a chair, a face on a poster) doesn't
///   count.
///
/// Either way, once open, an event stays open while anything moves, person
/// or not, so someone turning away or stepping behind the sofa doesn't split
/// it in two; it closes after [cooldown] of stillness.
class MotionEventGate {
  MotionEventGate({this.cooldown = const Duration(seconds: 8), DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  static const personFramesToStart = 2;
  static const personWindow = 3;

  final Duration cooldown;
  final DateTime Function() _clock;

  DetectionMode mode = DetectionMode.person;

  /// Whether each of the last [personWindow] frames moved with a person in it.
  final _recentPeople = ListQueue<bool>();
  DateTime? _lastMotionAt;
  MotionLabel _label = MotionLabel.motion;

  /// The step for [check], the latest frame. [eventOpen] is whether the
  /// camera has an event open: it can also end one itself (on a teardown),
  /// so it, not this gate, is the one that knows.
  MotionStep next(FrameCheck check, {required bool eventOpen}) {
    final now = _clock();
    _recentPeople.addLast(check.motion && check.label == MotionLabel.person);
    while (_recentPeople.length > personWindow) {
      _recentPeople.removeFirst();
    }

    if (!eventOpen) {
      if (!check.motion) return const Hold();
      final MotionLabel label;
      switch (mode) {
        case DetectionMode.any:
          label = check.label;
        case DetectionMode.person:
          if (_recentPeople.where((seen) => seen).length < personFramesToStart) return const Hold();
          label = MotionLabel.person;
      }
      _label = label;
      _lastMotionAt = now;
      return StartEvent(label);
    }

    if (check.motion) {
      _lastMotionAt = now;
      if (check.label.outranks(_label)) {
        _label = check.label;
        return RaiseLabel(check.label);
      }
      return const Hold();
    }
    final last = _lastMotionAt;
    if (last == null || now.difference(last) >= cooldown) {
      _recentPeople.clear();
      return const EndEvent();
    }
    return const Hold();
  }
}
