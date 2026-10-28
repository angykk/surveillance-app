import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/api/motion_api.dart';
import 'package:mobile/ui/motion_timeline.dart';

void main() {
  final now = DateTime.now();
  MotionEvent event(String id, {bool hasClip = true, bool ongoing = false}) => MotionEvent(
        id: id,
        cameraId: 'cam',
        startedAt: now.subtract(const Duration(minutes: 5)),
        endedAt: ongoing ? null : now.subtract(const Duration(minutes: 4)),
        hasClip: hasClip,
      );

  final shared = <String>[];
  final deleted = <String>[];

  Future<void> pumpTimeline(WidgetTester tester, MotionEvent e, {required bool canDelete}) async {
    shared.clear();
    deleted.clear();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MotionTimeline(
          events: [e],
          loading: false,
          error: null,
          onRefresh: () async {},
          selectedId: null,
          onSelect: (_) {},
          onShare: (e, _) => shared.add(e.id),
          onDelete: canDelete ? (e) => deleted.add(e.id) : null,
        ),
      ),
    ));
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Event actions'));
    await tester.pumpAndSettle();
  }

  testWidgets('a manager can share and delete an ended event with a clip', (tester) async {
    await pumpTimeline(tester, event('a'), canDelete: true);
    await openMenu(tester);
    await tester.tap(find.text('Share clip'));
    await tester.pumpAndSettle();
    expect(shared, ['a']);

    // A long-press opens the same menu.
    await tester.longPress(find.text('1m'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted, ['a']);
  });

  testWidgets('Delete is left out without the role, and Share without a clip', (tester) async {
    await pumpTimeline(tester, event('a'), canDelete: false);
    await openMenu(tester);
    expect(find.text('Share clip'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);
    Navigator.of(tester.element(find.text('Share clip'))).pop();
    await tester.pumpAndSettle();

    await pumpTimeline(tester, event('b', hasClip: false), canDelete: true);
    await openMenu(tester);
    expect(find.text('Share clip'), findsNothing);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('no menu when there is nothing to do', (tester) async {
    await pumpTimeline(tester, event('a', hasClip: false), canDelete: false);
    expect(find.byTooltip('Event actions'), findsNothing);
  });

  testWidgets('an ongoing event cannot be deleted', (tester) async {
    await pumpTimeline(tester, event('a', hasClip: false, ongoing: true), canDelete: true);
    // The ongoing dot pulses forever, so this can't wait for things to settle.
    await tester.tap(find.byTooltip('Event actions'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Delete'), warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    expect(deleted, isEmpty);
  });
}
