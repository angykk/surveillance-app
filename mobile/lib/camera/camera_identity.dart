import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// This device's identity when acting as a Camera: a `camera_id` that's
/// generated once and persisted (so the server recognizes this device across
/// restarts/reconnects instead of registering it as a new camera each time),
/// plus a human-readable, user-editable `camera_name`.
class CameraIdentity {
  static const _idKey = 'camera_id';
  static const _nameKey = 'camera_name';

  const CameraIdentity({required this.id, required this.name, required this.isUnnamed});

  final String id;
  final String name;

  /// True until the user has ever explicitly set a name — lets the caller
  /// prompt for one on first setup instead of leaving every camera as the
  /// generic default, which is what made same-named cameras indistinguishable
  /// in the viewer's camera list.
  final bool isUnnamed;

  static Future<CameraIdentity> load() async {
    final prefs = await SharedPreferences.getInstance();

    var id = prefs.getString(_idKey);
    if (id == null) {
      id = _generateId();
      await prefs.setString(_idKey, id);
    }

    final storedName = prefs.getString(_nameKey);
    return CameraIdentity(id: id, name: storedName ?? 'Camera', isUnnamed: storedName == null);
  }

  static Future<void> saveName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, name);
  }

  static String _generateId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
