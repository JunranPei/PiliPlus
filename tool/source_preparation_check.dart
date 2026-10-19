import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/playback/playback_source_queue.dart';
import 'package:PiliPlus/plugin/pl_player/playback/source_preparation.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

Future<void> main() async {
  var passed = 0;
  {
    final queue = PlaybackSourceQueue();
    final page = Completer<void>();
    var opened = false;
    var published = false;
    final done = queue.run('first', (request) async {
      await SourcePreparation.overlap(
        request: request,
        openPaused: () async {
          opened = true;
        },
        preparePresentation: () => page.future,
      );
      published = true;
      return true;
    });
    await tick();
    require(
      opened && !published,
      'Real media must open before the page finishes',
    );
    page.complete();
    require(await done && published, 'Publication must wait for both steps');
    passed++;
  }
  {
    final queue = PlaybackSourceQueue();
    final open = Completer<void>();
    final page = Completer<void>();
    var secondStarted = false;
    var firstPublished = false;
    final first = queue.run('first', (request) async {
      await SourcePreparation.overlap(
        request: request,
        openPaused: () => open.future,
        preparePresentation: () => page.future,
      );
      firstPublished = true;
      return true;
    });
    await tick();
    final second = queue.run('second', (_) async {
      secondStarted = true;
      return true;
    });
    await tick();
    require(!secondStarted, 'Replacement must not race a pending player write');
    open.complete();
    require(
      !await first && await second && !firstPublished,
      'Cancellation must release page wait without publishing old media',
    );
    page.complete();
    passed++;
  }
  {
    final queue = PlaybackSourceQueue();
    final open = Completer<void>();
    var rejected = false;
    final first = queue
        .run('first', (request) async {
          await SourcePreparation.overlap(
            request: request,
            openPaused: () => open.future,
            preparePresentation: () =>
                Future<void>.error(StateError('page failed')),
          );
          return true;
        })
        .then<void>(
          (_) {},
          onError: (Object error) {
            rejected = true;
          },
        );
    await tick();
    require(!rejected, 'Page error must remain observed while open is pending');
    open.complete();
    await first;
    require(
      rejected && await queue.run('next', (_) async => true),
      'Page failure must propagate and leave the source queue usable',
    );
    passed++;
  }
  {
    final queue = PlaybackSourceQueue();
    final page = Completer<void>();
    var rejected = false;
    await queue
        .run('first', (request) async {
          await SourcePreparation.overlap(
            request: request,
            openPaused: () => Future<void>.error(StateError('media failed')),
            preparePresentation: () => page.future,
          );
          return true;
        })
        .then<void>(
          (_) {},
          onError: (Object error) {
            rejected = true;
          },
        );
    page.completeError(StateError('late page failure'));
    await tick();
    require(
      rejected && await queue.run('next', (_) async => true),
      'Media failure and late page failure must not break the queue',
    );
    passed++;
  }
  print('$passed source preparation checks passed');
}
