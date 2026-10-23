import 'api_client.dart';

class Household {
  const Household({required this.id, required this.name, required this.role});

  final String id;
  final String name;

  /// 'owner', 'admin' or 'viewer'.
  final String role;

  /// Owners and admins can add/remove/rename cameras; viewers can only
  /// watch.
  bool get canManage => role == 'owner' || role == 'admin';

  factory Household.fromJson(Map<String, dynamic> json) => Household(
        id: json['id'] as String,
        name: json['name'] as String,
        role: json['role'] as String,
      );
}

class PairingCode {
  const PairingCode({required this.code, required this.expiresAt});

  final String code;
  final DateTime expiresAt;

  /// What the QR code encodes. The prefix lets the camera's scanner ignore
  /// unrelated QR codes instead of trying to redeem them.
  String get qrPayload => '$qrPrefix$code';

  static const qrPrefix = 'survcam:pair:';

  /// Accepts either a scanned QR payload or a hand-typed code.
  static String? parse(String raw) {
    final value = raw.trim();
    final code = value.startsWith(qrPrefix) ? value.substring(qrPrefix.length) : value;
    final normalized = code.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    return RegExp(r'^[A-Z0-9]{8}$').hasMatch(normalized) ? normalized : null;
  }
}

/// Viewer Mode's account-level calls: the signed-in user's households, and
/// managing the cameras paired into them.
class HouseholdsApi {
  HouseholdsApi(this._client);

  final ApiClient _client;

  Future<List<Household>> households() async {
    final me = await _client.send('GET', '/me') as Map<String, dynamic>;
    return (me['households'] as List)
        .map((h) => Household.fromJson(h as Map<String, dynamic>))
        .toList();
  }

  Future<PairingCode> createPairingCode(String householdId) async {
    final json = await _client.send(
      'POST',
      '/households/$householdId/pairing-codes',
      expectStatus: 201,
    ) as Map<String, dynamic>;
    return PairingCode(
      code: json['code'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(((json['expires_at'] as num) * 1000).round()),
    );
  }

  Future<void> renameCamera(String deviceId, String name) =>
      _client.send('PATCH', '/devices/$deviceId', json: {'name': name});

  Future<void> removeCamera(String deviceId) =>
      _client.send('DELETE', '/devices/$deviceId', expectStatus: 204);
}
