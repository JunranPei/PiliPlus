import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/plugin/pl_player/playback/isolated_media_sources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/resume_index_fixture.dart';

void main() {
  for (final truncateOrigin in [false, true]) {
  test('resume cancellation retains worker, truncated origin=$truncateOrigin', () async {
    final bytes = resumeIndexFixture();
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final pumps = <Future<void>>[];
    var stopping = false;
    origin.listen((request) {
      pumps.add(() async {
        final start = int.parse(
          RegExp(r'bytes=(\d+)-')
              .firstMatch(request.headers.value('range')!)![1]!,
        );
        final socket = await request.response.detachSocket(writeHeaders: false);
        sockets.add(socket);
        var closed = false;
        socket.listen(
          (_) {},
          onDone: () => closed = true,
          onError: (Object _) => closed = true,
        );
        socket.done.ignore();
        try {
          socket.write(
            'HTTP/1.1 206 Partial Content\r\n'
            'Content-Length: ${bytes.length - start}\r\n'
            'Content-Range: bytes $start-${bytes.length - 1}/${bytes.length}\r\n'
            'Connection: close\r\n\r\n',
          );
          await socket.flush();
          for (
            var offset = start;
            offset < bytes.length && !stopping && !closed;
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
            if (truncateOrigin && start > 0 && offset >= start + 16384) {
              socket.destroy();
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 4));
          }
        } catch (_) {
          // The fixture deliberately loses its client in mid-response.
        }
      }());
    });
    final events = <({String name, Map<String, Object?> data})>[];
    final initialReceived = Completer<void>();
    final resumeClosed = Completer<void>();
    final failed = Completer<void>();
    final transport = IsolatedMediaSources(
      headers: {},
      onEvent: (name, data) {
        events.add((name: name, data: data));
        if (name == 'isolated.video.firstChunk' &&
            !initialReceived.isCompleted) {
          initialReceived.complete();
        }
        if (name == 'isolated.video.resume.delivery.upstreamClosed' &&
            !resumeClosed.isCompleted) {
          resumeClosed.complete();
        }
        if (name == 'isolated.closed' &&
            data['expected'] == false &&
            !failed.isCompleted) {
          failed.complete();
        }
      },
    );
    final client = HttpClient();
    final consumers = <Socket>[];
    Future<Socket> consume(
      Uri uri,
      int offset,
      Completer<void> received,
    ) async {
      final socket = await Socket.connect(uri.host, uri.port);
      consumers.add(socket);
      var count = 0;
      socket.listen((data) {
        count += data.length;
        if (count > 16384 && !received.isCompleted) received.complete();
      }, onError: (Object _) {});
      socket.done.ignore();
      socket.write(
        'GET ${uri.path} HTTP/1.1\r\nHost: ${uri.authority}\r\n'
        'Range: bytes=$offset-\r\nConnection: close\r\n\r\n',
      );
      await socket.flush();
      return socket;
    }

    try {
      final urls = await transport.start(
        'http://127.0.0.1:${origin.port}/video',
        'http://127.0.0.1:${origin.port}/audio',
        resumePosition: const Duration(seconds: 10),
      );
      final initial = await consume(
        Uri.parse(urls.video),
        0,
        Completer<void>(),
      );
      await initialReceived.future.timeout(const Duration(seconds: 3));
      final received = Completer<void>();
      final resumed = await consume(Uri.parse(urls.video), 500032, received);
      await received.future.timeout(const Duration(seconds: 3));
      initial.destroy();
      if (!truncateOrigin) resumed.destroy();
      await Future.any([resumeClosed.future, failed.future])
          .timeout(const Duration(seconds: 3));
      // New requests are causally after cancellation of the prior body. They
      // exercise the existing worker and its independent audio server.
      for (final url in [urls.video, urls.audio]) {
        final request = await client.openUrl('HEAD', Uri.parse(url));
        final response = await request.close();
        expect(response.statusCode, 200);
        expect(response.contentLength, bytes.length);
        await response.drain<void>();
      }
      final request = await client.getUrl(Uri.parse(urls.video));
      request.followRedirects = false;
      request.headers.set('range', 'bytes=850000-850031');
      final response = await request.close();
      expect(response.statusCode, 307);
      await response.drain<void>();
      expect(events.where((e) => e.name == 'isolated.workerError'), isEmpty);
      expect(failed.isCompleted, false);
    } finally {
      for (final e in events.where((e) => e.name == 'isolated.workerError')) {
        print(e.data);
      }
      transport.close();
      stopping = true;
      for (final socket in consumers) {
        socket.destroy();
      }
      client.close(force: true);
      for (final socket in sockets) {
        socket.destroy();
      }
      await origin.close(force: true);
      await Future.wait(pumps).timeout(const Duration(seconds: 3));
    }
  });
  }
}
