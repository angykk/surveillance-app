import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'camera_health.dart';

/// Reads this phone's [CameraHealth] in Camera Mode. Battery comes from
/// battery_plus; the thermal state from a small platform channel
/// (AppDelegate.swift, MainActivity.kt), since no plugin covers it.
class HealthMonitor {
  final _battery = Battery();

  static const _thermalChannel = MethodChannel('keepwatch/thermal');

  /// Fires when the phone is plugged in or unplugged, which is worth
  /// reporting right away rather than at the next periodic report.
  Stream<void> get pluggedInChanges => _battery.onBatteryStateChanged.map(_pluggedIn).distinct();

  /// Each part is best-effort: one the phone can't read is left null.
  Future<CameraHealth> read() async {
    final (level, state, thermal) = await (
      _readOrNull(() => _battery.batteryLevel),
      _readOrNull(() => _battery.batteryState),
      _readOrNull(() => _thermalChannel.invokeMethod<String>('thermalState')),
    ).wait;
    return CameraHealth(
      // Some emulators and desktops report -1 for "unknown".
      batteryLevel: level != null && level >= 0 && level <= 100 ? level : null,
      batteryCharging: state == null || state == BatteryState.unknown ? null : _pluggedIn(state),
      thermalState: ThermalState.fromName(thermal),
    );
  }

  static bool _pluggedIn(BatteryState state) =>
      state == BatteryState.charging || state == BatteryState.full || state == BatteryState.connectedNotCharging;

  static Future<T?> _readOrNull<T>(Future<T?> Function() read) async {
    try {
      return await read();
    } catch (e) {
      debugPrint('Reading camera health failed: $e');
      return null;
    }
  }
}
