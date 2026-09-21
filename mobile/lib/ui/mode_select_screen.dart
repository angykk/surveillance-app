import 'package:flutter/material.dart';

import '../camera/camera_screen.dart';
import 'camera_list_screen.dart';
import 'theme_controller.dart';

/// Entry screen: choose whether this device acts as a Camera/Server or a
/// Viewer/Client.
class ModeSelectScreen extends StatelessWidget {
  const ModeSelectScreen({super.key, required this.themeController});

  /// Only handed to Viewer Mode below — Camera Mode runs unattended as a
  /// fixed video feed, so a theme toggle has nothing to offer there.
  final ThemeController themeController;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Repurposed Security Camera')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
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
              const SizedBox(height: 32),
              _ModeCard(
                icon: Icons.videocam,
                title: 'Camera Mode',
                subtitle: 'Turn this device into a security camera',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CameraScreen()),
                ),
              ),
              const SizedBox(height: 16),
              _ModeCard(
                icon: Icons.smartphone,
                title: 'Viewer Mode',
                subtitle: 'View and manage your cameras',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CameraListScreen(themeController: themeController),
                  ),
                ),
              ),
            ],
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
