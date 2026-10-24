import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/api/api_client.dart';
import 'package:mobile/ui/shared_widgets.dart';

void main() {
  Future<Future<bool>> openConfirm(WidgetTester tester) async {
    late Future<bool> result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => result = showConfirmDialog(
            context,
            title: 'Remove Porch?',
            message: 'It will be disconnected.',
            confirmLabel: 'Remove',
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('confirm dialog is true only for the confirm button', (tester) async {
    var result = await openConfirm(tester);
    expect(find.text('Remove Porch?'), findsOneWidget);
    expect(find.text('It will be disconnected.'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);

    result = await openConfirm(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);

    // Dismissed by tapping outside.
    result = await openConfirm(tester);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('loading button shows a spinner and ignores taps while loading', (tester) async {
    var taps = 0;
    Widget build(bool loading) => MaterialApp(
          home: Scaffold(body: LoadingButton(loading: loading, onPressed: () => taps++, label: 'Sign in')),
        );

    await tester.pumpWidget(build(false));
    await tester.tap(find.text('Sign in'));
    expect(taps, 1);

    await tester.pumpWidget(build(true));
    expect(find.text('Sign in'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    expect(taps, 1);
  });

  testWidgets('message view shows its icon, message and action', (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageView(
          icon: Icons.cloud_off,
          message: 'Offline',
          action: TextButton(onPressed: () => tapped = true, child: const Text('Retry')),
        ),
      ),
    ));
    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(tapped, isTrue);
  });

  testWidgets('switch mode button calls back', (tester) async {
    var pressed = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SwitchModeButton(onPressed: () => pressed = true))));
    await tester.tap(find.text('Switch mode'));
    expect(pressed, isTrue);
  });

  test('epoch seconds, fractional or not, become DateTimes', () {
    expect(dateTimeFromEpochSeconds(0), DateTime.fromMillisecondsSinceEpoch(0));
    expect(dateTimeFromEpochSeconds(1700000000.25).millisecondsSinceEpoch, 1700000000250);
  });
}
