import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/parallel_audio_source.dart';

void main() {
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

  for (final delayMs in [40, 0]) {
    test(
      'backup at ${delayMs}ms wins and the losing upstream socket closes',
      () async {
        final primary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final backup = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final disconnected = Completer<void>();
        final bytes = List.generate(1024, (i) => i % 251);
        final events = <Map<String, Object?>>[];
        final transport = ParallelAudioSource(
          headers: {},
          onEvent: (name, data) => events.add({'event': name, ...data}),
        );
        final consumer = HttpClient();
        primary.listen((request) async {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.listen(
            (_) {},
            onDone: () {
              disconnected.complete();
              socket.destroy();
            },
          );
        });
        var backupRequests = 0;
        backup.listen((request) async {
          backupRequests++;
          expect(request.headers.value('range'), 'bytes=0-');
          await reply(request, bytes);
        });
        try {
          final local = await transport.start(
            'http://127.0.0.1:${primary.port}/video',
            alternatives: ['http://127.0.0.1:${backup.port}/video'],
            hedgeAfter: Duration(milliseconds: delayMs),
          );
          final response = await (await consumer.getUrl(Uri.parse(local)))
              .close();
          final actual = await response.fold<List<int>>(
            [],
            (a, b) => a..addAll(b),
          );
          expect(actual, bytes);
          expect(backupRequests, 1);
          expect(
            events.singleWhere(
              (e) => e['event'] == 'audio.prefetch.selected',
            )['backup'],
            true,
          );
          await disconnected.future.timeout(const Duration(seconds: 2));
          expect(
            events.where((e) => e['event'] == 'audio.prefetch.error'),
            isEmpty,
          );
        } finally {
          transport.close();
          consumer.close(force: true);
          await primary.close(force: true);
          await backup.close(force: true);
        }
      },
    );
  }

  test('fast preferred endpoint does not start a backup download', () async {
    final primary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final backup = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final transport = ParallelAudioSource(headers: {});
    final consumer = HttpClient();
    var backupRequests = 0;
    primary.listen((request) => reply(request, [1, 2, 3]));
    backup.listen((request) {
      backupRequests++;
      request.response.close();
    });
    try {
      final local = await transport.start(
        'http://127.0.0.1:${primary.port}/video',
        alternatives: ['http://127.0.0.1:${backup.port}/video'],
        hedgeAfter: const Duration(milliseconds: 120),
      );
      final response = await (await consumer.getUrl(Uri.parse(local))).close();
      expect(await response.fold<List<int>>([], (a, b) => a..addAll(b)), [
        1,
        2,
        3,
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 180));
      expect(backupRequests, 0);
    } finally {
      transport.close();
      consumer.close(force: true);
      await primary.close(force: true);
      await backup.close(force: true);
    }
  });

  test(
    'invalid primary response cannot win or postpone a valid backup',
    () async {
      final primary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final backup = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final transport = ParallelAudioSource(headers: {});
      final consumer = HttpClient();
      primary.listen((request) {
        request.response.statusCode = 403;
        request.response.close();
      });
      backup.listen((request) => reply(request, [7, 8, 9]));
      try {
        final local = await transport.start(
          'http://127.0.0.1:${primary.port}/video',
          alternatives: ['http://127.0.0.1:${backup.port}/video'],
          hedgeAfter: const Duration(seconds: 5),
        );
        final response = await (await consumer.getUrl(Uri.parse(local)))
            .close()
            .timeout(const Duration(seconds: 2));
        expect(await response.fold<List<int>>([], (a, b) => a..addAll(b)), [
          7,
          8,
          9,
        ]);
      } finally {
        transport.close();
        consumer.close(force: true);
        await primary.close(force: true);
        await backup.close(force: true);
      }
    },
  );

  test(
    'closing after hedge starts terminates both pending connections',
    () async {
      final primary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final backup = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final transport = ParallelAudioSource(headers: {});
      final arrived = Completer<void>();
      final disconnected = Completer<void>();
      var opened = 0;
      var closed = 0;
      Future<void> hold(HttpRequest request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.listen(
          (_) {},
          onDone: () {
            if (++closed == 2) disconnected.complete();
            socket.destroy();
          },
        );
        if (++opened == 2) arrived.complete();
      }

      primary.listen(hold);
      backup.listen(hold);
      try {
        await transport.start(
          'http://127.0.0.1:${primary.port}/video',
          alternatives: ['http://127.0.0.1:${backup.port}/video'],
          hedgeAfter: const Duration(milliseconds: 30),
        );
        await arrived.future.timeout(const Duration(seconds: 2));
        transport.close();
        await disconnected.future.timeout(const Duration(seconds: 2));
      } finally {
        transport.close();
        await primary.close(force: true);
        await backup.close(force: true);
      }
    },
  );
}
