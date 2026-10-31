import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/parallel_audio_source.dart';

void main() {
  late HttpServer origin;
  late HttpClient consumer;
  late ParallelAudioSource source;
  late Future<void> Function(HttpRequest) handler;
  late List<String?> requests;
  final bytes = Uint8List.fromList(List.generate(800000, (i) => i % 251));

  Future<void> serve(HttpRequest request) async {
    final match = RegExp(r'bytes=(\d+)-(\d*)')
        .firstMatch(request.headers.value('range') ?? 'bytes=0-')!;
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
    handler = serve;
    origin = (await HttpServer.bind(InternetAddress.loopbackIPv4, 0))
      ..listen((request) {
        requests.add(request.headers.value('range'));
        unawaited(handler(request).catchError((Object _) {}));
      });
    consumer = HttpClient();
    source = ParallelAudioSource(headers: {'User-Agent': 'fixture'});
  });
  tearDown(() async {
    source.close();
    consumer.close(force: true);
    await origin.close(force: true);
  });
  Future<String> start() =>
      source.start('http://127.0.0.1:${origin.port}/audio');
  Future<HttpClientResponse> get(
    String url, {
    String? range,
    String method = 'GET',
    bool redirect = true,
  }) async {
    final request = await consumer.openUrl(method, Uri.parse(url));
    request.followRedirects = redirect;
    if (range != null) request.headers.set('range', range);
    return request.close();
  }

  Future<List<int>> body(HttpClientResponse response) =>
      response.fold<List<int>>([], (a, b) => a..addAll(b));

  test(
    'request starts before native consumer without downloading entire body',
    () async {
      final arrived = Completer<void>();
      final release = Completer<void>();
      handler = (request) async {
        expect(request.headers.value('user-agent'), 'fixture');
        arrived.complete();
        await release.future;
        await serve(request);
      };
      final url = await start();
      await arrived.future.timeout(const Duration(seconds: 2));
      expect(requests, ['bytes=0-']);
      expect(source.receivedBytes, 0);
      release.complete();
      expect(await body(await get(url)), bytes);
      expect(requests.length, 1);
      expect(source.deliveredBytes, bytes.length);
    },
  );

  test(
    'first chunk reaches native consumer before upstream finishes',
    () async {
      final release = Completer<void>();
      handler = (request) async {
        request.response
          ..statusCode = 206
          ..contentLength = bytes.length
          ..bufferOutput = false;
        request.response.headers.set('content-range', 'bytes 0-799999/800000');
        request.response.add(bytes.sublist(0, 1024));
        await request.response.flush();
        await release.future;
        request.response.add(bytes.sublist(1024));
        await request.response.close();
      };
      final iterator = StreamIterator(await get(await start()));
      expect(
        await iterator.moveNext().timeout(const Duration(seconds: 2)),
        true,
      );
      expect(iterator.current, bytes.sublist(0, iterator.current.length));
      release.complete();
      await iterator.cancel();
    },
  );

  test(
    'prefix reopens reuse bytes while later seeks retain range on redirect',
    () async {
      final url = await start();
      expect(
        await body(await get(url, range: 'bytes=0-63')),
        bytes.sublist(0, 64),
      );
      expect(
        await body(await get(url, range: 'bytes=16-47')),
        bytes.sublist(16, 48),
      );
      expect(requests.length, 1);
      expect(
        await body(await get(url, range: 'bytes=400000-400099')),
        bytes.sublist(400000, 400100),
      );
      expect(requests.last, 'bytes=400000-400099');
    },
  );

  test(
    'HEAD leaves stream available and unsatisfiable range reports total',
    () async {
      final url = await start();
      final head = await get(url, method: 'HEAD');
      expect(head.contentLength, bytes.length);
      expect(await body(head), isEmpty);
      final invalid = await get(url, range: 'bytes=800000-');
      expect(invalid.statusCode, 416);
      expect(invalid.headers.value('content-range'), 'bytes */800000');
      await invalid.drain<void>();
      expect(await body(await get(url)), bytes);
    },
  );

  test('full 200 response preserves exact audio bytes', () async {
    handler = (request) async {
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    };
    expect(await body(await get(await start())), bytes);
  });

  test(
    'malformed origin range falls back before delivering corrupt bytes',
    () async {
      handler = (request) async {
        request.response
          ..statusCode = 206
          ..contentLength = 3;
        request.response.headers.set('content-range', 'bytes 1-3/800000');
        request.response.add([1, 2, 3]);
        await request.response.close();
      };
      final response = await get(await start(), redirect: false);
      expect(response.statusCode, 307);
      expect(
        response.headers.value('location'),
        'http://127.0.0.1:${origin.port}/audio',
      );
      await response.drain<void>();
    },
  );

  test(
    'slow headers fall back within native timeout and remain usable later',
    () async {
      source.close();
      source = ParallelAudioSource(
        headers: {},
        headerWait: const Duration(milliseconds: 80),
      );
      final release = Completer<void>();
      handler = (request) async {
        await release.future;
        await serve(request);
      };
      final url = await start();
      final response = await get(
        url,
        redirect: false,
      ).timeout(const Duration(seconds: 2));
      expect(response.statusCode, 307);
      await response.drain<void>();
      release.complete();
      expect(await body(await get(url)), bytes);
      expect(requests.length, 1);
    },
  );

  test(
    'dispose terminates upstream body still waiting for a consumer',
    () async {
      final began = Completer<void>();
      final disconnected = Completer<void>();
      handler = (request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.listen(
          (_) {},
          onDone: () {
            disconnected.complete();
            socket.destroy();
          },
        );
        socket
          ..write(
            'HTTP/1.1 206 Partial Content\r\nContent-Length: 800000\r\nContent-Range: bytes 0-799999/800000\r\n\r\n',
          )
          ..add(bytes.sublist(0, 1024));
        await socket.flush();
        began.complete();
      };
      await start();
      await began.future;
      source.close();
      await disconnected.future.timeout(const Duration(seconds: 2));
    },
  );

  test('seek bypasses a stalled current delivery', () async {
    handler = (request) async {
      if (request.headers.value('range') != 'bytes=0-') return serve(request);
      request.response
        ..statusCode = 206
        ..contentLength = bytes.length
        ..bufferOutput = false;
      request.response.headers.set('content-range', 'bytes 0-799999/800000');
      request.response.add(bytes.sublist(0, 1024));
      await request.response.flush();
    };
    final url = await start();
    final old = StreamIterator(await get(url));
    await old.moveNext();
    final seek = await get(
      url,
      range: 'bytes=500000-500099',
    ).timeout(const Duration(seconds: 2));
    expect(await body(seek), bytes.sublist(500000, 500100));
    await old.cancel();
  });

  test('paused native consumer backpressures a large upstream body', () async {
    const total = 64 * 1024 * 1024;
    final chunk = Uint8List(16 * 1024);
    handler = (request) async {
      request.response
        ..statusCode = 206
        ..contentLength = total
        ..bufferOutput = false;
      request.response.headers.set(
        'content-range',
        'bytes 0-${total - 1}/$total',
      );
      for (var sent = 0; sent < total; sent += chunk.length) {
        request.response.add(chunk);
        await request.response.flush();
      }
      await request.response.close();
    };
    final paused = StreamIterator(await get(await start()));
    try {
      expect(await paused.moveNext().timeout(const Duration(seconds: 2)), true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(source.receivedBytes, greaterThan(0));
      expect(source.receivedBytes, lessThan(total ~/ 2));
    } finally {
      source.close();
      await paused.cancel();
    }
  });
}
