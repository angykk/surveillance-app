/// Runs an async job one at a time, for work like opening the camera that
/// lifecycle changes can both ask for again and make stale part-way through.
///
/// A [run] while the job is running doesn't start a second copy alongside
/// it; the job runs once more after the current one finishes. [cancel]
/// marks the running job stale: its `isCurrent` callback turns false, so it
/// can drop what it opened instead of handing it over.
class SerialTask {
  SerialTask(this._job);

  final Future<void> Function(bool Function() isCurrent) _job;
  bool _running = false;
  bool _again = false;
  int _generation = 0;

  Future<void> run() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        final generation = _generation;
        await _job(() => generation == _generation);
      } while (_again);
    } finally {
      _running = false;
    }
  }

  /// Makes the running job stale and drops any run asked for before now.
  void cancel() {
    _generation++;
    _again = false;
  }
}
