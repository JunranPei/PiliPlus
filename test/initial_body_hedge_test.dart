import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/parallel_audio_source.dart';
import 'package:PiliPlus/plugin/pl_player/playback/resume_index_hint.dart';

import 'fixtures/resume_index_fixture.dart';

void main() {
  for (final enabled in [false, true]) {
    test('headers-first stalled primary with body racing=$enabled', () async {
      final bytes = resumeIndexFixture()..[8] = 99;
      final releasePrimary = Completer<void>();
      final primaryHeaders = Completer<void>();
      final selected = Completer<Map<String, Object?>>();
      final primary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final backup = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final consumer = HttpClient();
      final events = <Map<String, Object?>>[];
      final source = ParallelAudioSource(
        headers: {},
        boundedResumeInit: true,
        initialBodyHedge: enabled,
        cancelClosedDelivery: true,
        resumePosition: const Duration(seconds: 10),
        resumeIndexHint: ResumeIndexHint(
          prefix: resumeIndexFixture().sublist(0, 96),
          totalBytes: bytes.length,
        ),
        onEvent: (name, data) {
          events.add({'event': name, ...data});
          if (name == 'audio.prefetch.selected' && !selected.isCompleted)
            selected.complete(data);
        },
      );
      Future<void> serve(HttpRequest request, bool slow) async {
        final range = request.headers.value('range')!;
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
        final start = int.parse(match[1]!);
        final end = match[2]!.isEmpty
            ? bytes.length - 1
            : math.min(int.parse(match[2]!), bytes.length - 1);
        if (!slow && start == 0) {
          await primaryHeaders.future;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        request.response
          ..statusCode = 206
          ..contentLength = end - start + 1
          ..bufferOutput = false;
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/${bytes.length}',
        );
        if (slow && start == 0) {
          request.response.add(bytes.sublist(0, 1024));
          await request.response.flush();
          primaryHeaders.complete();
          await releasePrimary.future;
          request.response.add(bytes.sublist(1024, end + 1));
        } else {
          request.response.add(bytes.sublist(start, end + 1));
        }
        await request.response.close();
      }

      primary.listen(
        (r) => unawaited(serve(r, true).catchError((Object _) {})),
      );
      backup.listen(
        (r) => unawaited(serve(r, false).catchError((Object _) {})),
      );
      try {
        final url = await source.start(
          'http://127.0.0.1:${primary.port}/media',
          alternatives: ['http://127.0.0.1:${backup.port}/media'],
          hedgeAfter: Duration.zero,
        );
        final request = await consumer.getUrl(Uri.parse(url));
        request.headers.set('range', 'bytes=0-');
        final pending = request.close();
        final winner = await selected.future.timeout(
          const Duration(seconds: 2),
        );
        expect(winner['backup'], enabled);
        expect(releasePrimary.isCompleted, false);
        if (enabled) {
          expect(
            winner['bodyPrefetchedBytes'] as int,
            greaterThanOrEqualTo(8192),
          );
        } else {
          expect(winner['bodyPrefetchedBytes'], 0);
          releasePrimary.complete();
        }
        final response = await pending;
        expect(response.headers.value('content-range'), 'bytes 0-65535/900000');
        final delivered = await response.fold<List<int>>(
          [],
          (a, b) => a..addAll(b),
        );
        expect(delivered, bytes.sublist(0, 65536));
        if (enabled) {
          expect(releasePrimary.isCompleted, false);
          expect(
            events.any(
              (e) =>
                  e['event'] == 'audio.prefetch.initialBody.ready' &&
                  e['backup'] == true &&
                  e['ready'] == true,
            ),
            true,
          );
        }
      } finally {
        source.close();
        if (!releasePrimary.isCompleted) releasePrimary.complete();
        consumer.close(force: true);
        await primary.close(force: true);
        await backup.close(force: true);
      }
    });
  }

  test(
    'closing both incomplete initial bodies releases the pending consumer',
    () async {
      final bytes = resumeIndexFixture();
      final release = Completer<void>();
      final bothSent = Completer<void>();
      var sent = 0;
      final primary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final backup = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final consumer = HttpClient();
      final source = ParallelAudioSource(
        headers: {},
        boundedResumeInit: true,
        initialBodyHedge: true,
        resumePosition: const Duration(seconds: 10),
        resumeIndexHint: ResumeIndexHint(
          prefix: bytes.sublist(0, 96),
          totalBytes: bytes.length,
        ),
      );
      Future<void> serve(HttpRequest request) async {
        final start = int.parse(
          RegExp(r'bytes=(\d+)-')
              .firstMatch(request.headers.value('range')!)![1]!,
        );
        final end = start == 0 ? 65535 : bytes.length - 1;
        request.response
          ..statusCode = 206
          ..contentLength = end - start + 1
          ..bufferOutput = false;
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/${bytes.length}',
        );
        request.response.add(bytes.sublist(start, start + 1024));
        await request.response.flush();
        if (start == 0 && ++sent == 2) bothSent.complete();
        await release.future;
        await request.response.close();
      }

      primary.listen((r) => unawaited(serve(r).catchError((Object _) {})));
      backup.listen((r) => unawaited(serve(r).catchError((Object _) {})));
      try {
        final url = await source.start(
          'http://127.0.0.1:${primary.port}/media',
          alternatives: ['http://127.0.0.1:${backup.port}/media'],
          hedgeAfter: Duration.zero,
        );
        final request = await consumer.getUrl(Uri.parse(url));
        request.headers.set('range', 'bytes=0-');
        final pending = request.close();
        final checked = expectLater(
          pending,
          throwsA(anyOf(isA<HttpException>(), isA<SocketException>())),
        );
        await bothSent.future.timeout(const Duration(seconds: 2));
        source.close();
        await checked.timeout(const Duration(seconds: 2));
      } finally {
        source.close();
        release.complete();
        consumer.close(force: true);
        await primary.close(force: true);
        await backup.close(force: true);
      }
    },
  );
}
