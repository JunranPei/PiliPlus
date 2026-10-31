import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:PiliPlus/plugin/pl_player/playback/isolated_media_sources.dart';
import 'package:PiliPlus/plugin/pl_player/playback/one_shot_prefetch.dart';
import 'package:PiliPlus/plugin/pl_player/playback/prepared_resource.dart';
import 'package:PiliPlus/plugin/pl_player/playback/prepared_media_engine.dart';

typedef MediaWarmupEvent = void Function(String, Map<String, Object?>);
typedef _Key = ({
  Object scope,
  String video,
  String audio,
  String headers,
  Duration start,
});

/// One bounded selected-track transport. Taking it transfers both URLs and the
/// worker, so ordinary playback consumes the existing selected HTTP responses.
class SelectedMediaWarmup {
  SelectedMediaWarmup({
    this.lifetime = const Duration(seconds: 8),
    IsolatedMediaSources Function(Map<String, String>, MediaWarmupEvent?)?
    create,
  }) : _create =
           create ??
           ((headers, event) =>
               IsolatedMediaSources(headers: headers, onEvent: event)),
       _cache = OneShotPrefetch(lifetime: lifetime);

  static const enabled = bool.fromEnvironment('VISIBLE_MEDIA_PREFETCH');
  static final instance = SelectedMediaWarmup();
  final Duration lifetime;
  final IsolatedMediaSources Function(Map<String, String>, MediaWarmupEvent?)
  _create;
  final OneShotPrefetch<_Key, MediaWarmupLease> _cache;

  _Key _key(
    Object scope,
    String video,
    String audio,
    Map<String, String> headers,
    Duration start,
  ) => (
    scope: scope,
    video: video,
    audio: audio,
    headers: jsonEncode(SplayTreeMap<String, String>.of(headers)),
    start: start,
  );

  bool start({
    required Object scope,
    required String video,
    required String audio,
    required Map<String, String> headers,
    Duration start = Duration.zero,
    List<String> videoAlternatives = const [],
    List<String> audioAlternatives = const [],
    MediaWarmupEvent? onEvent,
    void Function(MediaWarmupLease)? prepareEngine,
  }) {
    final key = _key(scope, video, audio, headers, start);
    MediaWarmupLease? lease;
    Timer? deadline;
    return _cache.start(
      key,
      () async {
        final transport = _create(headers, onEvent);
        final urls = transport.start(
          video,
          audio,
          videoAlternatives: videoAlternatives,
          audioAlternatives: audioAlternatives,
          resumePosition: const bool.fromEnvironment('PREFETCH_RESUME_RANGE')
              ? start
              : Duration.zero,
        )..ignore(); // Observe failures even when no player takes the response.
        lease = MediaWarmupLease(transport, urls, start: start);
        prepareEngine?.call(lease!);
        deadline = Timer(lifetime, () => _cache.clearIf(key));
        return lease!;
      },
      cancel: () {
        deadline?.cancel();
        lease?.close();
      },
      onClaim: () => deadline?.cancel(),
    );
  }

  Future<MediaWarmupLease?> take({
    required Object scope,
    required String video,
    required String audio,
    required Map<String, String> headers,
    Duration start = Duration.zero,
    MediaWarmupEvent? onEvent,
  }) async {
    final future = _cache.take(_key(scope, video, audio, headers, start));
    if (future == null) return null;
    final lease = await future;
    lease.transport.onEvent = onEvent;
    return lease;
  }

  void clear() => _cache.clear();
}

class MediaWarmupLease {
  MediaWarmupLease(this.transport, this.urls, {this.start = Duration.zero});
  final Duration start;
  final IsolatedMediaSources transport;
  final Future<({String video, String audio})> urls;
  PreparedResource<PreparedMediaEngine>? preparedEngine;

  void close() {
    unawaited(preparedEngine?.cancel());
    transport.close();
  }
}
