import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth/viewer_gate.dart';
import 'camera/camera_gate.dart';
import 'config.dart';
import 'ui/app_mode_controller.dart';
import 'ui/mode_select_screen.dart';
import 'ui/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  // Only Viewer Mode signs in, but initializing up front lets
  // supabase_flutter restore a persisted session before the first frame.
  await Supabase.initialize(url: AppConfig.supabaseUrl, publishableKey: AppConfig.supabasePublishableKey);
  runApp(const MainApp());
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  final _themeController = ThemeController();
  final _modeController = AppModeController();
  bool _modeLoaded = false;

  @override
  void initState() {
    super.initState();
    _themeController.load();
    // Waited for, so a paired camera relaunching doesn't flash the picker.
    _modeController.load().whenComplete(() {
      if (mounted) setState(() => _modeLoaded = true);
    });
  }

  @override
  void dispose() {
    _themeController.dispose();
    _modeController.dispose();
    super.dispose();
  }

  /// The chosen mode is the app's root rather than a pushed route, so there's
  /// no back button out of it; switching goes through each mode's settings.
  Widget _buildHome() {
    if (!_modeLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ValueListenableBuilder<AppMode?>(
      valueListenable: _modeController,
      builder: (context, mode, _) {
        switch (mode) {
          case null:
            return ModeSelectScreen(onSelected: _modeController.setMode);
          case AppMode.camera:
            return CameraGate(key: const ValueKey(AppMode.camera), onSwitchMode: _modeController.clear);
          case AppMode.viewer:
            return ViewerGate(
              key: const ValueKey(AppMode.viewer),
              themeController: _themeController,
              onSwitchMode: _modeController.clear,
            );
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeController,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'Repurposed Security Camera',
          theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
          darkTheme: ThemeData(
            colorSchemeSeed: Colors.indigo,
            brightness: Brightness.dark,
            useMaterial3: true,
          ),
          themeMode: themeMode,
          home: _buildHome(),
        );
      },
    );
  }
}
