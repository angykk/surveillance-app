import 'dart:io';

import 'package:http/http.dart' as http;

import '../api/api_client.dart';

/// Metadata for a motion clip stored on the signaling server, as opposed to
/// [RecordingManager]'s purely local, on-device files.
class RemoteRecording {
  const RemoteRecording({
    required this.id,
    required this.cameraId,
    required this.cameraName,
    required this.createdAt,
    required this.sizeBytes,
  });

  final String id;
  final String cameraId;
  final String cameraName;
  final DateTime createdAt;
  final int sizeBytes;

  factory RemoteRecording.fromJson(Map<String, dynamic> json) => RemoteRecording(
        id: json['id'] as String,
        cameraId: json['camera_id'] as String,
        cameraName: json['camera_name'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          ((json['created_at'] as num) * 1000).round(),
        ),
        sizeBytes: json['size_bytes'] as int,
      );
}

/// Talks to the server's `/recordings` HTTP API: cameras upload motion clips
/// here so they outlive the camera device's own local storage and become
/// reachable from Viewer Mode, which lists and streams them back out.
///
/// Built on a device-signed [ApiClient] in Camera Mode (uploads are
/// attributed to whichever camera the token belongs to) and a user-signed
/// one in Viewer Mode (the server only returns the user's own households'
/// clips).
class RecordingsApi {
  RecordingsApi(this._client);

  final ApiClient _client;

  /// Best-effort upload of a finished clip. Callers should keep the local
  /// file regardless of success/failure — this is additive server storage,
  /// not the source of truth on the camera side.
  Future<void> uploadRecording(File file) async {
    final request = http.MultipartRequest('POST', _client.uri('/recordings'))
      ..headers.addAll(await _client.authHeaders())
      ..files.add(await http.MultipartFile.fromPath('file', file.path));
    final response = await request.send();
    if (response.statusCode != 201) {
      throw ApiException(response.statusCode, 'POST /recordings');
    }
  }

  Future<List<RemoteRecording>> listRecordings(String cameraId) async {
    final items = await _client.send('GET', '/recordings', query: {'camera_id': cameraId}) as List<dynamic>;
    return items.map((e) => RemoteRecording.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> deleteRecording(String id) =>
      _client.send('DELETE', '/recordings/$id', expectStatus: 204);

  Uri fileUrl(String id) => _client.uri('/recordings/$id/file');

  /// Headers the video player must send when streaming [fileUrl], since
  /// clips are only served to members of the camera's household.
  Future<Map<String, String>> fileHeaders() => _client.authHeaders();
}
