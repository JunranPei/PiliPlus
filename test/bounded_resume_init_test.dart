import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/parallel_audio_source.dart';
import 'package:PiliPlus/plugin/pl_player/playback/resume_index_hint.dart';

import 'fixtures/resume_index_fixture.dart';

void main() {
  late HttpServer origin;
  late HttpClient consumer;
  late ParallelAudioSource source;
  late Uint8List bytes;
  late List<String> requests;
  late Future<void> Function(HttpRequest) handler;

  Future<void> serve(HttpRequest request, {bool ignoreRange = false}) async {
    final match = RegExp(r'^bytes=(\d+)-(\d*)$')
        .firstMatch(request.headers.value('range') ?? 'bytes=0-')!;
    final start = ignoreRange ? 0 : int.parse(match[1]!);
    final end = ignoreRange || match[2]!.isEmpty
        ? bytes.length - 1
        : math.min(int.parse(match[2]!), bytes.length - 1);
    request.response
      ..statusCode = ignoreRange ? 200 : 206
      ..contentLength = end - start + 1;
    if (!ignoreRange) {
      request.response.headers.set(
        'content-range',
        'bytes $start-$end/${bytes.length}',
      );
    }
    request.response.add(bytes.sublist(start, end + 1));
    await request.response.close();
  }

  setUp(() async {
    bytes = resumeIndexFixture();
    requests = [];
    handler = serve;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) {
      requests.add(request.headers.value('range') ?? 'none');
      unawaited(handler(request).catchError((Object _) {}));
    });
    consumer = HttpClient();
    source = ParallelAudioSource(headers: {});
  });
  tearDown(() async {
    source.close();
    consumer.close(force: true);
    await origin.close(force: true);
  });

  Future<String> start({
    bool enabled = true,
    bool hint = true,
    int seconds = 10,
    bool cancelClosedDelivery = true,
  }) async {
    source.close();
    source = ParallelAudioSource(
      headers: {'User-Agent': 'current-headers'},
      boundedResumeInit: enabled,
      cancelClosedDelivery: cancelClosedDelivery,
      resumePosition: Duration(seconds: seconds),
      resumeIndexHint: hint
          ? ResumeIndexHint(
              prefix: resumeIndexFixture().sublist(0, 65536),
              totalBytes: bytes.length,
            )
          : null,
    );
    return source.start('http://127.0.0.1:${origin.port}/media');
  }

  Future<HttpClientResponse> get(
    String url, {
    String? range = 'bytes=0-',
    String method = 'GET',
  }) async {
    final request = await consumer.openUrl(method, Uri.parse(url));
    request.followRedirects = false;
    if (range != null) request.headers.set('range', range);
    return request.close();
  }

  Future<List<int>> body(HttpClientResponse response) =>
      response.fold<List<int>>([], (a, b) => a..addAll(b));

  for (final cancelClosedDelivery in [false, true]) {
    test(
      'fresh bounded init then cached prefix, target and further range ($cancelClosedDelivery)',
      () async {
        // Valid old metadata may differ: the hint must never supply decoder bytes.
        bytes[8] ^= 0x7f;
        final url = await start(cancelClosedDelivery: cancelClosedDelivery);
        final first = await get(url);
        expect(first.statusCode, 206);
        expect(first.contentLength, 65536);
        expect(first.headers.value('content-range'), 'bytes 0-65535/900000');
        expect(await body(first), bytes.sublist(0, 65536));
        expect(
          await body(await get(url, range: 'bytes=0-95')),
          bytes.sublist(0, 96),
        );
        expect(
          await body(await get(url, range: 'bytes=500032-500131')),
          bytes.sublist(500032, 500132),
        );
        expect(requests, ['bytes=0-65535', 'bytes=500000-']);
        final more = await get(url, range: 'bytes=65536-');
        expect(more.statusCode, 307);
        expect(
          more.headers.value('location'),
          'http://127.0.0.1:${origin.port}/media',
        );
        await more.drain<void>();
      },
    );
  }

  for (final mode in ['disabled', 'no-hint', 'first-play']) {
    test('$mode preserves unbounded initial request', () async {
      final url = await start(
        enabled: mode != 'disabled',
        hint: mode != 'no-hint',
        seconds: mode == 'first-play' ? 0 : 10,
      );
      final response = await get(url, range: 'bytes=0-31');
      expect(await body(response), bytes.sublist(0, 32));
      expect(requests.first, 'bytes=0-');
    });
  }

  test(
    'origin ignoring bounded Range retains full resource behavior',
    () async {
      handler = (request) => serve(request, ignoreRange: true);
      final response = await get(await start());
      expect(response.contentLength, bytes.length);
      expect(await body(response), bytes);
    },
  );

  test(
    'HEAD exposes complete size; range-free GET redirects without truncation',
    () async {
      final url = await start();
      final head = await get(url, range: null, method: 'HEAD');
      expect(head.contentLength, bytes.length);
      expect(await body(head), isEmpty);
      final whole = await get(url, range: null);
      expect(whole.statusCode, 307);
      expect(await body(whole), isEmpty);
    },
  );

  test(
    'unexpected partial range falls back instead of promising wrong bytes',
    () async {
      handler = (request) async {
        request.response
          ..statusCode = 206
          ..contentLength = 100;
        request.response.headers.set('content-range', 'bytes 0-99/900000');
        request.response.add(bytes.sublist(0, 100));
        await request.response.close();
      };
      final response = await get(await start());
      expect(response.statusCode, 307);
      expect(await body(response), isEmpty);
    },
  );
}
