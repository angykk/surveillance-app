import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/camera/serial_task.dart';

void main() {
  test('a run while running waits its turn instead of overlapping', () async {
    var active = 0;
    var maxActive = 0;
    var runs = 0;
    final gate = Completer<void>();
    final task = SerialTask((_) async {
      runs++;
      maxActive = (++active) > maxActive ? active : maxActive;
      await gate.future;
      active--;
    });

    final first = task.run();
    // E.g. the camera and mic permission pop-ups each bringing the app back.
    unawaited(task.run());
    unawaited(task.run());
    gate.complete();
    await first;
    expect(maxActive, 1);
    // Several asks while busy fold into one more run.
    expect(runs, 2);
  });

  test('cancel makes the running job stale', () async {
    final gate = Completer<void>();
    final seen = <bool>[];
    final task = SerialTask((isCurrent) async {
      await gate.future;
      seen.add(isCurrent());
    });

    final running = task.run();
    task.cancel(); // The app went to the background mid-setup.
    gate.complete();
    await running;
    expect(seen, [false]);
  });

  test('a run asked for after a cancel still happens, and is current', () async {
    var gate = Completer<void>();
    final seen = <bool>[];
    final task = SerialTask((isCurrent) async {
      await gate.future;
      seen.add(isCurrent());
    });

    final running = task.run();
    task.cancel(); // inactive...
    unawaited(task.run()); // ...then resumed
    final firstGate = gate;
    gate = Completer<void>()..complete();
    firstGate.complete();
    await running;
    expect(seen, [false, true]);
  });

  test('a cancel drops a rerun that was asked for before it', () async {
    final gate = Completer<void>();
    var runs = 0;
    final task = SerialTask((_) async {
      runs++;
      await gate.future;
    });

    final running = task.run();
    unawaited(task.run()); // resumed...
    task.cancel(); // ...then straight back to the background
    gate.complete();
    await running;
    expect(runs, 1);
  });

  test('can run again once finished', () async {
    var runs = 0;
    final task = SerialTask((_) async => runs++);
    await task.run();
    await task.run();
    expect(runs, 2);
  });
}
