import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/playback/playback_source_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'replacement cancels an event wait but still waits for cleanup',
    () async {
      final queue = PlaybackSourceQueue();
      final started = Completer<PlaybackSourceRequest>();
      final frame = Completer<void>();
      final cleanupStarted = Completer<void>();
      final cleanupFinished = Completer<void>();
      final events = <String>[];

      final first = queue.run(Object(), (request) async {
        events.add('first started');
        started.complete(request);
        try {
          await Future.any([frame.future, request.cancelled]);
          request.checkCurrent();
          events.add('obsolete frame revealed');
          return true;
        } finally {
          cleanupStarted.complete();
          await cleanupFinished.future;
          events.add('first cleanup finished');
        }
      });
      final firstRequest = await started.future;
      final second = queue.run(Object(), (request) async {
        events.add('second started');
        return true;
      });

      expect(firstRequest.isCurrent, isFalse);
      expect(queue.busy, isTrue);
      await cleanupStarted.future;
      expect(events, ['first started']);

      cleanupFinished.complete();
      expect(await first, isFalse);
      expect(await second, isTrue);
      expect(events, [
        'first started',
        'first cleanup finished',
        'second started',
      ]);
      expect(queue.busy, isFalse);
    },
  );

  test('repeated clicks before execution run only the latest intent', () async {
    final queue = PlaybackSourceQueue();
    final owner = Object();
    final executed = <int>[];
    final results = <Future<bool>>[];

    for (var click = 0; click < 4; click += 1) {
      results.add(
        queue.run(owner, (request) async {
          executed.add(request.id);
          return true;
        }),
      );
    }

    expect(queue.busy, isTrue);
    expect(await Future.wait(results), [false, false, false, true]);
    expect(executed, [4]);
    expect(queue.busy, isFalse);
  });

  test('a newer queued request replaces an intermediate route', () async {
    final queue = PlaybackSourceQueue();
    final started = Completer<void>();
    final finishOldLoad = Completer<void>();
    final executed = <String>[];

    final first = queue.run(Object(), (request) async {
      executed.add('first');
      started.complete();
      await finishOldLoad.future;
      // Even an action without an explicit check cannot report stale success.
      return true;
    });
    await started.future;
    final second = queue.run(Object(), (request) async {
      executed.add('second');
      return true;
    });
    final third = queue.run(Object(), (request) async {
      executed.add('third');
      return true;
    });

    expect(executed, ['first']);
    finishOldLoad.complete();
    expect(await Future.wait([first, second, third]), [false, false, true]);
    expect(executed, ['first', 'third']);
  });

  test('another route cannot cancel the active owner', () async {
    final queue = PlaybackSourceQueue();
    final owner = Object();
    final started = Completer<PlaybackSourceRequest>();
    final finish = Completer<void>();
    final result = queue.run(owner, (request) async {
      started.complete(request);
      await finish.future;
      request.checkCurrent();
      return true;
    });
    final request = await started.future;

    queue.cancel(Object());
    expect(request.isCurrent, isTrue);
    expect(request.owner, same(owner));
    finish.complete();
    expect(await result, isTrue);
    expect(request.isCurrent, isTrue);
    expect(queue.busy, isFalse);

    queue.cancel(owner);
    await request.cancelled;
    expect(request.isCurrent, isFalse);
    expect(request.checkCurrent, throwsA(isA<PlaybackSourceCancelled>()));
  });

  test(
    'cancelAll releases active waits and skips queued source work',
    () async {
      final queue = PlaybackSourceQueue();
      final started = Completer<PlaybackSourceRequest>();
      final first = queue.run(Object(), (request) async {
        started.complete(request);
        await request.cancelled;
        request.checkCurrent();
        return true;
      });
      final request = await started.future;
      var queuedRan = false;
      final queued = queue.run(Object(), (request) async {
        queuedRan = true;
        return true;
      });

      queue
        ..cancelAll()
        ..cancelAll();
      expect(request.isCurrent, isFalse);
      expect(await Future.wait([first, queued]), [false, false]);
      expect(queuedRan, isFalse);
      expect(queue.busy, isFalse);
      expect(await queue.run(Object(), (request) async => true), isTrue);
    },
  );

  test(
    'source failure reaches its caller without poisoning the queue',
    () async {
      final queue = PlaybackSourceQueue();
      final started = Completer<void>();
      final failOpen = Completer<void>();
      final failure = StateError('opening media failed');
      final first = queue.run(Object(), (request) async {
        started.complete();
        await failOpen.future;
        return true;
      });
      final assertion = expectLater(first, throwsA(same(failure)));
      await started.future;
      var secondRan = false;
      final second = queue.run(Object(), (request) async {
        secondRan = true;
        return true;
      });

      expect(secondRan, isFalse);
      failOpen.completeError(failure);
      await assertion;
      expect(await second, isTrue);
      expect(secondRan, isTrue);
      expect(queue.busy, isFalse);
    },
  );

  test('completed identity is retained until replacement', () async {
    final queue = PlaybackSourceQueue();
    late PlaybackSourceRequest completed;
    expect(
      await queue.run(Object(), (request) async {
        completed = request;
        return false;
      }),
      isFalse,
    );

    expect(completed.isCurrent, isTrue);
    expect(queue.busy, isFalse);
    final next = queue.run(Object(), (request) async {
      expect(request.id, completed.id + 1);
      return true;
    });
    expect(completed.isCurrent, isFalse);
    await completed.cancelled;
    expect(await next, isTrue);
  });
}
