import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/resume_body_recovery.dart';

void main() {
  final bytes = Uint8List.fromList(
    List.generate(800000, (i) => (i ^ (i >> 11)) & 255),
  );
  const offset = 300000;
  late HttpServer origin;
  late StreamController<List<int>> primary;
  late ResumeBodyRecovery recovery;
  late Future<void> Function(HttpRequest) handler;
  late Completer<void> requested, release, rejected, done;
  late List<int> delivered;
  late List<Map<String, Object?>> events;
  late StreamSubscription<List<int>> subscription;
  Timer? drip;
  int position = offset;
  int requests = 0;

  Future<void> serve(HttpRequest request) async {
    final start = int.parse(
      request.headers.value('range')!.substring(6).split('-').first,
    );
    request.response
      ..statusCode = 206
      ..contentLength = bytes.length - start
      ..headers.set('content-range', 'bytes $start-799999/800000');
    request.response.add(bytes.sublist(start));
    await request.response.close();
  }

  setUp(() async {
    position = offset;
    requests = 0;
    delivered = [];
    events = [];
    requested = Completer<void>();
    release = Completer<void>();
    rejected = Completer<void>();
    done = Completer<void>();
    primary = StreamController<List<int>>();
    handler = serve;
    origin = (await HttpServer.bind(InternetAddress.loopbackIPv4, 0))
      ..listen((request) async {
        requests++;
        if (!requested.isCompleted) requested.complete();
        await release.future;
        await handler(request).catchError((Object _) {});
      });
  });

  void start({bool enabled = true}) {
    recovery = ResumeBodyRecovery(
      source: primary.stream,
      alternate: Uri.parse('http://127.0.0.1:${origin.port}/video'),
      headers: {},
      offset: offset,
      total: bytes.length,
      progressRace: enabled,
      stallAfter: const Duration(milliseconds: 50),
      closePrimary: () {},
      onEvent: (name, data) {
        events.add({'event': name, ...data});
        if (name == 'rejected' && !rejected.isCompleted) rejected.complete();
      },
    );
    subscription = recovery.stream.listen(
      delivered.addAll,
      onError: done.completeError,
      onDone: done.complete,
    );
  }

  void send(int length) {
    primary.add(bytes.sublist(position, position + length));
    position += length;
  }

  void finishPrimary() {
    drip?.cancel();
    send(bytes.length - position);
    primary.close().ignore();
  }

  Future<void> caughtUp() async {
    final end = DateTime.now().add(const Duration(seconds: 2));
    while (delivered.length < position - offset) {
      if (DateTime.now().isAfter(end)) {
        throw StateError('Primary delivery did not progress');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  void trickle() {
    send(113000);
    drip = Timer.periodic(const Duration(milliseconds: 5), (_) => send(1024));
  }

  tearDown(() async {
    drip?.cancel();
    if (!release.isCompleted) release.complete();
    await subscription.cancel();
    await recovery.close();
    primary.close().ignore();
    await origin.close(force: true);
  });

  test(
    'trickle keeps old stall detector quiet but is recovered by progress race',
    () async {
      start();
      trickle();
      await requested.future;
      drip!.cancel();
      send(32000); // The primary advances while alternate headers are pending.
      await caughtUp();
      final beforeSwitch = delivered.length;
      release.complete();
      await done.future;
      expect(delivered, bytes.sublist(offset));
      expect(
        events.singleWhere((e) => e['event'] == 'begin')['reason'],
        'slow-prefix-progress',
      );
      final switched = events.singleWhere((e) => e['event'] == 'switched');
      expect(switched['receivedBytes'], beforeSwitch);
      expect(switched['matchedBytes'] as int, greaterThan(65536));
      expect(requests, 1);
    },
  );

  test(
    'disabled progress race preserves original slow trickle without alternate',
    () async {
      start(enabled: false);
      trickle();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(requests, 0);
      finishPrimary();
      await done.future;
      expect(delivered, bytes.sublist(offset));
    },
  );

  for (final overflow in [false, true]) {
    test(
      'continued primary survives ${overflow ? 'replay window overrun' : 'mismatch after original overlap'}',
      () async {
        handler = (request) async {
          final start = int.parse(
            request.headers.value('range')!.substring(6).split('-').first,
          );
          final payload = bytes.sublist(start);
          if (!overflow) payload[65536 + 10] ^= 1;
          request.response
            ..statusCode = 206
            ..contentLength = payload.length
            ..headers.set('content-range', 'bytes $start-799999/800000');
          request.response.add(payload);
          await request.response.close();
        };
        start();
        trickle();
        await requested.future;
        drip!.cancel();
        send(overflow ? 300000 : 32000);
        await caughtUp();
        release.complete();
        await rejected.future;
        expect(
          events.singleWhere((e) => e['event'] == 'rejected')['reason'],
          overflow ? 'comparison-window-exceeded' : 'overlap-mismatch',
        );
        finishPrimary();
        await done.future;
        expect(delivered, bytes.sublist(offset));
        expect(events.where((e) => e['event'] == 'switched'), isEmpty);
      },
    );
  }

  test(
    'healthy prefix disables progress race without waiting for a buffer',
    () async {
      start();
      send(300000);
      drip = Timer.periodic(const Duration(milliseconds: 5), (_) => send(1024));
      await caughtUp();
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(requests, 0);
      finishPrimary();
      await done.future;
      expect(delivered, bytes.sublist(offset));
    },
  );

  test('paused consumer suppresses both progress and stall timers', () async {
    start();
    send(113000);
    await caughtUp();
    subscription.pause();
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(requests, 0);
    subscription.resume();
    finishPrimary();
    await done.future;
    expect(delivered, bytes.sublist(offset));
  });

  test(
    'cancel during catch-up prevents late switch and additional requests',
    () async {
      start();
      trickle();
      await requested.future;
      drip!.cancel();
      await subscription.cancel().timeout(const Duration(seconds: 1));
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(events.where((e) => e['event'] == 'switched'), isEmpty);
      expect(requests, 1);
    },
  );
}
