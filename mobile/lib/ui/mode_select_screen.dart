import 'package:flutter/material.dart';

import 'app_mode_controller.dart';

/// Entry screen: choose whether this device acts as a Camera/Server or a
/// Viewer/Client. Shown only until a mode is chosen; the choice persists,
/// and switching later goes through that mode's settings.
class ModeSelectScreen extends StatelessWidget {
  const ModeSelectScreen({super.key, required this.onSelected});

  final ValueChanged<AppMode> onSelected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Repurposed Security Camera')),
      // Scrollable and width-capped so it still fits a phone in landscape.
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.security, size: 64),
                const SizedBox(height: 8),
                const Text(
                  'Choose how this device should be used',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  'You can switch later from settings.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 32),
                _ModeCard(
                  icon: Icons.videocam,
                  title: 'Camera Mode',
                  subtitle: 'Turn this device into a security camera',
                  onTap: () => onSelected(AppMode.camera),
                ),
                const SizedBox(height: 16),
                _ModeCard(
                  icon: Icons.smartphone,
                  title: 'Viewer Mode',
                  subtitle: 'View and manage your cameras',
                  onTap: () => onSelected(AppMode.viewer),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: Icon(icon, size: 36),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
