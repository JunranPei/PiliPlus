import 'dart:async';

/// Temporarily bounds decoded audio ahead of the existing filtered-audio FIFO.
/// It never discards frames or changes the audio output buffer or seek clipping.
class StartupAudioDecodeQueue {
  StartupAudioDecodeQueue({
    required this.readSeconds,
    required this.writeSeconds,
    required this.ownsPlayer,
    required Future<void> frameReady,
    required Future<void> cancelled,
    this.onEvent,
    Duration deadline = const Duration(seconds: 5),
  }) {
    unawaited(
      frameReady.then(
        (_) => restore('source-frame'),
        onError: (Object error) => restore('frame-error'),
      ),
    );
    unawaited(cancelled.then((_) => restore('cancelled')));
    try {
      final previous = readSeconds();
      final value = double.tryParse(previous);
      if (value == null ||
          !value.isFinite ||
          value < 0 ||
          (value > 0 && value <= seconds)) {
        _finished = true;
        _event('skipped', {'previousSeconds': previous});
        return;
      }
      _previous = previous;
      writeSeconds('$seconds');
      final actual = readSeconds();
      if (double.tryParse(actual) != seconds) {
        throw StateError('Audio decode queue did not accept startup limit');
      }
      _timer = Timer(deadline, () => restore('deadline'));
      _event('limited', {
        'previousSeconds': previous,
        'actualSeconds': actual,
      });
    } catch (error) {
      _event('limitError', {'type': error.runtimeType.toString()});
      restore('limit-error');
    }
  }

  static const seconds = 0.08;
  final String Function() readSeconds;
  final void Function(String) writeSeconds;
  final bool Function() ownsPlayer;
  final void Function(String, Map<String, Object?>)? onEvent;
  String? _previous;
  Timer? _timer;
  bool _finished = false;

  void _event(String name, Map<String, Object?> data) =>
      onEvent?.call(name, data);

  void restore(String reason) {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    _timer = null;
    final previous = _previous;
    if (previous == null) return;
    if (!ownsPlayer()) {
      _event('restoreSkipped', {'reason': reason, 'ownerChanged': true});
      return;
    }
    try {
      final before = readSeconds();
      // A newer owner or an explicit setting must not be overwritten.
      if (double.tryParse(before) != seconds) {
        _event('restoreSkipped', {
          'reason': reason,
          'actualSeconds': before,
          'settingChanged': true,
        });
        return;
      }
      writeSeconds(previous);
      final after = readSeconds();
      if (double.tryParse(after) != double.tryParse(previous)) {
        throw StateError(
          'Audio decode queue did not restore its original limit',
        );
      }
      _event('restored', {
        'reason': reason,
        'previousSeconds': before,
        'actualSeconds': after,
      });
    } catch (error) {
      _event('restoreError', {
        'reason': reason,
        'type': error.runtimeType.toString(),
      });
    }
  }
}
