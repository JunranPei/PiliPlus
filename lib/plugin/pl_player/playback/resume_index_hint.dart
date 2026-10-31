import 'dart:typed_data';

/// Only a prediction hint. Fresh native Range and response length validation
/// still determine which bytes can be consumed; this never supplies media data.
class ResumeIndexHint {
  ResumeIndexHint({required this.prefix, required this.totalBytes});

  final Uint8List prefix;
  final int totalBytes;
}

/// Small, expiring metadata cache shared by sequential transports on the UI
/// isolate. Values sent to workers contain neither sockets nor playback state.
class ResumeIndexHintCache {
  ResumeIndexHintCache({
    this.capacity = 4,
    this.maxPrefixBytes = 64 * 1024,
    this.ttl = const Duration(minutes: 2),
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int capacity;
  final int maxPrefixBytes;
  final Duration ttl;
  final int Function() _nowMs;
  final _entries = <String, ({ResumeIndexHint hint, int atMs})>{};

  ResumeIndexHint? get(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    final age = _nowMs() - entry.atMs;
    if (age < 0 || age >= ttl.inMilliseconds) {
      _entries.remove(key);
      return null;
    }
    return ResumeIndexHint(
      prefix: Uint8List.fromList(entry.hint.prefix),
      totalBytes: entry.hint.totalBytes,
    );
  }

  bool put(String key, ResumeIndexHint hint) {
    if (capacity <= 0 ||
        key.isEmpty ||
        hint.prefix.isEmpty ||
        hint.prefix.length > maxPrefixBytes ||
        hint.totalBytes <= hint.prefix.length) {
      return false;
    }
    _entries.remove(key);
    _entries[key] = (
      hint: ResumeIndexHint(
        prefix: Uint8List.fromList(hint.prefix),
        totalBytes: hint.totalBytes,
      ),
      atMs: _nowMs(),
    );
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
    return true;
  }
}
