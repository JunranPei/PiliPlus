import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/resume_body_recovery.dart';

void main() {
  final bytes = Uint8List.fromList(
    List.generate(800000, (i) => ((i * 17) ^ (i >> 9)) & 255),
  );
  const offset = 300000;
  const prefix = 113000;
  late HttpServer origin;
  late StreamController<List<int>> primary;
  late ResumeBodyRecovery recovery;
  late Future<void> Function(HttpRequest) handler;
  late List<String?> requests;
  late List<Map<String, Object?>> events;
  late Completer<void> requested;
  late Completer<void> rejected;
  var primaryClosed = false;

  Future<void> serve(HttpRequest request) async {
    final start = int.parse(
      request.headers
          .value('range')!
          .substring('bytes='.length)
          .split('-')
          .first,
    );
    request.response
      ..statusCode = 206
      ..contentLength = bytes.length - start
      ..headers.set('content-range', 'bytes $start-799999/800000');
    request.response.add(bytes.sublist(start));
    await request.response.close();
  }

  setUp(() async {
    requests = [];
    events = [];
    requested = Completer<void>();
    rejected = Completer<void>();
    primaryClosed = false;
    primary = StreamController<List<int>>();
    handler = serve;
    origin = (await HttpServer.bind(InternetAddress.loopbackIPv4, 0))
      ..listen((request) {
        requests.add(request.headers.value('range'));
        if (!requested.isCompleted) requested.complete();
        handler(request).catchError((Object _) {});
      });
    recovery = ResumeBodyRecovery(
      source: primary.stream,
      alternate: Uri.parse('http://127.0.0.1:${origin.port}/video'),
      headers: {'User-Agent': 'fixture'},
      offset: offset,
      total: bytes.length,
      stallAfter: const Duration(milliseconds: 50),
      retryTimeout: const Duration(milliseconds: 300),
      closePrimary: () => primaryClosed = true,
      onEvent: (name, data) {
        events.add({'event': name, ...data});
        if (name == 'rejected' && !rejected.isCompleted) rejected.complete();
      },
    );
  });
  tearDown(() async {
    await recovery.close();
    primary.close().ignore();
    await origin.close(force: true);
  });

  Future<List<int>> collect() =>
      recovery.stream.fold<List<int>>([], (a, b) => a..addAll(b));
  void firstBytes() => primary.add(bytes.sublist(offset, offset + prefix));
  void remaining() {
    primary.add(bytes.sublist(offset + prefix));
    primary.close().ignore();
  }

  test(
    '113KB then stall: immediate first bytes and exact validated continuation',
    () async {
      final first = Completer<void>();
      final result = recovery.stream
          .map((chunk) {
            if (!first.isCompleted) first.complete();
            return chunk;
          })
          .fold<List<int>>([], (a, b) => a..addAll(b));
      firstBytes();
      await first.future;
      expect(
        requests,
        isEmpty,
      ); // No up-front buffer fill or alternate request.
      expect(await result, bytes.sublist(offset));
      expect(requests, ['bytes=${offset + prefix - 65536}-']);
      expect(primaryClosed, isTrue);
      expect(
        events.singleWhere((e) => e['event'] == 'switched')['matchedBytes'],
        65536,
      );
    },
  );

  test(
    'healthy source does not request alternate or delay completion',
    () async {
      final result = collect();
      firstBytes();
      remaining();
      expect(await result, bytes.sublist(offset));
      expect(requests, isEmpty);
      expect(primaryClosed, isFalse);
    },
  );

  for (final defect in ['status200', 'range', 'total', 'encoding', 'overlap']) {
    test('rejects $defect without corrupting original stream', () async {
      handler = (request) async {
        const start = offset + prefix - 65536;
        request.response
          ..statusCode = defect == 'status200' ? 200 : 206
          ..contentLength = bytes.length - start
          ..headers.set(
            'content-range',
            'bytes ${defect == 'range' ? start + 1 : start}-799999/${defect == 'total' ? 800001 : 800000}',
          );
        if (defect == 'encoding') {
          request.response.headers.set('content-encoding', 'gzip');
        }
        final payload = bytes.sublist(start);
        if (defect == 'overlap') payload[40000] ^= 1;
        request.response.add(payload);
        await request.response.close();
      };
      final result = collect();
      firstBytes();
      await rejected.future;
      remaining();
      expect(await result, bytes.sublist(offset));
      expect(primaryClosed, isFalse);
      expect(events.where((e) => e['event'] == 'switched'), isEmpty);
    });
  }

  test(
    'primary resumes during retry: discard late alternate without duplicates',
    () async {
      final release = Completer<void>();
      handler = (request) async {
        await release.future;
        await serve(request);
      };
      final result = collect();
      firstBytes();
      await requested.future;
      remaining();
      expect(await result, bytes.sublist(offset));
      release.complete();
      expect(events.any((e) => e['reason'] == 'primary-resumed'), isTrue);
      expect(primaryClosed, isFalse);
    },
  );

  test('consumer backpressure never starts the stall timer', () async {
    final first = Completer<void>();
    final done = Completer<void>();
    final chunks = <int>[];
    late StreamSubscription<List<int>> sub;
    sub = recovery.stream.listen((chunk) {
      chunks.addAll(chunk);
      if (!first.isCompleted) {
        sub.pause();
        first.complete();
      }
    }, onDone: done.complete);
    firstBytes();
    await first.future;
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(requests, isEmpty);
    sub.resume();
    await done.future;
    await sub.cancel();
    expect(chunks, bytes.sublist(offset));
    expect(requests.length, 1);
  });

  test(
    'cancel while alternate headers pending closes without late switch',
    () async {
      final release = Completer<void>();
      handler = (request) async {
        await release.future;
        await serve(request);
      };
      final sub = recovery.stream.listen((_) {});
      firstBytes();
      await requested.future;
      await sub.cancel().timeout(const Duration(seconds: 1));
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(events.where((e) => e['event'] == 'switched'), isEmpty);
      expect(primaryClosed, isFalse);
    },
  );

  test(
    'alternate stalls during overlap: deadline releases it, primary survives',
    () async {
      final release = Completer<void>();
      handler = (request) async {
        const start = offset + prefix - 65536;
        request.response
          ..statusCode = 206
          ..contentLength = bytes.length - start
          ..bufferOutput = false
          ..headers.set('content-range', 'bytes $start-799999/800000');
        request.response.add(bytes.sublist(start, start + 100));
        await request.response.flush();
        await release.future;
        request.response.add(bytes.sublist(start + 100));
        await request.response.close();
      };
      final result = collect();
      firstBytes();
      await rejected.future;
      remaining();
      expect(await result, bytes.sublist(offset));
      release.complete();
      expect(events.any((e) => e['reason'] == 'timeout'), isTrue);
    },
  );

  test(
    'early close without listener does not wait for a future consumer',
    () async {
      await recovery.close().timeout(const Duration(seconds: 1));
      expect(await collect(), isEmpty);
      expect(requests, isEmpty);
    },
  );

  test(
    'truncated primary remains an error rather than false completion',
    () async {
      final result = expectLater(collect(), throwsA(isA<HttpException>()));
      firstBytes();
      primary.close().ignore();
      await result;
    },
  );
}
