import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/isolated_media_sources.dart';

void main() {
  test(
    'audio backup wins in worker without changing selected video bytes',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final backup = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final consumer = HttpClient();
      final lostAudioClosed = Completer<void>();
      Socket? stalled;
      final events = <String>[];
      final transport = IsolatedMediaSources(
        headers: {},
        onEvent: (name, _) => events.add(name),
      );
      final videoBytes = List.generate(4096, (i) => i % 211);
      final audioBytes = List.generate(2048, (i) => i % 193);
      var backupRequests = 0;
      Future<void> reply(HttpRequest request, List<int> bytes) async {
        request.response
          ..statusCode = 206
          ..contentLength = bytes.length;
        request.response.headers.set(
          'content-range',
          'bytes 0-${bytes.length - 1}/${bytes.length}',
        );
        request.response.add(bytes);
        await request.response.close();
      }

      origin.listen((request) async {
        if (request.uri.path == '/video') {
          await reply(request, videoBytes);
        } else {
          expect(request.uri.path, '/audio');
          final socket = stalled = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.listen(
            (_) {},
            onDone: () {
              if (!lostAudioClosed.isCompleted) lostAudioClosed.complete();
              socket.destroy();
            },
          );
        }
      });
      backup.listen((request) async {
        backupRequests++;
        expect(request.uri.path, '/audio');
        await reply(request, audioBytes);
      });
      try {
        final urls = await transport.start(
          'http://127.0.0.1:${origin.port}/video',
          'http://127.0.0.1:${origin.port}/audio',
          audioAlternatives: ['http://127.0.0.1:${backup.port}/audio'],
        );
        for (final pair in [
          (urls.video, videoBytes),
          (urls.audio, audioBytes),
        ]) {
          final response = await (await consumer.getUrl(Uri.parse(pair.$1)))
              .close();
          final bytes = await response.fold<List<int>>(
            [],
            (a, b) => a..addAll(b),
          );
          expect(bytes, pair.$2);
        }
        await lostAudioClosed.future.timeout(const Duration(seconds: 3));
        expect(backupRequests, 1);
        expect(events, contains('isolated.audio.selected'));
        expect(events, isNot(contains('isolated.video.hedge')));
        expect(events.where((name) => name.endsWith('.error')), isEmpty);
      } finally {
        transport.close();
        consumer.close(force: true);
        stalled?.destroy();
        await origin.close(force: true);
        await backup.close(force: true);
      }
    },
  );

  test(
    'both requests run before native consumption and preserve bytes',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final transport = IsolatedMediaSources(
        headers: {'User-Agent': 'fixture'},
      );
      final release = Completer<void>();
      final arrived = Completer<void>();
      final requests = <String>[];
      origin.listen((request) async {
        requests.add(request.uri.path);
        if (requests.length == 2) arrived.complete();
        expect(request.headers.value('range'), 'bytes=0-');
        expect(request.headers.value('user-agent'), 'fixture');
        await release.future;
        final bytes = List.generate(4096, (i) => i % 251);
        request.response
          ..statusCode = 206
          ..contentLength = bytes.length;
        request.response.headers.set('content-range', 'bytes 0-4095/4096');
        request.response.add(bytes);
        await request.response.close();
      });
      try {
        final urls = await transport.start(
          'http://127.0.0.1:${origin.port}/video',
          'http://127.0.0.1:${origin.port}/audio',
        );
        await arrived.future.timeout(const Duration(seconds: 3));
        expect(requests.toSet(), {'/video', '/audio'});
        release.complete();
        for (final url in [urls.video, urls.audio]) {
          final request = await client.getUrl(Uri.parse(url));
          final response = await request.close();
          final body = await response.fold<List<int>>(
            [],
            (a, b) => a..addAll(b),
          );
          expect(body, List.generate(4096, (i) => i % 251));
        }
      } finally {
        transport.close();
        client.close(force: true);
        await origin.close(force: true);
      }
    },
  );

  test(
    'closing during worker creation terminates readiness promptly',
    () async {
      final transport = IsolatedMediaSources(headers: {});
      final pending = transport.start(
        'http://127.0.0.1:1/video',
        'http://127.0.0.1:1/audio',
      );
      transport.close();
      await expectLater(
        pending.timeout(const Duration(seconds: 3)),
        throwsStateError,
      );
      transport.close();
    },
  );

  test(
    'source disposal closes both worker-owned upstream connections',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final transport = IsolatedMediaSources(headers: {});
      final arrived = Completer<void>();
      final disconnected = Completer<void>();
      var connections = 0;
      var closed = 0;
      origin.listen((request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.listen(
          (_) {},
          onDone: () {
            if (++closed == 2) disconnected.complete();
            socket.destroy();
          },
        );
        socket.write(
          'HTTP/1.1 206 Partial Content\r\nContent-Length: 800000\r\nContent-Range: bytes 0-799999/800000\r\n\r\n',
        );
        await socket.flush();
        if (++connections == 2) arrived.complete();
      });
      try {
        await transport.start(
          'http://127.0.0.1:${origin.port}/video',
          'http://127.0.0.1:${origin.port}/audio',
        );
        await arrived.future.timeout(const Duration(seconds: 3));
        transport.close();
        await disconnected.future.timeout(const Duration(seconds: 3));
      } finally {
        transport.close();
        await origin.close(force: true);
      }
    },
  );
}
