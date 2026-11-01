import 'package:flutter/material.dart';

import '../health/camera_health.dart';

/// A camera's battery, plus a warning while it's running hot, for its card
/// on the camera list. Shown dimmed for an offline camera, whose health is
/// as of when it was last seen. Problems use the theme's error color.
class CameraHealthBadges extends StatelessWidget {
  const CameraHealthBadges({super.key, required this.health, required this.online});

  final CameraHealth health;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final normal = online ? colors.onSurfaceVariant : colors.outline;
    final problem = online ? colors.error : colors.outline;
    final level = health.batteryLevel;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (level != null || health.batteryCharging != null)
          _Badge(
            icon: batteryIcon(health),
            label: level == null ? null : '$level%',
            color: health.batteryLow ? problem : normal,
            semanticLabel: [
              if (level != null) 'Battery $level%',
              if (health.batteryCharging == true) 'charging',
            ].join(', '),
          ),
        if (health.runningHot)
          _Badge(icon: Icons.thermostat, label: 'Hot', color: problem, semanticLabel: 'Running hot'),
      ],
    );
  }
}

/// The battery icon for [health]: charging, low, or filled to its level.
IconData batteryIcon(CameraHealth health) {
  if (health.batteryCharging == true) return Icons.battery_charging_full;
  final level = health.batteryLevel;
  if (level == null) return Icons.battery_unknown;
  if (health.batteryLow) return Icons.battery_alert;
  if (level >= 95) return Icons.battery_full;
  const bars = [
    Icons.battery_0_bar,
    Icons.battery_1_bar,
    Icons.battery_2_bar,
    Icons.battery_3_bar,
    Icons.battery_4_bar,
    Icons.battery_5_bar,
    Icons.battery_6_bar,
  ];
  return bars[(level * bars.length ~/ 100).clamp(0, bars.length - 1)];
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label, required this.color, required this.semanticLabel});

  final IconData icon;
  final String? label;
  final Color color;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            if (label != null) ...[
              const SizedBox(width: 2),
              Text(label!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color)),
            ],
          ],
        ),
      ),
    );
  }
}
