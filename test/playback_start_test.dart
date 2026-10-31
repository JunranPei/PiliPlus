import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/playback/playback_start.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cancelled native write finishes before returning, without presentation',
    () async {
      final native = Completer<void>();
      var current = true;
      var presented = false;
      var activated = false;
      var finished = false;
      final result =
          PlaybackStart.run(
            isCurrent: () => current,
            isPlaying: () => true,
            start: () => native.future,
            present: () async {
              presented = true;
            },
            activate: () => activated = true,
          ).then((value) {
            finished = true;
            return value;
          });
      current = false;
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      native.complete();
      expect(await result, isFalse);
      expect(presented, isFalse);
      expect(activated, isFalse);
    },
  );

  for (final reason in ['cancel', 'replace', 'pause']) {
    test('$reason during presentation does not activate late', () async {
      final showing = Completer<void>();
      final entered = Completer<void>();
      var current = true;
      var owner = 1;
      var playing = true;
      var activated = false;
      final result = PlaybackStart.run(
        isCurrent: () => current && owner == 1,
        isPlaying: () => playing,
        start: () async {},
        present: () {
          entered.complete();
          return showing.future;
        },
        activate: () => activated = true,
      );
      await entered.future;
      if (reason == 'cancel') current = false;
      if (reason == 'replace') owner = 2;
      if (reason == 'pause') playing = false;
      showing.complete();
      expect(await result, isFalse);
      expect(activated, isFalse);
    });
  }

  test('current playing source activates once after presentation', () async {
    final events = <String>[];
    expect(
      await PlaybackStart.run(
        isCurrent: () => true,
        isPlaying: () => true,
        start: () async {
          events.add('start');
        },
        present: () async {
          events.add('present');
        },
        activate: () => events.add('activate'),
      ),
      isTrue,
    );
    expect(events, ['start', 'present', 'activate']);
  });

  test('native failure propagates without activating', () async {
    var activated = false;
    await expectLater(
      PlaybackStart.run(
        isCurrent: () => true,
        isPlaying: () => true,
        start: () => Future<void>.error(StateError('native failure')),
        present: () => throw StateError('must not present'),
        activate: () => activated = true,
      ),
      throwsStateError,
    );
    expect(activated, isFalse);
  });
}
