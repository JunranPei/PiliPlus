import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/plugin/pl_player/playback/parallel_audio_source.dart';
import 'package:PiliPlus/plugin/pl_player/playback/resume_index_hint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/resume_index_fixture.dart';

void main() {
  late HttpServer origin;
  late HttpClient consumer;
  late ParallelAudioSource source;
  late Future<void> Function(HttpRequest) handler;
  late List<String?> requests;
  late List<String> events;
  final bytes = resumeIndexFixture();

  Future<void> serve(HttpRequest request) async {
    final match = RegExp(r'^bytes=(\d+)-(\d*)$')
        .firstMatch(request.headers.value('range')!)!;
    final start = int.parse(match[1]!);
    final end = match[2]!.isEmpty ? bytes.length - 1 : int.parse(match[2]!);
    request.response
      ..statusCode = 206
      ..contentLength = end - start + 1;
    request.response.headers.set(
      'content-range',
      'bytes $start-$end/${bytes.length}',
    );
    request.response.add(bytes.sublist(start, end + 1));
    await request.response.close();
  }

  setUp(() async {
    requests = [];
    events = [];
    handler = serve;
    origin = (await HttpServer.bind(InternetAddress.loopbackIPv4, 0))
      ..listen((request) {
        requests.add(request.headers.value('range'));
        unawaited(handler(request).catchError((Object _) {}));
      });
    consumer = HttpClient();
    source = ParallelAudioSource(
      headers: {'User-Agent': 'fixture'},
      resumePosition: const Duration(seconds: 10),
      onEvent: (name, _) => events.add(name),
    );
  });
  tearDown(() async {
    source.close();
    consumer.close(force: true);
    await origin.close(force: true);
  });
  Future<HttpClientResponse> get(
    String url,
    String range, {
    bool redirects = true,
  }) async {
    final request = await consumer.getUrl(Uri.parse(url));
    request.followRedirects = redirects;
    request.headers.set('range', range);
    return request.close();
  }

  Future<List<int>> body(HttpClientResponse response) =>
      response.fold<List<int>>([], (a, b) => a..addAll(b));
  Future<String> prepare() async {
    final url = await source.start('http://127.0.0.1:${origin.port}/media');
    expect(
      await body(await get(url, 'bytes=0-65535')),
      bytes.sublist(0, 65536),
    );
    return url;
  }

  test(
    'index hint starts the target request before fresh initialization headers',
    () async {
      source.close();
      final releaseInit = Completer<void>();
      final targetBegan = Completer<void>();
      source = ParallelAudioSource(
        headers: {},
        resumePosition: const Duration(seconds: 10),
        resumeIndexHint: ResumeIndexHint(
          prefix: bytes.sublist(0, 65536),
          totalBytes: bytes.length,
        ),
        onEvent: (name, _) => events.add(name),
      );
      handler = (request) async {
        if (request.headers.value('range') == 'bytes=0-') {
          await releaseInit.future;
        } else if (request.headers.value('range') == 'bytes=500000-') {
          targetBegan.complete();
        }
        await serve(request);
      };
      final url = await source.start('http://127.0.0.1:${origin.port}/media');
      try {
        await targetBegan.future.timeout(const Duration(seconds: 2));
        expect(events, contains('audio.prefetch.resume.indexHint'));
      } finally {
        releaseInit.complete();
      }
      expect(
        await body(await get(url, 'bytes=0-65535')),
        bytes.sublist(0, 65536),
      );
      expect(
        await body(await get(url, 'bytes=500032-500131')),
        bytes.sublist(500032, 500132),
      );
    },
  );

  test('stale hinted length falls back to the current native range without wrong bytes', () async {
    source.close();
    source = ParallelAudioSource(
      headers: {},
      resumePosition: const Duration(seconds: 10),
      resumeBodyWarmup: true,
      resumeIndexHint: ResumeIndexHint(
        prefix: bytes.sublist(0, 65536),
        totalBytes: bytes.length + 1000,
      ),
    );
    final response = await get(
      await prepare(),
      'bytes=500032-500131',
      redirects: false,
    );
    expect(response.statusCode, 307);
    expect(await body(response), isEmpty);
    final fresh = await get(
      'http://127.0.0.1:${origin.port}/media',
      'bytes=500032-500131',
    );
    expect(await body(fresh), bytes.sublist(500032, 500132));
  });

  test('target request starts during initialization and exact bytes survive a skipped prefix', () async {
    final began = Completer<void>();
    handler = (request) async {
      if (request.headers.value('range') == 'bytes=500000-') began.complete();
      await serve(request);
    };
    final url = await prepare();
    await began.future.timeout(const Duration(seconds: 2));
    expect(events, isNot(contains('audio.prefetch.resume.firstChunk')));
    expect(
      await body(await get(url, 'bytes=500032-500131')),
      bytes.sublist(500032, 500132),
    );
    expect(
      await body(await get(url, 'bytes=500040-500060')),
      bytes.sublist(500040, 500061),
    );
    expect(requests, ['bytes=0-', 'bytes=500000-']);
    expect(events, contains('audio.prefetch.resume.claim'));
    // An unrelated later seek must retain the caller's original Range.
    expect(
      await body(await get(url, 'bytes=850000-850099')),
      bytes.sublist(850000, 850100),
    );
    expect(requests.last, 'bytes=850000-850099');
  });
  test(
    'open-ended resume streams the exact remainder without truncation',
    () async {
      final url = await prepare();
      final response = await get(url, 'bytes=500000-');
      expect(
        response.headers.value('content-range'),
        'bytes 500000-899999/900000',
      );
      expect(response.contentLength, 400000);
      expect(await body(response), bytes.sublist(500000));
      expect(requests, ['bytes=0-', 'bytes=500000-']);
    },
  );
  test(
    'body prefill occurs before native claim and exact range is preserved',
    () async {
      source.close();
      final warmed = Completer<void>();
      source = ParallelAudioSource(
        headers: {},
        resumePosition: const Duration(seconds: 10),
        resumeBodyWarmup: true,
        onEvent: (name, _) {
          events.add(name);
          if (name == 'audio.prefetch.resume.bodyWarmup.paused' &&
              !warmed.isCompleted) {
            warmed.complete();
          }
        },
      );
      final url = await prepare();
      await warmed.future.timeout(const Duration(seconds: 2));
      expect(events, isNot(contains('audio.prefetch.resume.firstChunk')));
      final response = await get(url, 'bytes=500032-');
      expect(
        response.headers.value('content-range'),
        'bytes 500032-899999/900000',
      );
      expect(await body(response), bytes.sublist(500032));
      expect(requests, ['bytes=0-', 'bytes=500000-']);
      expect(events, contains('audio.prefetch.resume.bodyWarmup.claim'));
    },
  );
  for (final (segmentBytes, expectedLimit) in [
    (100000, 256 * 1024),
    (600000, 600000),
    (2000000, 1024 * 1024),
  ]) {
    test(
      'segment body warmup bounds $segmentBytes bytes and preserves a skipped range',
      () async {
        source.close();
        final media = Uint8List(3000000)..setRange(0, bytes.length, bytes);
        // The second five-second segment begins at byte 500000. Enlarge only
        // its sidx entry; the caller still requests the same exact byte range.
        ByteData.sublistView(media).setUint32(60, segmentBytes);
        final warmed = Completer<Map<String, Object?>>();
        final planned = Completer<Map<String, Object?>>();
        handler = (request) async {
          final start = int.parse(
            RegExp(r'^bytes=(\d+)-')
                .firstMatch(request.headers.value('range')!)![1]!,
          );
          request.response
            ..statusCode = 206
            ..contentLength = media.length - start
            ..headers.set(
              'content-range',
              'bytes $start-${media.length - 1}/${media.length}',
            );
          request.response.add(media.sublist(start));
          await request.response.close();
        };
        source = ParallelAudioSource(
          headers: {},
          resumePosition: const Duration(seconds: 10),
          resumeBodyWarmup: true,
          resumeSegmentBodyWarmup: true,
          onEvent: (name, data) {
            if (name == 'audio.prefetch.resume.plan' && !planned.isCompleted) {
              planned.complete(data);
            }
            if (name == 'audio.prefetch.resume.bodyWarmup.paused' &&
                !warmed.isCompleted) {
              warmed.complete(data);
            }
          },
        );
        final url = await source.start('http://127.0.0.1:${origin.port}/media');
        expect(await body(await get(url, 'bytes=0-65535')), media.sublist(0, 65536));
        final pause = await warmed.future.timeout(const Duration(seconds: 2));
        expect((await planned.future)['bodyWarmupLimit'], expectedLimit);
        expect(pause['limit'], expectedLimit);
        expect(
          pause['prefetchedBytes'] as int,
          greaterThanOrEqualTo(expectedLimit),
        );
        expect(
          pause['prefetchedBytes'] as int,
          lessThan(expectedLimit + (pause['lastChunkBytes'] as int)),
        );
        final response = await get(url, 'bytes=500032-500131');
        expect(
          response.headers.value('content-range'),
          'bytes 500032-500131/3000000',
        );
        expect(await body(response), media.sublist(500032, 500132));
        expect(requests, ['bytes=0-', 'bytes=500000-']);
      },
    );
  }

  test(
    'wrong predicted response range is rejected before any media bytes',
    () async {
      handler = (request) async {
        if (request.headers.value('range') != 'bytes=500000-') {
          return serve(request);
        }
        request.response
          ..statusCode = 206
          ..contentLength = 3;
        request.response.headers.set(
          'content-range',
          'bytes 500001-500003/900000',
        );
        request.response.add([1, 2, 3]);
        await request.response.close();
      };
      final response = await get(
        await prepare(),
        'bytes=500000-',
        redirects: false,
      );
      expect(response.statusCode, 307);
      expect(await body(response), isEmpty);
    },
  );
  test(
    'stalled speculative headers fall back within the normal header budget',
    () async {
      source.close();
      source = ParallelAudioSource(
        headers: {},
        resumePosition: const Duration(seconds: 10),
        headerWait: const Duration(milliseconds: 80),
      );
      final release = Completer<void>();
      handler = (request) async {
        if (request.headers.value('range') == 'bytes=500000-') {
          await release.future;
        }
        await serve(request);
      };
      try {
        final response = await get(
          await prepare(),
          'bytes=500000-',
          redirects: false,
        ).timeout(const Duration(seconds: 2));
        expect(response.statusCode, 307);
        expect(await body(response), isEmpty);
      } finally {
        release.complete();
      }
    },
  );
  test(
    'closing before a native claim closes the speculative connection',
    () async {
      final began = Completer<void>();
      final disconnected = Completer<void>();
      handler = (request) async {
        if (request.headers.value('range') != 'bytes=500000-') {
          return serve(request);
        }
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.listen(
          (_) {},
          onDone: () {
            disconnected.complete();
            socket.destroy();
          },
        );
        socket.write(
          'HTTP/1.1 206 Partial Content\r\nContent-Length: 400000\r\nContent-Range: bytes 500000-899999/900000\r\n\r\n',
        );
        await socket.flush();
        began.complete();
      };
      await prepare();
      await began.future.timeout(const Duration(seconds: 2));
      source.close();
      await disconnected.future.timeout(const Duration(seconds: 2));
      expect(events, contains('audio.prefetch.resume.closed'));
      expect(events, isNot(contains('audio.prefetch.resume.firstChunk')));
    },
  );

  test(
    'audio can wait for a master target after its prefix was consumed',
    () async {
      source.close();
      source = ParallelAudioSource(
        headers: {'User-Agent': 'fixture'},
        resumePosition: const Duration(seconds: 14),
        waitForResumeAlignment: true,
      );
      final url = await prepare();
      expect(requests, ['bytes=0-']);
      source.alignResumeTo(const Duration(seconds: 10));
      expect(
        await body(await get(url, 'bytes=500032-500131')),
        bytes.sublist(500032, 500132),
      );
      expect(requests, ['bytes=0-', 'bytes=500000-']);
      source.alignResumeTo(const Duration(seconds: 15));
      expect(
        await body(await get(url, 'bytes=500040-500060')),
        bytes.sublist(500040, 500061),
      );
      expect(requests, ['bytes=0-', 'bytes=500000-']);
    },
  );

  test('alignment arriving before a prefix preserves the original requested position', () async {
    source.close();
    Duration? plannedStart;
    Map<String, Object?>? plan;
    source = ParallelAudioSource(
      headers: {'User-Agent': 'fixture'},
      resumePosition: const Duration(seconds: 14),
      waitForResumeAlignment: true,
      onResumeSegment: (position) => plannedStart = position,
      onEvent: (name, data) {
        if (name == 'audio.prefetch.resume.plan') plan = data;
      },
    )..alignResumeTo(const Duration(seconds: 10));
    final url = await prepare();
    expect(
      await body(await get(url, 'bytes=500000-500031')),
      bytes.sublist(500000, 500032),
    );
    expect(plannedStart, const Duration(seconds: 5));
    expect(plan!['requestedUs'], 14000000);
    expect(plan!['predictionTargetUs'], 10000000);
    expect(requests, ['bytes=0-', 'bytes=500000-']);
  });

  test(
    'missing master alignment falls back without opening an extra response',
    () async {
      source.close();
      source = ParallelAudioSource(
        headers: {'User-Agent': 'fixture'},
        resumePosition: const Duration(seconds: 14),
        waitForResumeAlignment: true,
      );
      final response = await get(
        await prepare(),
        'bytes=500000-500031',
        redirects: false,
      ).timeout(const Duration(seconds: 2));
      expect(response.statusCode, 307);
      expect(await body(response), isEmpty);
      expect(requests, ['bytes=0-']);
      source
        ..close()
        ..alignResumeTo(const Duration(seconds: 10));
      expect(requests, ['bytes=0-']);
    },
  );
}
