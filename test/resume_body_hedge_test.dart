import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/parallel_audio_source.dart';
import 'package:PiliPlus/plugin/pl_player/playback/resume_index_hint.dart';

import 'fixtures/resume_index_fixture.dart';

void main() {
  for (final (enabled, cancel, alignEarly) in const [
    (false, false, false),
    (true, false, false),
    (true, true, false),
    (true, false, true),
  ]) {
    test(
      'target body stalls after 113KB: hedge=$enabled cancel=$cancel alignmentDuringBind=$alignEarly',
      () async {
        final bytes = resumeIndexFixture();
        final primaryHeaders = Completer<void>();
        final release = Completer<void>();
        final bothStalled = Completer<void>();
        final selected = Completer<Map<String, Object?>>();
        var stalled = 0;
        final primary = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final backup = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final consumer = HttpClient();
        final events = <Map<String, Object?>>[];
        final source = ParallelAudioSource(
          headers: {},
          boundedResumeInit: true,
          resumeBodyHedge: enabled,
          waitForResumeAlignment: alignEarly,
          resumeBodyWarmup: true,
          hedgeResumePrefetch: true,
          cancelClosedDelivery: true,
          resumePosition: const Duration(seconds: 10),
          resumeIndexHint: ResumeIndexHint(
            prefix: bytes.sublist(0, 96),
            totalBytes: bytes.length,
          ),
          onEvent: (name, data) {
            events.add({'event': name, ...data});
            if (name == 'audio.prefetch.resume.selected' &&
                !selected.isCompleted) {
              selected.complete(data);
            }
          },
        );
        Future<void> serve(HttpRequest request, bool slow) async {
          final match = RegExp(r'bytes=(\d+)-(\d*)')
              .firstMatch(request.headers.value('range')!)!;
          final start = int.parse(match[1]!);
          final end = match[2]!.isEmpty
              ? bytes.length - 1
              : int.parse(match[2]!);
          if (!slow && start > 0) {
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
          if (start > 0 && (slow || cancel)) {
            request.response.add(bytes.sublist(start, start + 113000));
            await request.response.flush();
            if (slow) primaryHeaders.complete();
            if (++stalled == 2) bothStalled.complete();
            await release.future;
            request.response.add(bytes.sublist(start + 113000, end + 1));
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
          final starting = source.start(
            'http://127.0.0.1:${primary.port}/media',
            alternatives: ['http://127.0.0.1:${backup.port}/media'],
            hedgeAfter: Duration.zero,
          );
          if (alignEarly) source.alignResumeTo(const Duration(seconds: 10));
          final url = await starting;
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
          final pending = request.close();
          if (cancel) {
            final checked = expectLater(
              pending,
              throwsA(anyOf(isA<HttpException>(), isA<SocketException>())),
            );
            await bothStalled.future.timeout(const Duration(seconds: 2));
            source.close();
            await checked.timeout(const Duration(seconds: 2));
            expect(selected.isCompleted, false);
          } else {
            final winner = await selected.future.timeout(
              const Duration(seconds: 2),
            );
            expect(winner['backup'], enabled);
            expect(release.isCompleted, false);
            if (enabled) {
              expect(
                winner['bodyPrefetchedBytes'] as int,
                greaterThanOrEqualTo(256 * 1024),
              );
            } else {
              expect(winner['bodyPrefetchedBytes'], 0);
              release.complete();
            }
            final response = await pending;
            expect(
              response.headers.value('content-range'),
              'bytes 500000-899999/900000',
            );
            expect(
              await response.fold<List<int>>([], (a, b) => a..addAll(b)),
              bytes.sublist(500000),
            );
            if (enabled) {
              expect(release.isCompleted, false);
              expect(
                events.where(
                  (e) => e['event'] == 'audio.prefetch.resume.bodyWarmup.claim',
                ),
                hasLength(1),
              );
            }
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
