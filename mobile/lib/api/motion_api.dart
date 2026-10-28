import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../motion/motion_label.dart';
import 'api_client.dart';

/// One stretch of movement a camera's motion detector saw. [endedAt] is null
/// while the motion is still going on; [hasClip] turns true once the camera
/// has uploaded its recording of it, shortly after it ends. [thumbnailUrl] is
/// a still of the moment motion started, usually there within seconds; it's
/// signed and short-lived, like a clip's URL.
class MotionEvent {
  const MotionEvent({
    required this.id,
    required this.cameraId,
    required this.startedAt,
    required this.endedAt,
    required this.hasClip,
    this.label = MotionLabel.motion,
    this.thumbnailUrl,
  });

  final String id;
  final String cameraId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final bool hasClip;

  /// What the camera saw: a person, a pet, or just motion.
  final MotionLabel label;
  final Uri? thumbnailUrl;

  bool get ongoing => endedAt == null;

  factory MotionEvent.fromJson(Map<dynamic, dynamic> json) => MotionEvent(
        id: json['id'] as String,
        cameraId: json['camera_id'] as String,
        startedAt: dateTimeFromEpochSeconds(json['started_at'] as num),
        endedAt: json['ended_at'] == null ? null : dateTimeFromEpochSeconds(json['ended_at'] as num),
        hasClip: json['has_clip'] as bool? ?? false,
        label: MotionLabel.fromName(json['label']),
        thumbnailUrl: json['thumbnail_url'] == null ? null : Uri.parse(json['thumbnail_url'] as String),
      );
}

/// A camera's motion history and clips. Viewer Mode (a user-signed
/// [ApiClient]) loads the timeline and streams clips; Camera Mode (a
/// device-signed one) uploads each event's thumbnail and clip. New events arrive live over
/// the signaling socket as `motion`; this only loads the backlog.
class MotionApi {
  MotionApi(this._client);

  final ApiClient _client;

  Future<List<MotionEvent>> events(String cameraId) async {
    final items = await _client.send('GET', '/devices/$cameraId/motion-events') as List<dynamic>;
    return items.map((e) => MotionEvent.fromJson(e as Map<dynamic, dynamic>)).toList();
  }

  /// Uploads [file] as [eventId]'s clip: the server hands out a signed URL,
  /// the file goes straight to clip storage, then the server is told it's
  /// there. Throws [ApiException] on a refusal from either.
  Future<void> uploadClip(String eventId, File file) => _upload(eventId, 'clip', file, 'video/mp4');

  /// Uploads [file] (a JPEG) as [eventId]'s thumbnail, the same way.
  Future<void> uploadThumbnail(String eventId, File file) => _upload(eventId, 'thumbnail', file, 'image/jpeg');

  Future<void> _upload(String eventId, String kind, File file, String contentType) async {
    final grant = await _client.send('POST', '/motion-events/$eventId/$kind/upload') as Map<String, dynamic>;
    final status = await _put(Uri.parse(grant['url'] as String), file, contentType).timeout(_transferTimeout);
    if (status != 200) throw ApiException(status, 'PUT $kind upload');
    await _client.send('POST', '/motion-events/$eventId/$kind/done', expectStatus: 204);
  }

  /// Streams [file] as the request body rather than reading it into memory.
  static Future<int> _put(Uri url, File file, String contentType) async {
    final request = http.StreamedRequest('PUT', url)
      ..headers['Content-Type'] = contentType
      ..contentLength = await file.length();
    final sent = request.send();
    await request.sink.addStream(file.openRead());
    await request.sink.close();
    final response = await sent;
    await response.stream.drain<void>();
    return response.statusCode;
  }

  /// Covers the transfer of a file itself (a clip's upload or download),
  /// which takes much longer than an ordinary API call on a slow link.
  static const _transferTimeout = Duration(minutes: 5);

  /// A short-lived URL the video player streams [eventId]'s clip from. It's
  /// signed for that one clip, so the player sends no auth headers.
  Future<Uri> clipUrl(String eventId) async {
    final data = await _client.send('GET', '/motion-events/$eventId/clip-url') as Map<String, dynamic>;
    return Uri.parse(data['url'] as String);
  }

  /// Deletes [eventId] with its clip and thumbnail, for the whole household.
  /// Owners and admins only; an event still being recorded gets a 409.
  Future<void> deleteEvent(String eventId) =>
      _client.send('DELETE', '/motion-events/$eventId', expectStatus: 204);

  /// Downloads [event]'s clip to a temporary file named after [cameraName]
  /// and when it started, for handing to the share sheet. Earlier downloads
  /// are cleared out first, so they don't pile up.
  Future<File> downloadClip(MotionEvent event, String cameraName) async {
    final url = await clipUrl(event.id);
    final dir = Directory('${(await getTemporaryDirectory()).path}/shared-clips');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final name = cameraName.replaceAll(RegExp(r'[^\w-]+'), '-');
    final file = File('${dir.path}/$name-${DateFormat('yyyyMMdd-HHmmss').format(event.startedAt)}.mp4');

    final client = http.Client();
    try {
      final response = await client.send(http.Request('GET', url)).timeout(_transferTimeout);
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw ApiException(response.statusCode, 'GET clip download');
      }
      await response.stream.pipe(file.openWrite()).timeout(_transferTimeout);
    } finally {
      client.close();
    }
    return file;
  }
}
