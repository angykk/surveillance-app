/// What a motion event shows, least to most important. The names match the
/// server's `motion_events.label`.
enum MotionLabel {
  motion,
  pet,
  person;

  /// The label the server sent, or [motion] for anything unknown.
  static MotionLabel fromName(Object? name) =>
      values.firstWhere((label) => label.name == name, orElse: () => motion);

  bool outranks(MotionLabel other) => index > other.index;
}

/// What a camera opens a motion event for, set from Viewer Mode. The names
/// match the server's `devices.detection_mode`.
enum DetectionMode {
  /// Only once the person detector sees someone.
  person,

  /// Any motion, as the background subtraction sees it.
  any;

  static DetectionMode fromName(Object? name) =>
      values.firstWhere((mode) => mode.name == name, orElse: () => person);
}
