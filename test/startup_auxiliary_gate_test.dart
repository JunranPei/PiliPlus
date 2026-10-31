import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/startup_auxiliary_gate.dart';

void main() {
  test('releases on readiness and removes its listener', () async {
    final stream = StreamController<bool>.broadcast(sync: true);
    final gate = StartupAuxiliaryGate();
    var released = false;
    final waiting = gate
        .wait(readiness: stream.stream, isReady: () => false)
        .then((reason) {
          released = true;
          return reason;
        });
    stream.add(false);
    await Future<void>.delayed(Duration.zero);
    expect(released, false);
    stream.add(true);
    expect(await waiting, 'ready');
    expect(stream.hasListener, false);
    await stream.close();
  });

  test('already ready does not subscribe or delay', () async {
    final stream = StreamController<bool>.broadcast();
    expect(
      await StartupAuxiliaryGate().wait(
        readiness: stream.stream,
        isReady: () => true,
      ),
      'ready',
    );
    expect(stream.hasListener, false);
    await stream.close();
  });

  test('deadline releases page data even if playback fails', () async {
    final stream = StreamController<bool>.broadcast();
    expect(
      await StartupAuxiliaryGate().wait(
        readiness: stream.stream,
        isReady: () => false,
        deadline: const Duration(milliseconds: 15),
      ),
      'deadline',
    );
    expect(stream.hasListener, false);
    await stream.close();
  });

  test(
    'cancel settles all pending operations and supports a new source',
    () async {
      final stream = StreamController<bool>.broadcast(sync: true);
      final gate = StartupAuxiliaryGate();
      final old = List.generate(
        3,
        (_) => gate.wait(
          readiness: stream.stream,
          isReady: () => false,
        ),
      );
      gate.cancel();
      expect(await Future.wait(old), everyElement('cancelled'));
      expect(stream.hasListener, false);
      final next = gate.wait(readiness: stream.stream, isReady: () => false);
      stream.add(true);
      expect(await next, 'ready');
      await stream.close();
    },
  );

  test('closing readiness settles waiting operations', () async {
    final stream = StreamController<bool>.broadcast();
    final waiting = StartupAuxiliaryGate().wait(
      readiness: stream.stream,
      isReady: () => false,
    );
    await stream.close();
    expect(await waiting, 'cancelled');
  });
}
