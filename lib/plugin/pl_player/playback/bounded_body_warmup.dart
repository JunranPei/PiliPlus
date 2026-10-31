import 'dart:async';

/// Reads ahead until [limit] bytes, then pauses the single upstream listener.
/// The bound can be exceeded by the last incoming chunk; no further chunk is
/// requested while unclaimed. Claiming never waits to fill the buffer.
class BoundedBodyWarmup {
  BoundedBodyWarmup(
    Stream<List<int>> source, {
    required this.limit,
    this.onEvent,
  }) {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit');
    _output = StreamController<List<int>>(
      onListen: () {
        _claimed = true;
        onEvent?.call('claim', {'prefetchedBytes': prefetchedBytes});
        _pause(false);
      },
      onPause: () => _pause(true),
      onResume: () => _pause(false),
      onCancel: close,
    );
    _input = source.listen(
      (chunk) {
        if (_closed) return;
        _output.add(chunk);
        if (!_claimed) {
          final first = prefetchedBytes == 0;
          prefetchedBytes += chunk.length;
          if (first) onEvent?.call('firstChunk', {'bytes': chunk.length});
          if (prefetchedBytes >= limit) {
            _pause(true);
            if (!_ready.isCompleted) _ready.complete(true);
            onEvent?.call('paused', {
              'prefetchedBytes': prefetchedBytes,
              'limit': limit,
              'lastChunkBytes': chunk.length,
            });
          }
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!_ready.isCompleted) _ready.complete(false);
        if (!_closed) _output.addError(error, stack);
      },
      onDone: () {
        if (!_ready.isCompleted) _ready.complete(false);
        _output.close().ignore();
      },
    );
  }

  final int limit;
  final void Function(String, Map<String, Object?>)? onEvent;
  late final StreamController<List<int>> _output;
  late final StreamSubscription<List<int>> _input;
  bool _claimed = false;
  bool _paused = false;
  bool _closed = false;
  int prefetchedBytes = 0;
  final _ready = Completer<bool>();

  Stream<List<int>> get stream => _output.stream;

  /// True when the unclaimed prefix reached its bound; false on early EOF,
  /// error, or close. Claiming the stream itself never waits for this future.
  Future<bool> get ready => _ready.future;

  void _pause(bool paused) {
    if (_closed || _paused == paused) return;
    _paused = paused;
    if (paused) {
      _input.pause();
    } else {
      _input.resume();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_ready.isCompleted) _ready.complete(false);
    await _input.cancel();
    // A controller closed before being claimed completes only after a listener
    // drains it. Cancellation must not wait on a listener that will never exist.
    _output.close().ignore();
  }
}
