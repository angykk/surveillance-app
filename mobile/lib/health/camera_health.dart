/// How hot a phone is running. Phones only expose this as a coarse level,
/// not degrees: these are iOS's thermal states, with Android's thermal
/// statuses mapped onto them (see MainActivity.kt).
enum ThermalState {
  nominal,
  fair,

  /// The phone is throttling itself; the camera may slow down or freeze.
  serious,

  /// About to shut features down to cool off.
  critical;

  static ThermalState? fromName(Object? name) => values.where((s) => s.name == name).firstOrNull;
}

/// A camera's battery and temperature, as it reports them to the server
/// (`camera-health`) and as rosters carry them back. A field is null when the
/// phone couldn't read it.
class CameraHealth {
  const CameraHealth({this.batteryLevel, this.batteryCharging, this.thermalState});

  /// Percent, 0–100.
  final int? batteryLevel;

  /// Plugged in, whether or not it's still charging (a full battery counts).
  final bool? batteryCharging;
  final ThermalState? thermalState;

  /// Matches the server's threshold for its low-battery alert.
  static const lowBatteryPercent = 20;

  bool get batteryLow => batteryLevel != null && batteryLevel! <= lowBatteryPercent && batteryCharging != true;

  bool get runningHot => thermalState == ThermalState.serious || thermalState == ThermalState.critical;

  static CameraHealth? fromJson(Object? json) {
    if (json is! Map) return null;
    final level = json['battery_level'];
    final charging = json['battery_charging'];
    return CameraHealth(
      batteryLevel: level is int ? level : null,
      batteryCharging: charging is bool ? charging : null,
      thermalState: ThermalState.fromName(json['thermal_state']),
    );
  }

  Map<String, dynamic> toJson() => {
        'battery_level': batteryLevel,
        'battery_charging': batteryCharging,
        'thermal_state': thermalState?.name,
      };
}
