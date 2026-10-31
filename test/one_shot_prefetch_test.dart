import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/one_shot_prefetch.dart';

void main() {
  test(
    'scroll retention preserves completed data but never extends its TTL',
    () async {
      var now = Duration.zero;
      var cancelled = 0;
      final cache = OneShotPrefetch<String, String>(
        lifetime: const Duration(seconds: 10),
        elapsed: () => now,
      )..start('video', () async => 'raw', cancel: () => cancelled++);
      await Future<void>.delayed(Duration.zero);
      now = const Duration(seconds: 9);
      expect(cache.clearPendingKeepReady(), isTrue);
      expect(cache.peekReady('video'), 'raw');
      expect(
        cache.start('video', () async => 'replacement', cancel: () {}),
        isFalse,
      );
      now = const Duration(seconds: 10);
      expect(cache.clearPendingKeepReady(), isFalse);
      expect(cache.peekReady('video'), isNull);
      expect(cache.take('video'), isNull);
      expect(cancelled, 1);
    },
  );

  test(
    'scroll cancels pending data and a late completion cannot be retained',
    () async {
      var cancelled = 0;
      final pending = Completer<String>();
      final cache = OneShotPrefetch<String, String>(
        lifetime: const Duration(seconds: 10),
      )..start('video', () => pending.future, cancel: () => cancelled++);
      expect(cache.clearPendingKeepReady(), isFalse);
      pending.complete('late');
      await Future<void>.delayed(Duration.zero);
      expect(cache.peekReady('video'), isNull);
      expect(cache.clearPendingKeepReady(), isFalse);
      expect(cancelled, 1);
    },
  );

  test(
    'retained data respects the complete key and transfers only once',
    () async {
      const key = ('account1', 42, 'HDR', 'voice-on');
      var claimed = 0;
      var cancelled = 0;
      final cache =
          OneShotPrefetch<Object, String>(
            lifetime: const Duration(seconds: 10),
          )..start(
            key,
            () async => 'raw',
            cancel: () => cancelled++,
            onClaim: () => claimed++,
          );
      await Future<void>.delayed(Duration.zero);
      expect(cache.clearPendingKeepReady(), isTrue);
      expect(cache.peekReady(('account2', 42, 'HDR', 'voice-on')), isNull);
      expect(cache.peekReady(('account1', 43, 'HDR', 'voice-on')), isNull);
      expect(cache.peekReady(('account1', 42, 'SD', 'voice-on')), isNull);
      expect(cache.peekReady(('account1', 42, 'HDR', 'voice-off')), isNull);
      expect(await cache.take(key), 'raw');
      expect(cache.peekReady(key), isNull);
      expect(cache.take(key), isNull);
      cache.clear();
      expect((claimed, cancelled), (1, 0));
    },
  );

  test('background clearing still cancels completed retained data', () async {
    var cancelled = 0;
    final cache = OneShotPrefetch<String, String>(
      lifetime: const Duration(seconds: 10),
    )..start('video', () async => 'raw', cancel: () => cancelled++);
    await Future<void>.delayed(Duration.zero);
    expect(cache.clearPendingKeepReady(), isTrue);
    cache.clear();
    expect(cache.peekReady('video'), isNull);
    expect(cancelled, 1);
  });

  test(
    'late successful replacement never publishes stale ready data',
    () async {
      final old = Completer<String>();
      final cache =
          OneShotPrefetch<String, String>(
              lifetime: const Duration(seconds: 10),
            )
            ..start('old', () => old.future, cancel: () {})
            ..start('new', () async => 'new raw', cancel: () {});
      await Future<void>.delayed(Duration.zero);
      old.complete('old raw');
      await Future<void>.delayed(Duration.zero);
      expect(cache.peekReady('old'), isNull);
      expect(cache.peekReady('new'), 'new raw');
    },
  );

  test(
    'matching request is reused once and ownership transfers on claim',
    () async {
      var cancelled = 0;
      var claimed = 0;
      var loads = 0;
      final cache = OneShotPrefetch<String, String>(
        lifetime: const Duration(seconds: 10),
      );
      Future<String> load() async {
        loads++;
        return 'raw';
      }

      expect(
        cache.start(
          'video',
          load,
          cancel: () => cancelled++,
          onClaim: () => claimed++,
        ),
        isTrue,
      );
      expect(cache.start('video', load, cancel: () => cancelled++), isFalse);
      expect(await cache.take('video'), 'raw');
      cache.clear();
      expect(cache.take('video'), isNull);
      expect((loads, cancelled, claimed), (1, 0, 1));
    },
  );

  test('expiry and parameter mismatch cancel speculative work', () {
    var now = Duration.zero;
    var cancelled = 0;
    final cache =
        OneShotPrefetch<Object, String>(
          lifetime: const Duration(seconds: 10),
          elapsed: () => now,
        )..start(
          ('account1', 1, 'language1'),
          () async => 'raw',
          cancel: () => cancelled++,
        );
    expect(cache.take(('account2', 1, 'language1')), isNull);
    cache.start(
      ('account1', 1, 'language1'),
      () async => 'raw',
      cancel: () => cancelled++,
    );
    now = const Duration(seconds: 10);
    expect(cache.take(('account1', 1, 'language1')), isNull);
    expect(cancelled, 2);
  });

  test('late failure cannot clear a newer entry', () async {
    final first = Completer<String>();
    var cancelled = 0;
    final cache =
        OneShotPrefetch<String, String>(
            lifetime: const Duration(seconds: 10),
          )
          ..start('old', () => first.future, cancel: () => cancelled++)
          ..start('new', () async => 'new raw', cancel: () => cancelled++);
    first.completeError(StateError('old failure'));
    await Future<void>.delayed(Duration.zero);
    expect(await cache.take('new'), 'new raw');
    expect(cancelled, 1);
  });

  test('cleared in-flight result cannot repopulate the cache', () async {
    final result = Completer<String>();
    final cache =
        OneShotPrefetch<String, String>(
            lifetime: const Duration(seconds: 10),
          )
          ..start('old', () => result.future, cancel: () {})
          ..clear();
    result.complete('late raw');
    await Future<void>.delayed(Duration.zero);
    expect(cache.take('old'), isNull);
  });

  test(
    'claimed in-flight errors reach consumer without being retained',
    () async {
      final result = Completer<String>();
      final cache = OneShotPrefetch<String, String>(
        lifetime: const Duration(seconds: 10),
      )..start('video', () => result.future, cancel: () {});
      final claimed = cache.take('video')!;
      final checked = expectLater(claimed, throwsStateError);
      result.completeError(StateError('network failure'));
      await checked;
      expect(cache.take('video'), isNull);
    },
  );
}
