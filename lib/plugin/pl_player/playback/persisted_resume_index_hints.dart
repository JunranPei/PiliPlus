import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';
import 'package:PiliPlus/plugin/pl_player/playback/mp4_resume_range.dart';
import 'package:PiliPlus/plugin/pl_player/playback/resume_index_hint.dart';

/// Bounded prediction metadata for a later app process. No URLs, headers,
/// progress, or media payloads are stored. Native Range still governs playback.
class PersistedResumeIndexHints {
  PersistedResumeIndexHints(
    this.box, {
    this.capacity = 32,
    this.ttl = const Duration(days: 7),
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Box<dynamic> box;
  final int capacity;
  final Duration ttl;
  final int Function() _nowMs;
  static const _namespace = 'pili_resume_sidx_v1:';
  static const _maximumPrefix = 64 * 1024;
  Future<void> _pending = Future<void>.value();

  String _key(String key) => '$_namespace${sha256.convert(utf8.encode(key))}';

  ResumeIndexHint? get(String key) {
    if (key.isEmpty || capacity <= 0) return null;
    try {
      final entry = box.get(_key(key));
      if (entry is! Map || entry['version'] != 1) return null;
      final at = entry['atMs'];
      final total = entry['totalBytes'];
      final prefix = entry['prefix'];
      if (at is! int || total is! int || prefix is! Uint8List) return null;
      final age = _nowMs() - at;
      if (age < 0 || age >= ttl.inMilliseconds) return null;
      final metadata = _metadataPrefix(prefix, total);
      return metadata == null
          ? null
          : ResumeIndexHint(prefix: metadata, totalBytes: total);
    } catch (_) {
      // A missing, closed, or damaged optional cache is a normal cache miss.
      return null;
    }
  }

  /// Returns the persisted metadata size, or null on failure. Serialize updates
  /// so concurrent audio/video writes cannot exceed the entry bound.
  Future<int?> put(String key, ResumeIndexHint hint) {
    final prefix = _metadataPrefix(hint.prefix, hint.totalBytes);
    if (key.isEmpty || capacity <= 0 || prefix == null) {
      return Future<int?>.value();
    }
    final storageKey = _key(key);
    final at = _nowMs();
    final attempt = _pending.then<int?>((_) async {
      try {
        final keys = box.keys
            .whereType<String>()
            .where((key) => key.startsWith(_namespace) && key != storageKey)
            .toList();
        int storedAt(String key) {
          final value = box.get(key);
          return value is Map && value['atMs'] is int
              ? value['atMs'] as int
              : 0;
        }

        keys.sort((a, b) => storedAt(a).compareTo(storedAt(b)));
        while (keys.length >= capacity) {
          await box.delete(keys.removeAt(0));
        }
        await box.put(storageKey, {
          'version': 1,
          'atMs': at,
          'totalBytes': hint.totalBytes,
          'prefix': prefix,
        });
        return prefix.length;
      } catch (_) {
        return null;
      }
    });
    _pending = attempt.then<void>((_) {});
    return attempt;
  }

  // Trim at the first complete sidx. In particular, never persist an mdat or
  // bytes following the index just because a network chunk included them.
  static Uint8List? _metadataPrefix(Uint8List prefix, int total) {
    if (prefix.length > _maximumPrefix || total <= prefix.length) return null;
    final data = ByteData.sublistView(prefix);
    var offset = 0;
    while (offset + 8 <= prefix.length) {
      var size = data.getUint32(offset);
      final type = data.getUint32(offset + 4);
      var header = 8;
      if (size == 1) {
        if (offset + 16 > prefix.length) return null;
        size = data.getUint64(offset + 8);
        header = 16;
      }
      if (size < header ||
          size > prefix.length - offset ||
          type == 0x6d646174) {
        return null;
      }
      offset += size;
      if (type == 0x73696478) {
        final metadata = Uint8List.fromList(prefix.sublist(0, offset));
        return mp4ResumeRange(
                  metadata,
                  const Duration(microseconds: 1),
                  totalBytes: total,
                ) ==
                null
            ? null
            : metadata;
      }
    }
    return null;
  }
}
