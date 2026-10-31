import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_source_queue.dart';
import 'package:PiliPlus/plugin/pl_player/playback/source_preparation.dart';

void main() {
  test(
    'opens media while presentation is still pending and joins both',
    () async {
      final queue = PlaybackSourceQueue();
      final mounted = Completer<void>();
      final opened = Completer<void>();
      var complete = false;
      final pending = queue.run('page', (request) async {
        await SourcePreparation.overlap(
          request: request,
          openPaused: () async {
            opened.complete();
          },
          preparePresentation: () => mounted.future,
        );
        complete = true;
        return true;
      });
      await opened.future;
      expect(complete, false);
      mounted.complete();
      expect(await pending, true);
    },
  );

  test(
    'cancelled presentation cannot block next source or leak readiness',
    () async {
      final queue = PlaybackSourceQueue();
      final opened = Completer<void>();
      var staleReady = false;
      final pending = queue.run('old', (request) async {
        await SourcePreparation.overlap(
          request: request,
          openPaused: () async {
            opened.complete();
          },
          preparePresentation: () => Completer<void>().future,
        );
        staleReady = true;
        return true;
      });
      await opened.future;
      final replacement = queue.run('new', (_) async => true);
      expect(await pending.timeout(const Duration(seconds: 1)), false);
      expect(await replacement.timeout(const Duration(seconds: 1)), true);
      expect(staleReady, false);
    },
  );

  test(
    'presentation failure observes errors but waits for native write to finish',
    () async {
      final queue = PlaybackSourceQueue();
      final accepted = Completer<void>();
      final began = Completer<void>();
      var replacementBegan = false;
      final pending = queue.run('old', (request) async {
        await SourcePreparation.overlap(
          request: request,
          openPaused: () {
            began.complete();
            return accepted.future;
          },
          preparePresentation: () =>
              Future<void>.error(StateError('page failed')),
        );
        return true;
      });
      await began.future;
      final replacement = queue.run('new', (_) async {
        replacementBegan = true;
        return true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(replacementBegan, false);
      accepted.complete();
      expect(await pending, false);
      expect(await replacement, true);
    },
  );
}
