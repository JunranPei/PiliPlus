import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/plugin/pl_player/playback/parallel_audio_source.dart';
import 'package:PiliPlus/plugin/pl_player/playback/resume_index_hint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/resume_index_fixture.dart';

void main() {
  final bytes = resumeIndexFixture();
  late HttpServer primary;
  late HttpServer backup;
  late HttpClient consumer;
  late ParallelAudioSource source;
  late Future<void> Function(HttpRequest, bool) target;
  late Future<void> Function(HttpRequest, bool) initialization;
  late List<({String name, Map<String, Object?> data})> events;
  late List<Socket> sockets;

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

  Future<void> stall(
    HttpRequest request,
    Completer<void> began,
    Completer<void> closed,
  ) async {
    final socket = await request.response.detachSocket(writeHeaders: false);
    sockets.add(socket);
    socket.listen(
      (_) {},
      onDone: () {
        if (!closed.isCompleted) closed.complete();
        socket.destroy();
      },
    );
    began.complete();
  }

  setUp(() async {
    events = [];
    sockets = [];
    initialization = (request, _) => serve(request);
    Future<HttpServer> server(bool isBackup) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        final work = request.headers.value('range') == 'bytes=600000-'
            ? target(request, isBackup)
            : initialization(request, isBackup);
        unawaited(work.catchError((Object _) {}));
      });
      return server;
    }

    primary = await server(false);
    backup = await server(true);
    consumer = HttpClient();
    source = ParallelAudioSource(
      headers: {'User-Agent': 'current-request'},
      resumePosition: const Duration(seconds: 10),
      resumePresentationTime: true,
      resumeBodyWarmup: true,
      hedgeResumePrefetch: true,
      resumeIndexHint: ResumeIndexHint(
        prefix: Uint8List.sublistView(bytes, 0, 1000),
        totalBytes: bytes.length,
      ),
      onEvent: (name, data) => events.add((name: name, data: data)),
    );
  });
  tearDown(() async {
    source.close();
    consumer.close(force: true);
    for (final socket in sockets) {
      socket.destroy();
    }
    await primary.close(force: true);
    await backup.close(force: true);
  });

  Future<String> start() => source.start(
    'http://127.0.0.1:${primary.port}/current',
    alternatives: ['http://127.0.0.1:${backup.port}/current'],
    hedgeAfter: Duration.zero,
  );

  Future<List<int>> read(String url, String range) async {
    final request = await consumer.getUrl(Uri.parse(url));
    request.headers.set('range', range);
    final response = await request.close();
    expect(response.statusCode, 206);
    return response.fold<List<int>>([], (a, b) => a..addAll(b));
  }

  void freshSource() {
    source.close();
    events.clear();
    source = ParallelAudioSource(
      headers: {'User-Agent': 'current-request'},
      resumePosition: const Duration(seconds: 10),
      resumePresentationTime: true,
      resumeBodyWarmup: true,
      hedgeFreshResumePrefetch: true,
      onEvent: (name, data) => events.add((name: name, data: data)),
    );
  }

  for (final initialBackupWins in [false, true]) {
    test(
      'fresh range can use the other endpoint after '
      '${initialBackupWins ? 'backup' : 'primary'} initialization wins',
      () async {
        freshSource();
        final initStalled = Completer<void>();
        final initClosed = Completer<void>();
        final targetStalled = Completer<void>();
        final targetClosed = Completer<void>();
        final requested = <bool>[];
        initialization = (request, isBackup) async {
          if (isBackup != initialBackupWins) {
            return stall(request, initStalled, initClosed);
          }
          await initStalled.future;
          await serve(request);
        };
        target = (request, isBackup) async {
          requested.add(isBackup);
          expect(request.headers.value('user-agent'), 'current-request');
          if (isBackup == initialBackupWins) {
            return stall(request, targetStalled, targetClosed);
          }
          await targetStalled.future;
          await serve(request);
        };
        final url = await start();
        expect(await read(url, 'bytes=0-65535'), bytes.sublist(0, 65536));
        expect(await read(url, 'bytes=600032-'), bytes.sublist(600032));
        await Future.wait([initClosed.future, targetClosed.future])
            .timeout(const Duration(seconds: 2));
        expect(requested, [initialBackupWins, !initialBackupWins]);
        expect(
          events.any((e) => e.name == 'audio.prefetch.resume.indexHint'),
          isFalse,
        );
        expect(
          events
              .where((e) => e.name == 'audio.prefetch.selected')
              .single
              .data['backup'],
          initialBackupWins,
        );
        expect(
          events
              .where((e) => e.name == 'audio.prefetch.resume.selected')
              .single
              .data['backup'],
          isTrue,
        );
      },
    );
  }

  test('fresh range cancellation closes both target sockets', () async {
    freshSource();
    final began = [Completer<void>(), Completer<void>()];
    final closed = [Completer<void>(), Completer<void>()];
    target = (request, isBackup) => stall(
      request,
      began[isBackup ? 1 : 0],
      closed[isBackup ? 1 : 0],
    );
    final url = await start();
    expect(await read(url, 'bytes=0-65535'), bytes.sublist(0, 65536));
    await Future.wait(began.map((c) => c.future))
        .timeout(const Duration(seconds: 2));
    source.close();
    await Future.wait(closed.map((c) => c.future))
        .timeout(const Duration(seconds: 2));
    expect(
      events.any((e) => e.name == 'audio.prefetch.resume.firstChunk'),
      isFalse,
    );
  });

  test(
    'backup target beats stalled primary and cancels its connection',
    () async {
      final primaryBegan = Completer<void>();
      final primaryClosed = Completer<void>();
      final headers = <String?>[];
      target = (request, isBackup) async {
        headers.add(request.headers.value('user-agent'));
        if (!isBackup) return stall(request, primaryBegan, primaryClosed);
        await primaryBegan.future;
        await serve(request);
      };
      final url = await start();
      await primaryClosed.future.timeout(const Duration(seconds: 2));
      expect(
        events
            .where((e) => e.name == 'audio.prefetch.resume.selected')
            .single
            .data['backup'],
        isTrue,
      );
      expect(headers, ['current-request', 'current-request']);
      expect(await read(url, 'bytes=0-65535'), bytes.sublist(0, 65536));
      expect(await read(url, 'bytes=600032-'), bytes.sublist(600032));
    },
  );

  test('invalid backup cannot win over a valid current primary', () async {
    final invalidSent = Completer<void>();
    target = (request, isBackup) async {
      if (!isBackup) {
        await invalidSent.future;
        return serve(request);
      }
      request.response
        ..statusCode = 206
        ..contentLength = 1;
      request.response.headers.set(
        'content-range',
        'bytes 600001-600001/900000',
      );
      request.response.add([7]);
      await request.response.close();
      invalidSent.complete();
    };
    final url = await start();
    expect(await read(url, 'bytes=0-65535'), bytes.sublist(0, 65536));
    expect(
      await read(url, 'bytes=600000-600099'),
      bytes.sublist(600000, 600100),
    );
    expect(
      events
          .where((e) => e.name == 'audio.prefetch.resume.selected')
          .single
          .data['backup'],
      isFalse,
    );
  });

  test(
    'cancel before target headers closes both speculative connections',
    () async {
      final began = [Completer<void>(), Completer<void>()];
      final closed = [Completer<void>(), Completer<void>()];
      target = (request, isBackup) => stall(
        request,
        began[isBackup ? 1 : 0],
        closed[isBackup ? 1 : 0],
      );
      await start();
      await Future.wait(began.map((c) => c.future))
          .timeout(const Duration(seconds: 2));
      source.close();
      await Future.wait(closed.map((c) => c.future))
          .timeout(const Duration(seconds: 2));
      expect(
        events.any((e) => e.name == 'audio.prefetch.resume.firstChunk'),
        isFalse,
      );
    },
  );
}
