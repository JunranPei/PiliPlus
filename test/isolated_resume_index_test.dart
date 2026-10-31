import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/playback/isolated_media_sources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/resume_index_fixture.dart';

void main() {
  test(
    'a new worker reuses only the index and requests both current URLs early',
    () async {
      final bytes = resumeIndexFixture();
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final consumer = HttpClient();
      final releaseHeaders = Completer<void>();
      final bothEarlyTargets = Completer<void>();
      final stored = Completer<void>();
      final early = <String>{};
      final secondAgents = <String?>[];
      final firstRanges = <String>[];
      final events = <String>[];
      var storedCount = 0;
      final transports = <IsolatedMediaSources>[];
      origin.listen((request) {
        unawaited(
          () async {
            final range = request.headers.value('range')!;
            if (request.uri.queryParameters['token'] == 'second') {
              secondAgents.add(request.headers.value('User-Agent'));
              if (range == 'bytes=0-') {
                await releaseHeaders.future;
              } else if (range == 'bytes=600000-') {
                early.add(request.uri.path);
                if (early.length == 2 && !bothEarlyTargets.isCompleted) {
                  bothEarlyTargets.complete();
                }
              }
            } else {
              firstRanges.add(range);
            }
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
      Future<List<int>> read(String url, String range) async {
        final request = await consumer.getUrl(Uri.parse(url));
        request.headers.set('range', range);
        final response = await request.close();
        expect(response.statusCode, 206);
        return response.fold<List<int>>([], (a, b) => a..addAll(b));
      }

      Future<({String video, String audio})> start(String token) {
        final transport = IsolatedMediaSources(
          headers: {'User-Agent': token},
          onEvent: (name, data) {
            events.add('$token $name $data');
            if (name == 'isolated.indexHint.stored' && data['cached'] == true) {
              if (++storedCount == 2) stored.complete();
            }
          },
        );
        transports.add(transport);
        return transport.start(
          'http://127.0.0.1:${origin.port}/video?token=$token',
          'http://127.0.0.1:${origin.port}/audio?token=$token',
          resumePosition: token == 'first'
              ? Duration.zero
              : const Duration(seconds: 10),
        );
      }

      try {
        final first = await start('first');
        expect(
          await read(first.video, 'bytes=0-65535'),
          bytes.sublist(0, 65536),
        );
        expect(
          await read(first.audio, 'bytes=0-65535'),
          bytes.sublist(0, 65536),
        );
        await stored.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail('Index not stored: $events'),
        );
        expect(firstRanges, everyElement('bytes=0-'));
        transports.first.close();
        final second = await start('second');
        await bothEarlyTargets.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () =>
              fail('Target requests not concurrent: $early $events'),
        );
        expect(secondAgents, everyElement('second'));
        releaseHeaders.complete();
        expect(
          await read(second.video, 'bytes=0-65535'),
          bytes.sublist(0, 65536),
        );
        expect(
          await read(second.audio, 'bytes=0-65535'),
          bytes.sublist(0, 65536),
        );
        expect(
          await read(second.video, 'bytes=600000-600031'),
          bytes.sublist(600000, 600032),
        );
        expect(
          await read(second.audio, 'bytes=600000-600031'),
          bytes.sublist(600000, 600032),
        );
      } finally {
        if (!releaseHeaders.isCompleted) releaseHeaders.complete();
        for (final transport in transports) {
          transport.close();
        }
        consumer.close(force: true);
        await origin.close(force: true);
      }
    },
    skip:
        !const bool.fromEnvironment('REUSE_RESUME_INDEX') ||
        !const bool.fromEnvironment('PREFETCH_RESUME_AUDIO_MASTER') ||
        !const bool.fromEnvironment('PREFETCH_RESUME_PRESENTATION_TIME'),
  );
}
