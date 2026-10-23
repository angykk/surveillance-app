import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/api/households_api.dart';

void main() {
  group('PairingCode.parse', () {
    test('accepts a scanned QR payload', () {
      expect(PairingCode.parse('survcam:pair:ABCD2345'), 'ABCD2345');
    });

    test('accepts a hand-typed code, as displayed or sloppily', () {
      expect(PairingCode.parse('ABCD-2345'), 'ABCD2345');
      expect(PairingCode.parse(' abcd 2345 '), 'ABCD2345');
    });

    test('rejects anything that is not an 8-character code', () {
      expect(PairingCode.parse('https://example.com'), isNull);
      expect(PairingCode.parse('ABC'), isNull);
      expect(PairingCode.parse('survcam:pair:'), isNull);
    });

    test('round-trips through the QR payload', () {
      final code = PairingCode(code: 'XYZW6789', expiresAt: DateTime(2030));
      expect(PairingCode.parse(code.qrPayload), 'XYZW6789');
    });
  });
}
