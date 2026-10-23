import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// Socket.IO connection plus the RTCPeerConnection setup shared by Camera
/// Mode (offerer) and Viewer Mode (answerer): both need the same ICE server
/// config and the same "queue ICE candidates until the remote description is
/// set" handling, since candidates can arrive before the offer/answer does.
class SignalingClient {
  /// [auth] builds the Socket.IO `auth` payload — `{'device_token': ...}`
  /// for a camera, `{'token': <Supabase access token>}` for a viewer. It's
  /// re-run on every handshake, reconnects included, so a viewer always
  /// presents a current access token rather than whichever one was live
  /// when the socket was first created.
  SignalingClient(String serverUrl, {required Future<Map<String, dynamic>> Function() auth})
      : socket = io.io(serverUrl, <String, dynamic>{
          'transports': ['websocket'],
          'autoConnect': false,
          // socket_io_client caches one socket per URL; without this a new
          // client (e.g. after switching modes) could get back a disposed
          // socket still carrying the previous client's auth.
          'forceNew': true,
          'auth': (dynamic sendConnectPacket) {
            // An empty payload still gets sent on failure, so the server
            // refuses with `connect_error` instead of the handshake hanging.
            auth().catchError((Object _) => <String, dynamic>{}).then((data) => sendConnectPacket(data));
          },
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

  /// The reason the server gave for refusing the connection (e.g.
  /// `'device_revoked'`, `'unauthorized'`), or null for a plain network
  /// error, from a `connect_error` event's payload.
  static String? refusalReason(dynamic connectErrorData) =>
      connectErrorData is Map ? connectErrorData['message'] as String? : null;

  void dispose() {
    socket.dispose();
    pc?.close();
  }
}
