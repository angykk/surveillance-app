import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/motion/motion_detector.dart';
import 'package:mobile/motion/motion_event_gate.dart';
import 'package:mobile/motion/motion_label.dart';

const _still = (motion: false, label: MotionLabel.motion);
const _moving = (motion: true, label: MotionLabel.motion);
const _person = (motion: true, label: MotionLabel.person);
const _pet = (motion: true, label: MotionLabel.pet);

/// Feeds [frames] one second apart, tracking whether an event is open the
/// way the camera does, and returns each step.
List<MotionStep> _run(MotionEventGate gate, List<FrameCheck> frames, {required _Clock clock}) {
  final steps = <MotionStep>[];
  var open = false;
  for (final frame in frames) {
    final step = gate.next(frame, eventOpen: open);
    if (step is StartEvent) open = true;
    if (step is EndEvent) open = false;
    steps.add(step);
    clock.tick();
  }
  return steps;
}

class _Clock {
  DateTime now = DateTime(2026);
  void tick() => now = now.add(const Duration(seconds: 1));
}

void main() {
  late _Clock clock;
  late MotionEventGate gate;

  setUp(() {
    clock = _Clock();
    gate = MotionEventGate(cooldown: const Duration(seconds: 3), clock: () => clock.now);
  });

  test('people mode ignores motion with nobody in it', () {
    expect(_run(gate, [_moving, _moving, _pet, _moving], clock: clock), everyElement(isA<Hold>()));
  });

  test('people mode ignores a person seen in a single frame', () {
    expect(_run(gate, [_person, _moving, _moving, _person], clock: clock), everyElement(isA<Hold>()));
  });

  test('people mode opens an event on a person in 2 of 3 frames', () {
    final steps = _run(gate, [_person, _moving, _person], clock: clock);
    expect(steps.last, isA<StartEvent>().having((s) => s.label, 'label', MotionLabel.person));
  });

  test('an open event survives motion without the person, and ends after the cooldown', () {
    final steps = _run(gate, [_person, _person, _moving, _still, _moving, _still, _still, _still], clock: clock);
    expect(steps.whereType<StartEvent>(), hasLength(1));
    // Last motion at frame 4; the cooldown of 3 s runs out at frame 7.
    expect(steps.indexWhere((s) => s is EndEvent), 7);
  });

  test('after an event ends, a new one needs fresh sightings', () {
    final steps = _run(gate, [_person, _person, _still, _still, _still, _person], clock: clock);
    expect(steps[4], isA<EndEvent>());
    expect(steps[5], isA<Hold>());
  });

  test('any-motion mode opens on motion and raises the label once someone shows up', () {
    gate.mode = DetectionMode.any;
    final steps = _run(gate, [_moving, _pet, _person, _pet], clock: clock);
    expect(steps[0], isA<StartEvent>().having((s) => s.label, 'label', MotionLabel.motion));
    expect(steps[1], isA<RaiseLabel>().having((s) => s.label, 'label', MotionLabel.pet));
    expect(steps[2], isA<RaiseLabel>().having((s) => s.label, 'label', MotionLabel.person));
    expect(steps[3], isA<Hold>());
  });

  test('an event the camera ended itself lets the next one start', () {
    gate.mode = DetectionMode.any;
    expect(gate.next(_moving, eventOpen: false), isA<StartEvent>());
    // The camera tore down and closed it; the next motion is a new event.
    expect(gate.next(_moving, eventOpen: false), isA<StartEvent>());
  });
}
