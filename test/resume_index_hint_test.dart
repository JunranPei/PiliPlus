import 'dart:typed_data';

import 'package:PiliPlus/plugin/pl_player/playback/resume_index_hint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ResumeIndexHint hint(int value) => ResumeIndexHint(
    prefix: Uint8List.fromList([value, 2]),
    totalBytes: 100,
  );

  test('expired or backward-clock metadata is never reused', () {
    var now = 100;
    final cache = ResumeIndexHintCache(
      nowMs: () => now,
      ttl: const Duration(milliseconds: 10),
    )..put('video', hint(1));
    now = 109;
    expect(cache.get('video'), isNotNull);
    now = 110;
    expect(cache.get('video'), isNull);
    cache.put('video', hint(1));
    now = 109;
    expect(cache.get('video'), isNull);
  });

  test('cache cannot grow beyond its entry and prefix bounds', () {
    final cache = ResumeIndexHintCache(capacity: 2, maxPrefixBytes: 2)
      ..put('one', hint(1))
      ..put('two', hint(2))
      ..put('three', hint(3));
    expect(cache.get('one'), isNull);
    expect(cache.get('two'), isNotNull);
    expect(
      cache.put(
        'large',
        ResumeIndexHint(
          prefix: Uint8List(3),
          totalBytes: 100,
        ),
      ),
      isFalse,
    );
    expect(cache.get('three'), isNotNull);
  });

  test(
    'callers cannot mutate another load hint through shared byte storage',
    () {
      final cache = ResumeIndexHintCache();
      final original = hint(7);
      cache.put('video', original);
      original.prefix[0] = 1;
      final copy = cache.get('video')!;
      expect(copy.prefix[0], 7);
      copy.prefix[0] = 2;
      expect(cache.get('video')!.prefix[0], 7);
    },
  );
}
