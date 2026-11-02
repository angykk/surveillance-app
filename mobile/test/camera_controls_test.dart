import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/signaling/camera_controls.dart';
import 'package:mobile/ui/camera_list_screen.dart';

void main() {
  group('CameraControls', () {
    test('round-trips through the JSON the camera reports', () {
      const controls = CameraControls(torch: true, hasTorch: true, lens: CameraLens.front);
      final parsed = CameraControls.fromJson(controls.toJson())!;
      expect(parsed.torch, isTrue);
      expect(parsed.hasTorch, isTrue);
      expect(parsed.lens, CameraLens.front);
    });

    test('reads missing or unknown fields as the defaults', () {
      expect(CameraControls.fromJson(null), isNull);
      final parsed = CameraControls.fromJson({'torch': 'yes', 'lens': 'sideways'})!;
      expect(parsed.torch, isFalse);
      expect(parsed.hasTorch, isFalse);
      expect(parsed.lens, CameraLens.back);
    });

    test('comes with an online camera in the roster', () {
      final camera = CameraInfo.fromJson({
        'id': 'c1',
        'name': 'Front Door',
        'household_id': 'h1',
        'household_name': 'Home',
        'online': true,
        'last_seen_at': null,
        'controls': {'torch': false, 'has_torch': true, 'lens': 'back'},
      });
      expect(camera.controls?.hasTorch, isTrue);
      final offline = CameraInfo.fromJson({
        'id': 'c2',
        'name': 'Garage',
        'household_id': 'h1',
        'household_name': 'Home',
        'online': false,
        'last_seen_at': null,
        'controls': null,
      });
      expect(offline.controls, isNull);
    });
  });

  test('ControlAction uses the server\'s action names', () {
    expect(ControlAction.values.map((a) => a.wireName), ['torch', 'switch-lens', 'snapshot']);
    expect(ControlAction.fromName('switch-lens'), ControlAction.switchLens);
    expect(ControlAction.fromName('self-destruct'), isNull);
  });

  test('control errors read as messages, with a fallback', () {
    expect(controlErrorMessage('no-torch'), 'This lens has no torch.');
    expect(controlErrorMessage('something-new'), 'The camera couldn\'t do that.');
  });
}

