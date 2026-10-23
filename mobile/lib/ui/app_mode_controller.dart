import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppMode { camera, viewer }

/// Which mode this device runs in, persisted so a relaunch (or a camera
/// phone rebooting) goes straight back into it. Null until one is chosen;
/// clearing it returns to the mode picker.
class AppModeController extends ValueNotifier<AppMode?> {
  AppModeController() : super(null);

  static const _key = 'app_mode';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    value = AppMode.values.where((mode) => mode.name == stored).firstOrNull;
  }

  Future<void> setMode(AppMode mode) async {
    value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }

  Future<void> clear() async {
    value = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
