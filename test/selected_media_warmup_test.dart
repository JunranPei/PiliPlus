import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/plugin/pl_player/playback/isolated_media_sources.dart';
import 'package:PiliPlus/plugin/pl_player/playback/selected_media_warmup.dart';
import 'package:PiliPlus/plugin/pl_player/playback/visible_media_prefetch.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport extends IsolatedMediaSources {
  _Transport(
    Map<String, String> headers,
    void Function(String, Map<String, Object?>)? event,
  ) : super(headers: headers, onEvent: event);
  final ready = Completer<({String video, String audio})>();
  final closed = Completer<void>();
  int closes = 0;
  @override
  Future<({String video, String audio})> start(
    String video,
    String audio, {
    List<String> videoAlternatives = const [],
    List<String> audioAlternatives = const [],
    Duration resumePosition = Duration.zero,
  }) => ready.future;
  @override
  void close() {
    closes++;
    if (!closed.isCompleted) closed.complete();
  }
}

void main() {
  test(
    'different resume positions discard the old pending transport',
    () async {
      late _Transport transport;
      final cache =
          SelectedMediaWarmup(
            create: (headers, event) => transport = _Transport(headers, event),
          )..start(
            scope: 'account',
            video: 'video',
            audio: 'audio',
            headers: {},
            start: const Duration(seconds: 60),
          );
      expect(
        await cache.take(
          scope: 'account',
          video: 'video',
          audio: 'audio',
          headers: {},
          start: const Duration(seconds: 61),
        ),
        isNull,
      );
      expect(transport.closes, 1);
      transport.ready.complete((video: 'local-video', audio: 'local-audio'));
      expect(
        await cache.take(
          scope: 'account',
          video: 'video',
          audio: 'audio',
          headers: {},
          start: const Duration(seconds: 60),
        ),
        isNull,
      );
    },
  );

  test(
    'exact resume position transfers once and survives later UI clear',
    () async {
      late _Transport transport;
      final cache =
          SelectedMediaWarmup(
            create: (headers, event) => transport = _Transport(headers, event),
          )..start(
            scope: 'account',
            video: 'video',
            audio: 'audio',
            headers: {},
            start: const Duration(milliseconds: 60123),
          );
      final lease = await cache.take(
        scope: 'account',
        video: 'video',
        audio: 'audio',
        headers: {},
        start: const Duration(milliseconds: 60123),
      );
      expect(lease!.start, const Duration(milliseconds: 60123));
      cache.clear();
      expect(transport.closes, 0);
      transport.ready.complete((video: 'local-video', audio: 'local-audio'));
      expect(await lease.urls, (video: 'local-video', audio: 'local-audio'));
      lease.close();
      expect(transport.closes, 1);
    },
  );

  test(
    'unclaimed response closes at the deadline without another UI action',
    () async {
      final transports = <_Transport>[];
      final cache =
          SelectedMediaWarmup(
            lifetime: const Duration(milliseconds: 20),
            create: (headers, event) {
              final transport = _Transport(headers, event);
              transports.add(transport);
              return transport;
            },
          )..start(
            scope: 'account',
            video: 'video',
            audio: 'audio',
            headers: {},
          );
      expect(transports.single.closes, 0);
      await transports.single.closed.future.timeout(const Duration(seconds: 1));
      expect(transports.single.closes, 1);
      cache.clear();
      expect(transports.single.closes, 1);
    },
  );

  test(
    'account, selected URL and headers must all match before transfer',
    () async {
      for (final changed in ['account', 'video', 'audio', 'headers']) {
        late _Transport transport;
        final cache =
            SelectedMediaWarmup(
              create: (headers, event) =>
                  transport = _Transport(headers, event),
            )..start(
              scope: 'account',
              video: 'video',
              audio: 'audio',
              headers: {'Referer': 'one'},
            );
        expect(
          await cache.take(
            scope: changed == 'account' ? 'other' : 'account',
            video: changed == 'video' ? 'other' : 'video',
            audio: changed == 'audio' ? 'other' : 'audio',
            headers: {'Referer': changed == 'headers' ? 'other' : 'one'},
          ),
          isNull,
        );
        expect(transport.closes, 1);
      }
    },
  );

  test(
    'claim transfers a pending worker once; later UI clear cannot close it',
    () async {
      late _Transport transport;
      final cache =
          SelectedMediaWarmup(
            create: (headers, event) => transport = _Transport(headers, event),
          )..start(
            scope: 'account',
            video: 'video',
            audio: 'audio',
            headers: {'A': '1', 'B': '2'},
          );
      final lease = await cache.take(
        scope: 'account',
        video: 'video',
        audio: 'audio',
        headers: {'B': '2', 'A': '1'},
      );
      cache.clear();
      expect(lease!.transport, same(transport));
      expect(transport.closes, 0);
      expect(
        await cache.take(
          scope: 'account',
          video: 'video',
          audio: 'audio',
          headers: {'A': '1', 'B': '2'},
        ),
        isNull,
      );
      transport.ready.complete((video: 'local-video', audio: 'local-audio'));
      expect((await lease.urls).video, 'local-video');
      lease.transport.close();
      expect(transport.closes, 1);
    },
  );

  test('worker failure is observed and can fall back after claim', () async {
    late _Transport transport;
    final cache = SelectedMediaWarmup(
      create: (headers, event) => transport = _Transport(headers, event),
    )..start(scope: 'account', video: 'video', audio: 'audio', headers: {});
    transport.ready.completeError(StateError('worker failed'));
    final lease = await cache.take(
      scope: 'account',
      video: 'video',
      audio: 'audio',
      headers: {},
    );
    await expectLater(lease!.urls, throwsStateError);
    lease.transport.close();
    expect(transport.closes, 1);
  });

  test(
    'actual worker reuses both upstream responses and returns their bytes',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String, int>{};
      upstream.listen((request) async {
        final path = request.uri.path;
        requests.update(path, (count) => count + 1, ifAbsent: () => 1);
        final payload = List<int>.filled(1024, path == '/video' ? 86 : 65);
        request.response
          ..statusCode = HttpStatus.partialContent
          ..contentLength = payload.length;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-1023/1024',
        );
        request.response.add(payload);
        await request.response.close();
      });
      final warmed = Completer<void>();
      final stopped = Completer<void>();
      var headersSeen = 0;
      void event(String name, Map<String, Object?> data) {
        if (name.endsWith('.headers') && ++headersSeen == 2) warmed.complete();
        if (name == 'isolated.closed' && !stopped.isCompleted) {
          stopped.complete();
        }
      }

      final cache = SelectedMediaWarmup();
      final client = HttpClient();
      MediaWarmupLease? lease;
      final video = 'http://127.0.0.1:${upstream.port}/video';
      final audio = 'http://127.0.0.1:${upstream.port}/audio';
      try {
        cache.start(
          scope: 'account',
          video: video,
          audio: audio,
          headers: {},
          onEvent: event,
        );
        await warmed.future.timeout(const Duration(seconds: 5));
        lease = await cache.take(
          scope: 'account',
          video: video,
          audio: audio,
          headers: {},
          onEvent: event,
        );
        final urls = await lease!.urls;
        for (final source in [(urls.video, 86), (urls.audio, 65)]) {
          final response = await (await client.getUrl(Uri.parse(source.$1)))
              .close();
          final body = await response.fold<List<int>>(
            [],
            (bytes, chunk) => bytes..addAll(chunk),
          );
          expect(body, List<int>.filled(1024, source.$2));
        }
        expect(requests, {'/video': 1, '/audio': 1});
      } finally {
        cache.clear();
        lease?.transport.close();
        client.close(force: true);
        await upstream.close(force: true);
      }
      await stopped.future.timeout(const Duration(seconds: 3));
    },
  );

  PlayUrlModel fixture() => PlayUrlModel.fromJson({
    'accept_quality': [80, 64],
    'dash': {
      'video': [
        {'id': 80, 'codecs': 'hev1', 'baseUrl': 'https://example.test/hevc'},
        {'id': 80, 'codecs': 'avc1', 'baseUrl': 'https://example.test/avc'},
      ],
      'audio': [
        {'id': 30280, 'baseUrl': 'https://example.test/high-audio'},
        {'id': 30216, 'baseUrl': 'https://example.test/low-audio'},
      ],
    },
    'support_formats': [
      {
        'quality': 80,
        'codecs': ['hev1', 'avc1'],
      },
    ],
  });
  test('prediction respects quality, preferred codec and audio quality', () {
    final tracks = predictWarmupTracks(
      fixture(),
      videoQuality: 80,
      audioQuality: 30216,
      codecs: [VideoDecodeFormatType.AVC, VideoDecodeFormatType.HEVC],
    );
    expect(tracks!.video.codecs, 'avc1');
    expect(tracks.audio.id, 30216);
  });
  test('missing selected quality and nonzero resume skip prediction', () {
    expect(
      predictWarmupTracks(
        fixture(),
        videoQuality: 64,
        audioQuality: 30216,
        codecs: [VideoDecodeFormatType.AVC],
      ),
      isNull,
    );
    expect(
      predictWarmupTracks(
        fixture()..lastPlayTime = 60000,
        videoQuality: 80,
        audioQuality: 30216,
        codecs: [VideoDecodeFormatType.AVC],
      ),
      isNull,
    );
  });
  test(
    'resume opt-in preserves selected track quality and exact model progress',
    () {
      final model = fixture()..lastPlayTime = 60123;
      final tracks = predictWarmupTracks(
        model,
        videoQuality: 80,
        audioQuality: 30216,
        codecs: [VideoDecodeFormatType.AVC, VideoDecodeFormatType.HEVC],
        allowResume: true,
      );
      expect(tracks!.video.codecs, 'avc1');
      expect(tracks.audio.id, 30216);
      expect(model.lastPlayTime, 60123);
    },
  );
}
