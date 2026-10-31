import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/plugin/pl_player/playback/parallel_audio_source.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/resume_index_fixture.dart';

void main() {
  test('closed initial consumer releases only its upstream; resume and seeks survive', () async {
    final bytes = resumeIndexFixture();
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final initialClosed = Completer<void>();
    final targetOpened = Completer<void>();
    final targetClosed = Completer<void>();
    final releaseTarget = Completer<void>();
    final sockets = <Socket>[];
    final pumps = <Future<void>>[];
    var stopping = false;
    origin.listen((request) {
      pumps.add(() async {
        final range = request.headers.value('range')!;
        final start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
        final socket = await request.response.detachSocket(writeHeaders: false);
        sockets.add(socket);
        final closed = start == 0 ? initialClosed : targetClosed;
        socket.listen(
          (_) {},
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
          onError: (Object _) {
            if (!closed.isCompleted) closed.complete();
          },
        );
        try {
          socket.write(
            'HTTP/1.1 206 Partial Content\r\n'
            'Content-Length: ${bytes.length - start}\r\n'
            'Content-Range: bytes $start-${bytes.length - 1}/${bytes.length}\r\n'
            'Connection: close\r\n\r\n',
          );
          await socket.flush();
          if (start != 0) {
            if (!targetOpened.isCompleted) targetOpened.complete();
            await releaseTarget.future;
          }
          for (
            var offset = start;
            offset < bytes.length && !stopping && !closed.isCompleted;
            offset += 8192
          ) {
            socket.add(
              Uint8List.sublistView(
                bytes,
                offset,
                math.min(offset + 8192, bytes.length),
              ),
            );
            await socket.flush();
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        } catch (_) {
          // Cancellation is observed independently on the socket read side.
        }
      }());
    });
    final initialReceived = Completer<void>();
    final source = ParallelAudioSource(
      headers: {},
      cancelClosedDelivery: true,
      resumePosition: const Duration(seconds: 10),
      resumePresentationTime: false,
      resumeBodyWarmup: true,
      onEvent: (name, _) {
        if (name == 'audio.prefetch.firstChunk' &&
            !initialReceived.isCompleted) {
          initialReceived.complete();
        }
      },
    );
    final consumer = HttpClient();
    Socket? initial;
    final original = 'http://127.0.0.1:${origin.port}/media';
    try {
      final uri = Uri.parse(await source.start(original));
      initial = (await Socket.connect(uri.host, uri.port))
        ..listen((_) {}, onError: (Object _) {})
        ..write(
          'GET ${uri.path} HTTP/1.1\r\nHost: ${uri.authority}\r\n'
          'Range: bytes=0-\r\nConnection: close\r\n\r\n',
        );
      await initial.flush();
      await initialReceived.future.timeout(const Duration(seconds: 2));
      await targetOpened.future.timeout(const Duration(seconds: 2));
      initial.destroy();
      await initialClosed.future.timeout(const Duration(seconds: 2));
      final afterClose = source.receivedBytes;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(source.receivedBytes, afterClose);
      expect(targetClosed.isCompleted, false);

      Future<HttpClientResponse> get(String method, String? range) async {
        final request = await consumer.openUrl(method, uri);
        request.followRedirects = false;
        if (range != null) request.headers.set('range', range);
        return request.close();
      }

      Future<List<int>> body(HttpClientResponse response) =>
          response.fold<List<int>>([], (out, chunk) => out..addAll(chunk));

      final head = await get('HEAD', null);
      expect(head.statusCode, 200);
      expect(head.contentLength, bytes.length);
      expect(await body(head), isEmpty);
      expect(await body(await get('GET', 'bytes=0-31')), bytes.sublist(0, 32));

      releaseTarget.complete();
      final target = await get('GET', 'bytes=500032-500095');
      expect(target.statusCode, 206);
      expect(await body(target), bytes.sublist(500032, 500096));
      await targetClosed.future.timeout(const Duration(seconds: 2));

      final uncached = await get('GET', 'bytes=850000-850031');
      expect(uncached.statusCode, 307);
      expect(uncached.headers.value('location'), original);
      expect(await body(uncached), isEmpty);
    } finally {
      stopping = true;
      if (!releaseTarget.isCompleted) releaseTarget.complete();
      initial?.destroy();
      source.close();
      consumer.close(force: true);
      for (final socket in sockets) {
        socket.destroy();
      }
      await origin.close(force: true);
      await Future.wait(pumps).timeout(const Duration(seconds: 3));
    }
  });
}
