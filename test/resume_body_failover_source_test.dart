import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/parallel_audio_source.dart';
import 'package:PiliPlus/plugin/pl_player/playback/resume_index_hint.dart';

import 'fixtures/resume_index_fixture.dart';

void main() {
  for (final enabled in [false, true]) {
    for (final warmup in [false, true]) {
      test(
        'real proxy body-stall recovery enabled=$enabled warmup=$warmup',
        () async {
          final bytes = resumeIndexFixture();
          final release = Completer<void>();
          final firstBody = Completer<void>();
          final switched = Completer<void>();
          final events = <String>[];
          final primary = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final backup = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final consumer = HttpClient();
          final ranges = <String>[];
          Future<void> serve(HttpRequest request, bool slow) async {
            final match = RegExp(r'bytes=(\d+)-(\d*)')
                .firstMatch(request.headers.value('range')!)!;
            final start = int.parse(match[1]!);
            final end = match[2]!.isEmpty
                ? bytes.length - 1
                : int.parse(match[2]!);
            if (!slow) ranges.add(request.headers.value('range')!);
            request.response
              ..statusCode = 206
              ..contentLength = end - start + 1
              ..bufferOutput = false
              ..headers.set(
                'content-range',
                'bytes $start-$end/${bytes.length}',
              );
            if (slow && start == 500000) {
              request.response.add(bytes.sublist(start, start + 113000));
              await request.response.flush();
              await release.future;
              request.response.add(bytes.sublist(start + 113000, end + 1));
            } else {
              request.response.add(bytes.sublist(start, end + 1));
            }
            await request.response.close();
          }

          primary.listen((r) => serve(r, true).catchError((Object _) {}));
          backup.listen((r) => serve(r, false).catchError((Object _) {}));
          final source = ParallelAudioSource(
            headers: {},
            resumeBodyFailover: enabled,
            resumeBodyProgressRace: enabled,
            resumeBodyWarmup: warmup,
            resumeBodyHedge: false,
            hedgeResumePrefetch: false,
            cancelClosedDelivery: true,
            resumePosition: const Duration(seconds: 10),
            resumeIndexHint: ResumeIndexHint(
              prefix: bytes.sublist(0, 96),
              totalBytes: bytes.length,
            ),
            onEvent: (name, _) {
              events.add(name);
              if (name == 'audio.prefetch.resume.bodyRecovery.switched') {
                switched.complete();
              }
            },
          );
          try {
            final url = await source.start(
              'http://127.0.0.1:${primary.port}/media',
              alternatives: ['http://127.0.0.1:${backup.port}/media'],
              hedgeAfter: const Duration(seconds: 10),
            );
            final init = await consumer.getUrl(Uri.parse(url));
            init.headers.set('range', 'bytes=0-65535');
            expect(
              await (await init.close()).fold<List<int>>(
                [],
                (a, b) => a..addAll(b),
              ),
              bytes.sublist(0, 65536),
            );
            final request = await consumer.getUrl(Uri.parse(url));
            request.headers.set('range', 'bytes=500000-');
            final response = await request.close();
            expect(
              response.headers.value('content-range'),
              'bytes 500000-899999/900000',
            );
            final result = response
                .map((chunk) {
                  if (!firstBody.isCompleted) firstBody.complete();
                  return chunk;
                })
                .fold<List<int>>([], (a, b) => a..addAll(b));
            await firstBody.future;
            expect(switched.isCompleted, isFalse);
            expect(release.isCompleted, isFalse);
            if (enabled) {
              await switched.future.timeout(const Duration(seconds: 3));
              expect(await result, bytes.sublist(500000));
              expect(ranges, ['bytes=547464-']);
              expect(release.isCompleted, isFalse);
            } else {
              await Future<void>.delayed(const Duration(milliseconds: 450));
              expect(switched.isCompleted, isFalse);
              expect(ranges, isEmpty);
              release.complete();
              expect(await result, bytes.sublist(500000));
            }
          } finally {
            source.close();
            if (!release.isCompleted) release.complete();
            consumer.close(force: true);
            await primary.close(force: true);
            await backup.close(force: true);
          }
        },
      );
    }
  }
}
