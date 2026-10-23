import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_client.dart';

/// One stretch of movement a camera's motion detector saw. [endedAt] is null
/// while the motion is still going on; [hasClip] turns true once the camera
/// has uploaded its recording of it, shortly after it ends.
class MotionEvent {
  const MotionEvent({
    required this.id,
    required this.cameraId,
    required this.startedAt,
    required this.endedAt,
    required this.hasClip,
  });

  final String id;
  final String cameraId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final bool hasClip;

  bool get ongoing => endedAt == null;

  factory MotionEvent.fromJson(Map<dynamic, dynamic> json) => MotionEvent(
        id: json['id'] as String,
        cameraId: json['camera_id'] as String,
        startedAt: _fromEpochSeconds(json['started_at'] as num),
        endedAt: json['ended_at'] == null ? null : _fromEpochSeconds(json['ended_at'] as num),
        hasClip: json['has_clip'] as bool? ?? false,
      );

  static DateTime _fromEpochSeconds(num seconds) =>
      DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
}

/// A camera's motion history and clips. Viewer Mode (a user-signed
/// [ApiClient]) loads the timeline and streams clips; Camera Mode (a
/// device-signed one) uploads each event's clip. New events arrive live over
/// the signaling socket as `motion`; this only loads the backlog.
class MotionApi {
  MotionApi(this._client);

  final ApiClient _client;

  Future<List<MotionEvent>> events(String cameraId) async {
    final items = await _client.send('GET', '/devices/$cameraId/motion-events') as List<dynamic>;
    return items.map((e) => MotionEvent.fromJson(e as Map<dynamic, dynamic>)).toList();
  }

  Future<void> uploadClip(String eventId, File file) async {
    final path = '/motion-events/$eventId/clip';
    final request = http.MultipartRequest('POST', _client.uri(path))
      ..headers.addAll(await _client.authHeaders())
      ..files.add(await http.MultipartFile.fromPath('file', file.path));
    final response = await request.send();
    if (response.statusCode != 204) {
      throw ApiException(response.statusCode, 'POST $path');
    }
  }

  Uri clipUrl(String eventId) => _client.uri('/motion-events/$eventId/clip');

  /// Headers the video player must send when streaming [clipUrl], since
  /// clips are only served to members of the camera's household.
  Future<Map<String, String>> clipHeaders() => _client.authHeaders();
}
