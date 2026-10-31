import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/playback/bounded_body_warmup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bounded prefill pauses upstream and claim preserves all bytes',
    () async {
      var pauses = 0;
      final source = StreamController<List<int>>(
        sync: true,
        onPause: () => pauses++,
      );
      final warm = BoundedBodyWarmup(source.stream, limit: 6);
      source
        ..add([0, 1, 2, 3])
        ..add([4, 5, 6, 7]);
      expect(
        warm.prefetchedBytes,
        8,
      ); // Limit plus only the last incoming chunk.
      expect(pauses, 1);
      source.add([8, 9]);
      expect(warm.prefetchedBytes, 8);
      final result = warm.stream.expand((chunk) => chunk).toList();
      await source.close();
      expect(await result, List.generate(10, (i) => i));
      await warm.close();
    },
  );

  test(
    'claim delivers available bytes without waiting to fill its limit',
    () async {
      final source = StreamController<List<int>>(sync: true);
      final warm = BoundedBodyWarmup(source.stream, limit: 100);
      source.add([1, 2, 3]);
      final consumer = StreamIterator(warm.stream);
      expect(
        await consumer.moveNext().timeout(const Duration(seconds: 1)),
        isTrue,
      );
      expect(consumer.current, [1, 2, 3]);
      await consumer.cancel();
      await source.close();
    },
  );

  test('unclaimed paused warmup cancels without needing a consumer', () async {
    var cancellations = 0;
    final source = StreamController<List<int>>(
      sync: true,
      onCancel: () => cancellations++,
    );
    final warm = BoundedBodyWarmup(source.stream, limit: 2);
    source.add([1, 2]);
    await warm.close().timeout(const Duration(seconds: 1));
    await warm.close();
    expect(cancellations, 1);
    await source.close();
  });

  test(
    'an early body failure remains visible to its eventual consumer',
    () async {
      final source = StreamController<List<int>>(sync: true);
      final warm = BoundedBodyWarmup(source.stream, limit: 10);
      source.addError(StateError('fixture body failed'));
      await expectLater(warm.stream.drain<void>(), throwsStateError);
      await warm.close();
      await source.close();
    },
  );
}
