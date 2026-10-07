import 'dart:async';

/// A source change which has been replaced or cancelled by its owner.
class PlaybackSourceCancelled implements Exception {
  const PlaybackSourceCancelled();

  @override
  String toString() => 'Playback source request was cancelled';
}

/// Identifies a source change across its asynchronous preparation steps.
class PlaybackSourceRequest {
  PlaybackSourceRequest._(this.id, this.owner);

  final int id;
  final Object owner;
  final Completer<void> _cancelled = Completer<void>();

  /// Remains true after successful completion until replacement or cancellation.
  bool get isCurrent => !_cancelled.isCompleted;

  /// Lets an action stop waiting for events belonging to an obsolete source.
  Future<void> get cancelled => _cancelled.future;

  void checkCurrent() {
    if (!isCurrent) throw const PlaybackSourceCancelled();
  }

  void _cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// Serializes writes to the shared player while keeping only the latest intent.
///
/// Replacement invalidates the previous request immediately, including a request
/// that is still running. It does not start another action until that action has
/// returned: callers should use [PlaybackSourceRequest.cancelled] to release
/// event waits, and [PlaybackSourceRequest.checkCurrent] after asynchronous work.
class PlaybackSourceQueue {
  Future<void> _tail = Future<void>.value();
  PlaybackSourceRequest? _current;
  int _nextId = 0;
  int _pending = 0;

  /// Whether any action is running or waiting to be processed.
  bool get busy => _pending != 0;

  Future<bool> run(
    Object owner,
    Future<bool> Function(PlaybackSourceRequest request) action,
  ) {
    _current?._cancel();
    final request = PlaybackSourceRequest._(++_nextId, owner);
    _current = request;
    _pending += 1;

    final operation = _tail.then<bool>((_) async {
      try {
        request.checkCurrent();
        final result = await action(request);
        request.checkCurrent();
        return result;
      } on PlaybackSourceCancelled {
        return false;
      } finally {
        _pending -= 1;
      }
    });

    // Consume errors only on the internal tail. The original future still
    // reports them to its caller, and the next request remains executable.
    _tail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }

  void cancel(Object owner) {
    if (_current?.owner == owner) _current?._cancel();
  }

  void cancelAll() {
    _current?._cancel();
  }
}
