import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../auth/session.dart';

typedef AuthHeaders = Future<Map<String, String>> Function();

/// HTTP access to the server, signed with whichever credential this side of
/// the app holds: a Supabase access token in Viewer Mode, or the device
/// token from QR pairing in Camera Mode.
class ApiClient {
  ApiClient(this.serverUrl, this.authHeaders);

  ApiClient.forUser(String serverUrl) : this(serverUrl, userAuthHeaders);

  ApiClient.forDevice(String serverUrl, String deviceToken)
      : this(serverUrl, () async => {'Authorization': 'Device $deviceToken'});

  /// For the one unauthenticated call, redeeming a pairing code.
  ApiClient.anonymous(String serverUrl) : this(serverUrl, () async => const {});

  final String serverUrl;
  final AuthHeaders authHeaders;

  static const timeout = Duration(seconds: 15);

  Uri uri(String path, [Map<String, String>? query]) =>
      Uri.parse(serverUrl).replace(path: path, queryParameters: query);

  /// Sends a JSON request and returns the decoded response body (null for
  /// an empty body). Throws [ApiException] on any status other than
  /// [expectStatus].
  Future<dynamic> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? json,
    int expectStatus = 200,
  }) {
    // Without a timeout, an unreachable server (e.g. a stale SERVER_IP) or a
    // stalled Supabase token refresh in [authHeaders] leaves the caller
    // spinning indefinitely, so it covers the whole request.
    return _send(method, path, query, json, expectStatus).timeout(timeout);
  }

  Future<dynamic> _send(String method, String path, Map<String, String>? query, Object? json, int expectStatus) async {
    final request = http.Request(method, uri(path, query))..headers.addAll(await authHeaders());
    if (json != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(json);
    }
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode != expectStatus) {
      throw ApiException(response.statusCode, '$method $path');
    }
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }
}

class ApiException extends HttpException {
  ApiException(this.statusCode, String request) : super('$request failed with status $statusCode');

  final int statusCode;
}
