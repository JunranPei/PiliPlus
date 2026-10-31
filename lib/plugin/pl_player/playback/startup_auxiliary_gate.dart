import 'dart:async';

/// Gives playback first use of startup resources without starving page data.
class StartupAuxiliaryGate {
  final _pending = <Completer<String>>{};

  Future<String> wait({
    required Stream<bool> readiness,
    required bool Function() isReady,
    Duration deadline = const Duration(milliseconds: 1500),
  }) async {
    if (isReady()) return 'ready';
    final done = Completer<String>();
    _pending.add(done);
    void finish(String reason) {
      if (!done.isCompleted) done.complete(reason);
    }

    final subscription = readiness.listen((ready) {
      if (ready) finish('ready');
    }, onDone: () => finish('cancelled'));
    final timer = Timer(deadline, () => finish('deadline'));
    // Subscribe before checking again so a transition cannot be missed.
    if (isReady()) finish('ready');
    try {
      return await done.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
      _pending.remove(done);
    }
  }

  void cancel() {
    for (final done in _pending.toList()) {
      if (!done.isCompleted) done.complete('cancelled');
    }
  }
}
