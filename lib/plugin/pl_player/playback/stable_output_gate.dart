import 'dart:async';

enum StableOutputResult { stable, cancelled, bypass, timeout }

/// Observe valid output immediately, then verify it across two frame boundaries
/// or an uninterrupted [stableDwell] interval without requesting frames.
/// Invalid output waits for a notification instead of polling or scheduling UI.
class StableOutputGate {
  StableOutputGate({
    required this.readSignature,
    required this.nextFrame,
    required this.isCurrent,
    required this.shouldBypass,
    this.isSourceReady,
    required Future<void> cancelled,
    this.stableDwell,
    Duration minimum = const Duration(milliseconds: 120),
    Duration timeout = const Duration(seconds: 5),
  }) {
    _minimumElapsed = minimum == Duration.zero;
    if (!_minimumElapsed) {
      _minimumTimer = Timer(minimum, () {
        _minimumElapsed = true;
        notifyChanged();
      });
    }
    _deadline = Timer(timeout, () => _finish(StableOutputResult.timeout));
    unawaited(cancelled.then((_) => _finish(StableOutputResult.cancelled)));
  }

  final String? Function() readSignature;
  final Duration? stableDwell;
  final Future<void> Function() nextFrame;
  final bool Function() isCurrent;
  final bool Function() shouldBypass;
  final bool Function()? isSourceReady;
  final _ready = Completer<StableOutputResult>();
  Timer? _minimumTimer;
  Timer? _deadline;
  Timer? _dwellTimer;
  bool _dwellElapsed = false;
  bool _minimumElapsed = false;
  bool _framePending = false;
  int _generation = 0;
  int samples = 0;
  String? signature;

  Future<StableOutputResult> get ready => _ready.future;

  void notifyChanged() => _observe(frame: false);

  void _observe({required bool frame}) {
    if (_ready.isCompleted) return;
    try {
      if (!isCurrent()) {
        _finish(StableOutputResult.cancelled);
        return;
      }
      if (shouldBypass()) {
        _finish(StableOutputResult.bypass);
        return;
      }
      final current = isSourceReady?.call() == false ? null : readSignature();
      if (current != signature) {
        _dwellTimer?.cancel();
        _dwellTimer = null;
        _dwellElapsed = false;
        signature = current;
        samples = current == null ? 0 : 1;
        _generation++;
      } else if (current != null && frame) {
        samples++;
      }
      if (current == null) return;
      if (stableDwell case final dwell?) {
        if (_dwellElapsed) {
          if (_minimumElapsed) _finish(StableOutputResult.stable);
        } else {
          _dwellTimer ??= Timer(dwell, () {
            _dwellTimer = null;
            _dwellElapsed = true;
            _observe(frame: true);
          });
        }
        return;
      }
      if (samples >= 3) {
        if (_minimumElapsed) _finish(StableOutputResult.stable);
        return;
      }
      if (!_framePending) {
        _framePending = true;
        final generation = _generation;
        unawaited(
          nextFrame().then((_) {
            _framePending = false;
            // A change away and back within one frame must restart stability.
            _observe(frame: generation == _generation);
          }, onError: _fail),
        );
      }
    } catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _fail(Object error, StackTrace stack) {
    if (_ready.isCompleted) return;
    _minimumTimer?.cancel();
    _deadline?.cancel();
    _dwellTimer?.cancel();
    _ready.completeError(error, stack);
  }

  void _finish(StableOutputResult result) {
    if (_ready.isCompleted) return;
    _minimumTimer?.cancel();
    _deadline?.cancel();
    _dwellTimer?.cancel();
    _ready.complete(result);
  }

  void dispose() => _finish(StableOutputResult.cancelled);
}
