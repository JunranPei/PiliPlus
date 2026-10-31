import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/parallel_source_proxy.dart';

void main() {
  late HttpServer origin;
  late HttpClient consumer;
  late ParallelSourceProxy proxy;
  late Future<void> Function(HttpRequest) handler;
  late List<String> requests;
  final bytes = Uint8List.fromList(List.generate(800000, (i) => i % 251));

  Future<void> serve(HttpRequest request) async {
    final match = RegExp(r'bytes=(\d+)-(\d*)')
        .firstMatch(request.headers.value('range')!);
    final start = int.parse(match![1]!);
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
        requests.add('${request.uri.path} ${request.headers.value('range')}');
        unawaited(handler(request).catchError((Object _) {}));
      });
    consumer = HttpClient();
    proxy = ParallelSourceProxy(
      headers: {
        'User-Agent': 'fixture',
        'Referer': 'https://www.bilibili.com/',
      },
    );
    await proxy.start();
  });

  tearDown(() async {
    proxy.close();
    consumer.close(force: true);
    await origin.close(force: true);
  });

  String add([String name = 'video']) =>
      proxy.add('http://127.0.0.1:${origin.port}/$name', name);
  Future<HttpClientResponse> get(
    String url, {
    String? range,
    String method = 'GET',
  }) async {
    final request = await consumer.openUrl(method, Uri.parse(url));
    if (range != null) request.headers.set('range', range);
    return request.close();
  }

  Future<List<int>> body(HttpClientResponse response) =>
      response.fold<List<int>>([], (a, b) => a..addAll(b));

  test(
    'both upstream requests start before either response or mpv request',
    () async {
      final arrivals = Completer<void>();
      final release = Completer<void>();
      handler = (request) async {
        if (requests.length == 2) arrivals.complete();
        await release.future;
        await serve(request);
      };
      final video = add();
      final audio = add('audio');
      await arrivals.future.timeout(const Duration(seconds: 3));
      expect(requests, ['/video bytes=0-', '/audio bytes=0-']);
      release.complete();
      expect(await body(await get(video)), bytes);
      expect(await body(await get(audio)), bytes);
      expect(requests.length, 2);
    },
  );

  test(
    'first bytes are delivered without waiting for a full prefix or body',
    () async {
      final tail = Completer<void>();
      handler = (request) async {
        request.response
          ..statusCode = 206
          ..bufferOutput = false
          ..contentLength = bytes.length;
        request.response.headers.set(
          'content-range',
          'bytes 0-${bytes.length - 1}/${bytes.length}',
        );
        request.response.add(bytes.sublist(0, 1024));
        await request.response.flush();
        await tail.future;
        request.response.add(bytes.sublist(1024));
        await request.response.close();
      };
      final response = await get(add()).timeout(const Duration(seconds: 3));
      final iterator = StreamIterator(response);
      expect(
        await iterator.moveNext().timeout(const Duration(seconds: 3)),
        isTrue,
      );
      expect(iterator.current, bytes.sublist(0, iterator.current.length));
      expect(iterator.current.length, lessThanOrEqualTo(1024));
      tail.complete();
      await iterator.cancel();
    },
  );

  test(
    'initial probe is retained across reopen, with exact ranged bytes',
    () async {
      final url = add();
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
      expect(requests.last, '/video bytes=400000-400099');
    },
  );

  test(
    'HEAD, suffix and unsatisfiable ranges preserve HTTP semantics',
    () async {
      final url = add();
      final head = await get(url, method: 'HEAD');
      expect(head.contentLength, bytes.length);
      expect(await body(head), isEmpty);
      final suffix = await get(url, range: 'bytes=-80');
      expect(suffix.statusCode, 206);
      expect(await body(suffix), bytes.sublist(bytes.length - 80));
      final invalid = await get(url, range: 'bytes=800000-');
      expect(invalid.statusCode, 416);
      expect(invalid.headers.value('content-range'), 'bytes */800000');
      await invalid.drain<void>();
    },
  );

  test(
    'complete 200 response at offset zero can be streamed unchanged',
    () async {
      handler = (request) async {
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      };
      expect(await body(await get(add())), bytes);
    },
  );

  test('invalid upstream range redirects before media delivery', () async {
    handler = (request) async {
      request.response
        ..statusCode = 206
        ..contentLength = 3;
      request.response.headers.set('content-range', 'bytes 1-3/800000');
      request.response.add([1, 2, 3]);
      await request.response.close();
    };
    final request = await consumer.getUrl(Uri.parse(add()));
    request.followRedirects = false;
    final response = await request.close();
    expect(response.statusCode, 307);
    expect(
      response.headers.value('location'),
      'http://127.0.0.1:${origin.port}/video',
    );
    await response.drain<void>();
  });

  test('slow headers fall back before the player read timeout', () async {
    proxy.close();
    proxy = ParallelSourceProxy(
      headers: {},
      headerWait: const Duration(milliseconds: 100),
    );
    await proxy.start();
    final release = Completer<void>();
    handler = (request) async {
      await release.future;
      await serve(request);
    };
    final url = add();
    final request = await consumer.getUrl(Uri.parse(url));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 2));
    expect(response.statusCode, 307);
    await response.drain<void>();
    release.complete();
    // The same prefetched request remains available if mpv reopens this track.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      await body(await get(url, range: 'bytes=0-63')),
      bytes.sublist(0, 64),
    );
    expect(requests.length, 1);
  });

  test(
    'source cancellation closes connections with response bodies in flight',
    () async {
      final began = Completer<void>();
      final disconnected = Completer<void>();
      handler = (request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.listen(
          (_) {},
          onDone: () {
            if (!disconnected.isCompleted) disconnected.complete();
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
      add();
      await began.future;
      proxy.close();
      await disconnected.future.timeout(const Duration(seconds: 3));
    },
  );

  test(
    'seek replaces a stalled delivery without waiting for its body',
    () async {
      final stalled = Completer<void>();
      handler = (request) async {
        if (request.headers.value('range') != 'bytes=0-') return serve(request);
        request.response
          ..statusCode = 206
          ..bufferOutput = false
          ..contentLength = bytes.length;
        request.response.headers.set(
          'content-range',
          'bytes 0-${bytes.length - 1}/${bytes.length}',
        );
        request.response.add(bytes.sublist(0, 1024));
        await request.response.flush();
        stalled.complete();
      };
      final url = add();
      final first = await get(url);
      final old = StreamIterator(first);
      await old.moveNext();
      await stalled.future;
      final seek = await get(
        url,
        range: 'bytes=500000-500099',
      ).timeout(const Duration(seconds: 3));
      expect(await body(seek), bytes.sublist(500000, 500100));
      await old.cancel();
    },
  );
}
