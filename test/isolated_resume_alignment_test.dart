import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/playback/isolated_media_sources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/resume_index_fixture.dart';

void main() {
  test(
    'legacy boundary worker aligns audio when its initialization arrives first',
    () async {
      final bytes = resumeIndexFixture();
      final requests = <String>[];
      final events = <String>[];
      final closed = Completer<void>();
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final consumer = HttpClient();
      final transport = IsolatedMediaSources(
        headers: {'User-Agent': 'fixture'},
        onEvent: (name, _) {
          events.add(name);
          if (name == 'isolated.closed' && !closed.isCompleted) {
            closed.complete();
          }
        },
      );
      origin.listen((request) {
        unawaited(
          () async {
            final range = request.headers.value('range')!;
            requests.add('${request.uri.path}:$range');
            final start = int.parse(
              RegExp(r'^bytes=(\d+)-').firstMatch(range)![1]!,
            );
            request.response
              ..statusCode = 206
              ..contentLength = bytes.length - start;
            request.response.headers.set(
              'content-range',
              'bytes $start-${bytes.length - 1}/${bytes.length}',
            );
            request.response.add(bytes.sublist(start));
            await request.response.close();
          }().catchError((Object _) {}),
        );
      });
      Future<List<int>> read(String url, String range) async {
        final request = await consumer.getUrl(Uri.parse(url));
        request.headers.set('range', range);
        final response = await request.close();
        expect(response.statusCode, 206);
        return response.fold<List<int>>([], (a, b) => a..addAll(b));
      }

      try {
        final urls = await transport.start(
          'http://127.0.0.1:${origin.port}/video',
          'http://127.0.0.1:${origin.port}/audio',
          resumePosition: const Duration(seconds: 14),
        );
        expect(
          await read(urls.audio, 'bytes=0-65535'),
          bytes.sublist(0, 65536),
        );
        expect(requests.where((r) => !r.endsWith(':bytes=0-')), isEmpty);
        expect(
          await read(urls.video, 'bytes=0-65535'),
          bytes.sublist(0, 65536),
        );
        expect(
          await read(urls.video, 'bytes=600000-600031'),
          bytes.sublist(600000, 600032),
        );
        expect(
          await read(urls.audio, 'bytes=500032-500063'),
          bytes.sublist(500032, 500064),
        );
        expect(
          requests,
          containsAll(['/video:bytes=600000-', '/audio:bytes=500000-']),
        );
        expect(requests, isNot(contains('/audio:bytes=600000-')));
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
        consumer.close(force: true);
        await origin.close(force: true);
      }
    },
    skip:
        !const bool.fromEnvironment('PREFETCH_RESUME_AUDIO_MASTER') ||
        const bool.fromEnvironment('PREFETCH_RESUME_PRESENTATION_TIME'),
  );
}
