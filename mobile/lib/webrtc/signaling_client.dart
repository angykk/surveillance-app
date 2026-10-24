import 'package:socket_io_client/socket_io_client.dart' as io;

/// The Socket.IO control connection shared by Camera Mode and Viewer Mode:
/// rosters, motion events, and who's watching which camera. Live video
/// itself goes through LiveKit; this socket only hands out the
/// [StreamGrant]s for joining a camera's room.
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

  /// The reason the server gave for refusing the connection (e.g.
  /// `'device_revoked'`, `'unauthorized'`), or null for a plain network
  /// error, from a `connect_error` event's payload.
  static String? refusalReason(dynamic connectErrorData) =>
      connectErrorData is Map ? connectErrorData['message'] as String? : null;

  void dispose() {
    socket.dispose();
  }
}

/// Where and how to join one camera's LiveKit room: the server's URL plus an
/// access token scoped to that room (publish-only for the camera,
/// subscribe-only for a viewer).
class StreamGrant {
  const StreamGrant({required this.url, required this.token});

  final String url;
  final String token;

  /// Null for anything that isn't a grant, e.g. the empty ack the server
  /// sends when a camera can't be watched.
  static StreamGrant? fromJson(dynamic data) {
    if (data is! Map) return null;
    final url = data['url'];
    final token = data['token'];
    if (url is! String || token is! String) return null;
    return StreamGrant(url: url, token: token);
  }
}
