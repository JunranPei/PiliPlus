import 'dart:async';

/// Owns one speculative request. Claim transfers ownership to ordinary playback;
/// a late result can never repopulate an expired, replaced or consumed entry.
class OneShotPrefetch<K, V> {
  OneShotPrefetch({required this.lifetime, Duration Function()? elapsed})
    : _elapsed = elapsed ?? (Stopwatch()..start()).elapsedDuration;

  final Duration lifetime;
  final Duration Function() _elapsed;
  _PrefetchEntry<K, V>? _entry;

  bool start(
    K key,
    Future<V> Function() load, {
    required void Function() cancel,
    void Function()? onClaim,
  }) {
    final old = _entry;
    if (old != null && old.key == key && _elapsed() < old.expires) {
      return false;
    }
    clear();
    final entry = _PrefetchEntry<K, V>(
      key,
      _elapsed() + lifetime,
      cancel,
      onClaim,
    );
    _entry = entry;
    entry.value = Future<V>.sync(load);
    unawaited(
      entry.value.then<void>(
        (value) {
          if (identical(_entry, entry)) {
            entry
              ..completedValue = value
              ..completed = true;
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_entry, entry)) clear();
        },
      ),
    );
    return true;
  }

  Future<V>? take(K key) {
    final entry = _entry;
    if (entry == null) return null;
    if (entry.key != key || _elapsed() >= entry.expires) {
      clear();
      return null;
    }
    _entry = null;
    entry.onClaim?.call();
    return entry.value;
  }

  /// Reads only an already completed result without extending its original TTL.
  V? peekReady(K key) {
    final entry = _entry;
    if (entry == null) return null;
    if (_elapsed() >= entry.expires) {
      clear();
      return null;
    }
    if (entry.key != key || !entry.completed) return null;
    return entry.completedValue;
  }

  /// Retains data only. The caller must separately close speculative resources.
  bool clearPendingKeepReady() {
    final entry = _entry;
    if (entry != null && entry.completed && _elapsed() < entry.expires) {
      return true;
    }
    clear();
    return false;
  }

  void clear() {
    final entry = _entry;
    _entry = null;
    entry?.cancel();
  }

  void clearIf(K key) {
    if (_entry?.key == key) clear();
  }
}

class _PrefetchEntry<K, V> {
  _PrefetchEntry(this.key, this.expires, this.cancel, this.onClaim);
  final K key;
  final Duration expires;
  final void Function() cancel;
  final void Function()? onClaim;
  late final Future<V> value;
  bool completed = false;
  V? completedValue;
}

extension on Stopwatch {
  Duration elapsedDuration() => elapsed;
}
