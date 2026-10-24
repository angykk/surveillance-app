import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/signaling/signaling_client.dart';

void main() {
  test('only a server-ended connection needs a manual reconnect', () {
    expect(SignalingClient.serverEndedConnection('io server disconnect'), isTrue);
    // These socket_io_client reconnects after by itself, or this side chose.
    expect(SignalingClient.serverEndedConnection('io client disconnect'), isFalse);
    expect(SignalingClient.serverEndedConnection('transport close'), isFalse);
    expect(SignalingClient.serverEndedConnection('ping timeout'), isFalse);
    expect(SignalingClient.serverEndedConnection(null), isFalse);
  });

  test('refusalReason reads the server\'s reason', () {
    expect(SignalingClient.refusalReason({'message': 'device_revoked'}), 'device_revoked');
    expect(SignalingClient.refusalReason('websocket error'), isNull);
  });

  test('StreamGrant.fromJson accepts only a full grant', () {
    final grant = StreamGrant.fromJson({'url': 'ws://lk', 'token': 't'});
    expect((grant?.url, grant?.token), ('ws://lk', 't'));
    expect(StreamGrant.fromJson(null), isNull);
    expect(StreamGrant.fromJson({'url': 'ws://lk'}), isNull);
  });
}
