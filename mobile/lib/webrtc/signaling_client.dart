import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// Socket.IO connection plus the RTCPeerConnection setup shared by Camera
/// Mode (offerer) and Viewer Mode (answerer): both need the same ICE server
/// config and the same "queue ICE candidates until the remote description is
/// set" handling, since candidates can arrive before the offer/answer does.
class SignalingClient {
  /// [role] is 'camera' or 'viewer'. [extraQuery] carries role-specific
  /// identity — a camera sends `camera_id`/`camera_name` so the server can
  /// recognize it across reconnects and list it for viewers. Sent as query
  /// params so they're included on every handshake, reconnects included.
  SignalingClient(String serverUrl, {required String role, Map<String, String> extraQuery = const {}})
      : socket = io.io(serverUrl, <String, dynamic>{
          'transports': ['websocket'],
          'autoConnect': false,
          'query': {'role': role, ...extraQuery},
        });

  final io.Socket socket;
  RTCPeerConnection? pc;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  Future<RTCPeerConnection> createConnection() async {
    // Guards against leaking a stale connection if this is called again
    // (e.g. a fresh offer after a reconnect) before the previous one was
    // explicitly reset.
    await resetConnection();

    final connection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    }, {});

    connection.onIceCandidate = (RTCIceCandidate candidate) {
      socket.emit('icecandidate', {
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
        'candidate': candidate.candidate,
      });
    };

    pc = connection;
    return connection;
  }

  Future<void> addRemoteIceCandidate(dynamic data) async {
    final connection = pc;
    if (connection == null) return;

    final candidate = RTCIceCandidate(
      data['candidate'] as String?,
      data['sdpMid'] as String?,
      data['sdpMLineIndex'] as int?,
    );

    final remoteDescription = await connection.getRemoteDescription();
    if (remoteDescription == null) {
      _pendingRemoteCandidates.add(candidate);
      return;
    }
    await connection.addCandidate(candidate);
  }

  Future<void> flushPendingIceCandidates() async {
    final connection = pc;
    if (connection == null) return;
    for (final candidate in _pendingRemoteCandidates) {
      await connection.addCandidate(candidate);
    }
    _pendingRemoteCandidates.clear();
  }

  /// Tears down the peer connection without touching the socket, so a new
  /// one can be created the next time a viewer joins.
  Future<void> resetConnection() async {
    await pc?.close();
    pc = null;
    _pendingRemoteCandidates.clear();
  }

  void dispose() {
    socket.dispose();
    pc?.close();
  }
}
