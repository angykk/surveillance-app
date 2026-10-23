import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/api_client.dart';

/// This device's identity when acting as a Camera, issued by the server when
/// a pairing code is redeemed. Replaces the old self-generated `camera_id`:
/// the id is server-assigned and the token proves it, so one camera can't
/// claim to be another.
///
/// Kept in the platform keychain/keystore rather than shared_preferences,
/// since the token is a long-lived credential for the household.
class DeviceCredentials {
  const DeviceCredentials({required this.deviceId, required this.token, required this.name});

  final String deviceId;
  final String token;
  final String name;

  static const _storage = FlutterSecureStorage();
  static const _idKey = 'device_id';
  static const _tokenKey = 'device_token';
  static const _nameKey = 'device_name';

  DeviceCredentials withName(String newName) =>
      DeviceCredentials(deviceId: deviceId, token: token, name: newName);

  /// Null when this device hasn't been paired yet (or was un-paired).
  static Future<DeviceCredentials?> load() async {
    final id = await _storage.read(key: _idKey);
    final token = await _storage.read(key: _tokenKey);
    if (id == null || token == null) return null;
    final name = await _storage.read(key: _nameKey);
    return DeviceCredentials(deviceId: id, token: token, name: name ?? 'Camera');
  }

  Future<void> save() async {
    await _storage.write(key: _idKey, value: deviceId);
    await _storage.write(key: _tokenKey, value: token);
    await _storage.write(key: _nameKey, value: name);
  }

  static Future<void> clear() async {
    await _storage.delete(key: _idKey);
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _nameKey);
  }

  /// Redeems a pairing code (from the QR shown in Viewer Mode) for this
  /// device's credentials, and persists them.
  static Future<DeviceCredentials> pair(String serverUrl, {required String code, required String name}) async {
    final json = await ApiClient.anonymous(serverUrl).send(
      'POST',
      '/devices/pair',
      json: {'code': code, 'name': name},
      expectStatus: 201,
    ) as Map<String, dynamic>;
    final credentials = DeviceCredentials(
      deviceId: json['device_id'] as String,
      token: json['device_token'] as String,
      name: json['name'] as String,
    );
    await credentials.save();
    return credentials;
  }

  Future<void> rename(String serverUrl, String newName) =>
      ApiClient.forDevice(serverUrl, token).send('PATCH', '/devices/me', json: {'name': newName});
}
