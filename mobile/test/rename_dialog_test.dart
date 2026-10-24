import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/ui/rename_dialog.dart';

void main() {
  /// Opens the dialog over a blank app and returns its eventual result.
  Future<Future<String?>> showIt(WidgetTester tester, {String current = 'Front Door'}) async {
    late Future<String?> result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => result = showRenameCameraDialog(context, current: current),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('returns the new name, trimmed', (tester) async {
    final result = await showIt(tester);
    await tester.enterText(find.byType(TextField), '  Back Door ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await result, 'Back Door');
  });

  testWidgets('submitting from the keyboard saves too', (tester) async {
    final result = await showIt(tester);
    await tester.enterText(find.byType(TextField), 'Garage');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(await result, 'Garage');
  });

  testWidgets('cancel, empty and unchanged all return null', (tester) async {
    var result = await showIt(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isNull);

    result = await showIt(tester);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await result, isNull);

    result = await showIt(tester);
    await tester.enterText(find.byType(TextField), 'Front Door ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets('starts from the current name and closes cleanly', (tester) async {
    final result = await showIt(tester, current: 'Porch');
    expect(find.widgetWithText(TextField, 'Porch'), findsOneWidget);
    await tester.tap(find.text('Save'));
    // Through the whole closing animation: a controller disposed too early
    // throws here.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
    expect(await result, isNull);
  });
}
