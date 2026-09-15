import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

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
class RecordingsApi {
  RecordingsApi(this.serverUrl);

  final String serverUrl;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse(serverUrl).replace(path: path, queryParameters: query);

  /// Best-effort upload of a finished clip. Callers should keep the local
  /// file regardless of success/failure — this is additive server storage,
  /// not the source of truth on the camera side.
  Future<void> uploadRecording({
    required File file,
    required String cameraId,
    required String cameraName,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/recordings'))
      ..fields['camera_id'] = cameraId
      ..fields['camera_name'] = cameraName
      ..files.add(await http.MultipartFile.fromPath('file', file.path));
    final response = await request.send();
    if (response.statusCode != 201) {
      throw HttpException('Upload failed with status ${response.statusCode}');
    }
  }

  Future<List<RemoteRecording>> listRecordings(String cameraId) async {
    final response = await http.get(_uri('/recordings', {'camera_id': cameraId}));
    if (response.statusCode != 200) {
      throw HttpException('Listing recordings failed with status ${response.statusCode}');
    }
    final items = jsonDecode(response.body) as List<dynamic>;
    return items.map((e) => RemoteRecording.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> deleteRecording(String id) async {
    final response = await http.delete(_uri('/recordings/$id'));
    if (response.statusCode != 204) {
      throw HttpException('Delete failed with status ${response.statusCode}');
    }
  }

  Uri fileUrl(String id) => _uri('/recordings/$id/file');
}
