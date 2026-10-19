import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/playback/playback_source_queue.dart';

/// Open the actual source paused while its page is mounting. Playback remains
/// the caller's responsibility after both steps complete for the current owner.
abstract final class SourcePreparation {
  static const enabled = bool.fromEnvironment('SOURCE_EARLY_PREPARE');

  static Future<void> overlap({
    required PlaybackSourceRequest request,
    required Future<void> Function() openPaused,
    required Future<void> Function() preparePresentation,
  }) async {
    request.checkCurrent();
    final presentation = Future<void>.sync(preparePresentation);
    // A page may disappear or fail while mpv is accepting the source. Observe
    // its error immediately, then propagate it when joining the two steps.
    presentation.ignore();
    // Keep the serialized player's write alive until open has actually returned.
    await openPaused();
    request.checkCurrent();
    await Future.any<void>([
      presentation,
      request.cancelled.then<void>(
        (_) => throw const PlaybackSourceCancelled(),
      ),
    ]);
    request.checkCurrent();
  }
}
