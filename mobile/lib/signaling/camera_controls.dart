/// Which of the phone's cameras is filming. Cameras start on the rear one,
/// and go back to it whenever they restart.
enum CameraLens {
  back,
  front;

  static CameraLens fromName(Object? name) => values.where((l) => l.name == name).firstOrNull ?? back;
}

/// What a viewer can remotely change on a camera, as the camera reports it
/// (`camera-controls`) and rosters carry it back while the camera is online.
class CameraControls {
  const CameraControls({this.torch = false, this.hasTorch = false, this.lens = CameraLens.back});

  final bool torch;

  /// Whether the lens in use has a torch (front lenses usually don't).
  final bool hasTorch;
  final CameraLens lens;

  Map<String, dynamic> toJson() => {'torch': torch, 'has_torch': hasTorch, 'lens': lens.name};

  static CameraControls? fromJson(Object? json) {
    if (json is! Map) return null;
    return CameraControls(
      torch: json['torch'] == true,
      hasTorch: json['has_torch'] == true,
      lens: CameraLens.fromName(json['lens']),
    );
  }
}

/// A remote control a viewer sends a camera (`camera-control`), which the
/// server passes on as `control`.
enum ControlAction {
  torch('torch'),
  switchLens('switch-lens'),
  snapshot('snapshot');

  const ControlAction(this.wireName);

  final String wireName;

  static ControlAction? fromName(Object? name) => values.where((a) => a.wireName == name).firstOrNull;
}

/// Why a remote control didn't work, from the `error` in its ack, as a
/// message for the viewer.
String controlErrorMessage(Object? error) => switch (error) {
      'offline' => 'The camera is offline.',
      'timeout' => 'The camera didn\'t answer.',
      'no-torch' => 'This lens has no torch.',
      'not-ready' => 'The camera is still starting.',
      _ => 'The camera couldn\'t do that.',
    };
