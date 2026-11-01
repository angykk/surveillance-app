import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/health/camera_health.dart';
import 'package:mobile/ui/camera_health_badges.dart';
import 'package:mobile/ui/camera_list_screen.dart';

void main() {
  group('CameraHealth', () {
    test('round-trips through the JSON the server stores', () {
      const health = CameraHealth(batteryLevel: 64, batteryCharging: true, thermalState: ThermalState.fair);
      final parsed = CameraHealth.fromJson(health.toJson())!;
      expect(parsed.batteryLevel, 64);
      expect(parsed.batteryCharging, isTrue);
      expect(parsed.thermalState, ThermalState.fair);
    });

    test('reads missing or unknown fields as null', () {
      expect(CameraHealth.fromJson(null), isNull);
      final parsed = CameraHealth.fromJson({'battery_level': null, 'thermal_state': 'melting'})!;
      expect(parsed.batteryLevel, isNull);
      expect(parsed.batteryCharging, isNull);
      expect(parsed.thermalState, isNull);
    });

    test('battery is low at the threshold only while unplugged', () {
      expect(const CameraHealth(batteryLevel: 21).batteryLow, isFalse);
      expect(const CameraHealth(batteryLevel: 20).batteryLow, isTrue);
      expect(const CameraHealth(batteryLevel: 20, batteryCharging: false).batteryLow, isTrue);
      expect(const CameraHealth(batteryLevel: 5, batteryCharging: true).batteryLow, isFalse);
      expect(const CameraHealth().batteryLow, isFalse);
    });

    test('runs hot from serious up', () {
      expect(const CameraHealth(thermalState: ThermalState.fair).runningHot, isFalse);
      expect(const CameraHealth(thermalState: ThermalState.serious).runningHot, isTrue);
      expect(const CameraHealth(thermalState: ThermalState.critical).runningHot, isTrue);
    });
  });

  group('CameraHealthBadges', () {
    Future<void> pump(WidgetTester tester, CameraHealth health, {bool online = true}) => tester.pumpWidget(
          MaterialApp(home: Scaffold(body: CameraHealthBadges(health: health, online: online))),
        );

    Color? iconColor(WidgetTester tester, IconData icon) => tester.widget<Icon>(find.byIcon(icon)).color;

    testWidgets('shows the battery level, in the error color when low', (tester) async {
      await pump(tester, const CameraHealth(batteryLevel: 80, batteryCharging: false));
      expect(find.text('80%'), findsOneWidget);
      expect(find.text('Hot'), findsNothing);

      await pump(tester, const CameraHealth(batteryLevel: 12, batteryCharging: false));
      final context = tester.element(find.text('12%'));
      expect(iconColor(tester, Icons.battery_alert), Theme.of(context).colorScheme.error);
    });

    testWidgets('shows charging and running hot', (tester) async {
      await pump(tester, const CameraHealth(batteryLevel: 12, batteryCharging: true, thermalState: ThermalState.serious));
      expect(find.byIcon(Icons.battery_charging_full), findsOneWidget);
      expect(find.text('Hot'), findsOneWidget);
    });

    testWidgets('dims problems on an offline camera', (tester) async {
      await pump(tester, const CameraHealth(batteryLevel: 12, batteryCharging: false), online: false);
      final context = tester.element(find.text('12%'));
      expect(iconColor(tester, Icons.battery_alert), Theme.of(context).colorScheme.outline);
    });
  });

  test('CameraAlert words each kind and skips unknown ones', () {
    String? message(String kind) => CameraAlert.fromJson({'kind': kind, 'camera_name': 'Porch'})?.message;
    expect(message('offline'), 'Porch has gone offline.');
    expect(message('battery-low'), contains('Porch\'s battery is low'));
    expect(message('hot'), contains('Porch is running hot'));
    expect(message('flooded'), isNull);
    expect(CameraAlert.fromJson({'kind': 'offline'}), isNull);
  });
}
