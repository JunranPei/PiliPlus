import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/playback/isolated_media_sources.dart';
import 'package:PiliPlus/plugin/pl_player/playback/parallel_audio_source.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/resume_index_fixture.dart';

void main() {
  late HttpServer origin;
  late HttpClient consumer;
  late List<String> requests;
  late List<String> events;
  final bytes = resumeIndexFixture();

  setUp(() async {
    requests = [];
    events = [];
    consumer = HttpClient();
    origin = (await HttpServer.bind(InternetAddress.loopbackIPv4, 0))
      ..listen((request) {
        unawaited(
          () async {
            final range = request.headers.value('range')!;
            requests.add('${request.uri.path}:$range');
            final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
            final start = int.parse(match[1]!);
            final end = match[2]!.isEmpty
                ? bytes.length - 1
                : int.parse(match[2]!);
            request.response
              ..statusCode = 206
              ..contentLength = end - start + 1;
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/${bytes.length}',
            );
            request.response.add(bytes.sublist(start, end + 1));
            await request.response.close();
          }().catchError((Object _) {}),
        );
      });
  });
  tearDown(() async {
    consumer.close(force: true);
    await origin.close(force: true);
  });
  Future<HttpClientResponse> get(
    String url,
    String range, {
    bool follow = true,
  }) async {
    final request = await consumer.getUrl(Uri.parse(url));
    request.followRedirects = follow;
    request.headers.set('range', range);
    return request.close();
  }

  Future<List<int>> body(HttpClientResponse response) =>
      response.fold<List<int>>([], (a, b) => a..addAll(b));

  test('current segment prefetch supplies exact native bytes and preserves an earlier fallback', () async {
    final source = ParallelAudioSource(
      headers: {},
      resumePosition: const Duration(seconds: 10),
      resumePresentationTime: true,
      onEvent: (name, _) => events.add(name),
    );
    try {
      final url = await source.start('http://127.0.0.1:${origin.port}/video');
      expect(
        await body(await get(url, 'bytes=0-65535')),
        bytes.sublist(0, 65536),
      );
      expect(events, isNot(contains('audio.prefetch.resume.firstChunk')));
      // A guarded native path may still request the earlier segment. Preserve
      // that exact request instead of delivering our later prediction.
      final fallback = await get(url, 'bytes=500000-500031', follow: false);
      expect(fallback.statusCode, 307);
      expect(await body(fallback), isEmpty);
      final selected = await get(url, 'bytes=600000-600031');
      expect(
        selected.headers.value('content-range'),
        'bytes 600000-600031/900000',
      );
      expect(await body(selected), bytes.sublist(600000, 600032));
      expect(requests, ['/video:bytes=0-', '/video:bytes=600000-']);
      expect(events, contains('audio.prefetch.resume.claim'));
      source.close();
      expect(events, contains('audio.prefetch.resume.closed'));
    } finally {
      source.close();
    }
  });

  test(
    'isolated worker uses presentation boundaries for both selected tracks',
    () async {
      final closed = Completer<void>();
      final transport = IsolatedMediaSources(
        headers: {},
        onEvent: (name, _) {
          events.add(name);
          if (name == 'isolated.closed' && !closed.isCompleted) {
            closed.complete();
          }
        },
      );
      try {
        final urls = await transport.start(
          'http://127.0.0.1:${origin.port}/video',
          'http://127.0.0.1:${origin.port}/audio',
          resumePosition: const Duration(seconds: 10),
        );
        expect(
          await body(await get(urls.audio, 'bytes=0-65535')),
          bytes.sublist(0, 65536),
        );
        expect(
          await body(await get(urls.video, 'bytes=0-65535')),
          bytes.sublist(0, 65536),
        );
        expect(
          await body(await get(urls.video, 'bytes=600000-600031')),
          bytes.sublist(600000, 600032),
        );
        expect(
          await body(await get(urls.audio, 'bytes=600000-600031')),
          bytes.sublist(600000, 600032),
        );
        expect(
          requests,
          containsAll(['/video:bytes=600000-', '/audio:bytes=600000-']),
        );
        expect(requests.any((r) => r.contains('500000')), isFalse);
        transport.close();
        await closed.future.timeout(const Duration(seconds: 2));
        expect(
          events,
          containsAll([
            'isolated.video.resume.firstChunk',
            'isolated.audio.resume.firstChunk',
            'isolated.video.resume.closed',
            'isolated.audio.resume.closed',
          ]),
        );
        if (const bool.fromEnvironment('PREFETCH_RESUME_BODY')) {
          expect(
            events,
            containsAll([
              'isolated.video.resume.bodyWarmup.claim',
              'isolated.audio.resume.bodyWarmup.claim',
            ]),
          );
        }
      } finally {
        transport.close();
      }
    },
    skip:
        !const bool.fromEnvironment('PREFETCH_RESUME_RANGE') ||
        !const bool.fromEnvironment('PREFETCH_RESUME_PRESENTATION_TIME'),
  );
}
