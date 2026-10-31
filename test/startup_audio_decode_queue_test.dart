import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/playback/startup_audio_decode_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late String value;
  late List<String> writes;
  late List<Map<String, Object?>> events;
  late Completer<void> ready;
  late Completer<void> cancelled;
  late bool owner;

  StartupAudioDecodeQueue begin({
    void Function(String)? write,
    Duration deadline = const Duration(seconds: 5),
  }) => StartupAudioDecodeQueue(
    readSeconds: () => value,
    writeSeconds:
        write ??
        (next) {
          writes.add(next);
          value = next;
        },
    ownsPlayer: () => owner,
    frameReady: ready.future,
    cancelled: cancelled.future,
    deadline: deadline,
    onEvent: (name, data) => events.add({'event': name, ...data}),
  );

  setUp(() {
    value = '2.000000';
    writes = [];
    events = [];
    ready = Completer<void>();
    cancelled = Completer<void>();
    owner = true;
  });

  test('current source frame restores exact original value once', () async {
    final bound = begin();
    expect(value, '0.08');
    await Future<void>.delayed(Duration.zero);
    expect(writes, ['0.08']);
    ready.complete();
    await Future<void>.delayed(Duration.zero);
    expect(value, '2.000000');
    cancelled.complete();
    bound.restore('dispose');
    await Future<void>.delayed(Duration.zero);
    expect(writes, ['0.08', '2.000000']);
    expect(events.last['reason'], 'source-frame');
  });

  test(
    'cancel restores before frame and stale completion leaves next limit alone',
    () async {
      begin();
      cancelled.complete();
      await Future<void>.delayed(Duration.zero);
      expect(value, '2.000000');
      final oldReady = ready;
      ready = Completer<void>();
      cancelled = Completer<void>();
      begin();
      oldReady.complete();
      await Future<void>.delayed(Duration.zero);
      expect(value, '0.08');
      ready.complete();
      await Future<void>.delayed(Duration.zero);
      expect(writes, ['0.08', '2.000000', '0.08', '2.000000']);
    },
  );

  test('explicit cancel restores before ownership is invalidated', () async {
    final bound = begin();
    bound.restore('source-cancelled');
    owner = false;
    cancelled.complete();
    ready.complete();
    await Future<void>.delayed(Duration.zero);
    expect(value, '2.000000');
    expect(writes, ['0.08', '2.000000']);
    expect(events.last['reason'], 'source-cancelled');
  });

  test('deadline restores when no source frame arrives', () async {
    begin(deadline: Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(value, '2.000000');
    expect(events.last['reason'], 'deadline');
  });

  test(
    'failed frame observer restores without an unhandled future error',
    () async {
      begin();
      ready.completeError(StateError('load failed'));
      await Future<void>.delayed(Duration.zero);
      expect(value, '2.000000');
      expect(events.last['reason'], 'frame-error');
    },
  );

  test('changed player ownership prevents a stale setting write', () async {
    begin();
    owner = false;
    ready.complete();
    await Future<void>.delayed(Duration.zero);
    expect(writes, ['0.08']);
    expect(events.last['ownerChanged'], true);
  });

  test('explicit capacity change during startup is preserved', () async {
    begin();
    value = '0.5';
    cancelled.complete();
    await Future<void>.delayed(Duration.zero);
    expect(value, '0.5');
    expect(writes, ['0.08']);
    expect(events.last['settingChanged'], true);
  });

  test('already smaller capacity is not increased', () async {
    value = '0.04';
    begin();
    ready.complete();
    await Future<void>.delayed(Duration.zero);
    expect(value, '0.04');
    expect(writes, isEmpty);
  });

  test('zero means unlimited and is restored as zero', () async {
    value = '0';
    begin();
    expect(value, '0.08');
    cancelled.complete();
    await Future<void>.delayed(Duration.zero);
    expect(value, '0');
  });

  test('write throwing after mutation restores original capacity', () async {
    begin(
      write: (next) {
        writes.add(next);
        value = next;
        if (next == '0.08') throw StateError('backend failure after write');
      },
    );
    expect(value, '2.000000');
    expect(events.map((e) => e['event']), ['limitError', 'restored']);
    await Future<void>.delayed(Duration.zero);
    expect(writes.length, 2);
  });

  test('unsupported property leaves playback untouched', () async {
    value = 'unavailable';
    begin();
    ready.complete();
    await Future<void>.delayed(Duration.zero);
    expect(writes, isEmpty);
    expect(value, 'unavailable');
  });
}
