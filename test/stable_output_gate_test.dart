import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/stable_output_gate.dart';

class _Output {
  String? signature;
  bool current = true;
  bool bypass = false;
  bool sourceReady = true;
  final cancelled = Completer<void>();
  final frames = <Completer<void>>[];

  StableOutputGate gate({
    Duration minimum = Duration.zero,
    Duration timeout = const Duration(seconds: 1),
  }) => StableOutputGate(
    readSignature: () => signature,
    nextFrame: () {
      final frame = Completer<void>();
      frames.add(frame);
      return frame.future;
    },
    isCurrent: () => current,
    shouldBypass: () => bypass,
    isSourceReady: () => sourceReady,
    cancelled: cancelled.future,
    minimum: minimum,
    timeout: timeout,
  );

  Future<void> frame() async {
    frames.removeAt(0).complete();
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'buffering placeholder waits for source readiness without frame polling',
    () async {
      final output = _Output()
        ..signature = '960x540'
        ..sourceReady = false;
      final gate = output.gate()..notifyChanged();
      expect(gate.samples, 0);
      expect(output.frames, isEmpty);
      output
        ..signature = '1920x1080'
        ..sourceReady = true;
      gate.notifyChanged();
      await output.frame();
      await output.frame();
      expect(await gate.ready, StableOutputResult.stable);
      expect(gate.signature, '1920x1080');
    },
  );

  test('buffering again invalidates earlier stable observations', () async {
    final output = _Output()..signature = 'A';
    final gate = output.gate()..notifyChanged();
    await output.frame();
    output.sourceReady = false;
    gate.notifyChanged();
    await output.frame();
    expect(output.frames, isEmpty);
    expect(gate.samples, 0);
    output.sourceReady = true;
    gate.notifyChanged();
    await output.frame();
    await output.frame();
    expect(await gate.ready, StableOutputResult.stable);
  });

  test(
    'source-ready notification cannot revive cancelled buffering wait',
    () async {
      final output = _Output()
        ..signature = 'placeholder'
        ..sourceReady = false;
      final gate = output.gate()..notifyChanged();
      output.cancelled.complete();
      expect(await gate.ready, StableOutputResult.cancelled);
      output.sourceReady = true;
      gate.notifyChanged();
      expect(output.frames, isEmpty);
    },
  );

  test(
    'invalid output does not schedule frames; three observations are required',
    () async {
      final output = _Output();
      final gate = output.gate()..notifyChanged();
      expect(output.frames, isEmpty);
      output.signature = 'valid';
      gate
        ..notifyChanged()
        ..notifyChanged();
      expect(gate.samples, 1);
      expect(output.frames, hasLength(1));
      await output.frame();
      expect(gate.samples, 2);
      await output.frame();
      expect(await gate.ready, StableOutputResult.stable);
      expect(output.frames, isEmpty);
    },
  );

  test(
    'change away and back inside one pending frame resets stability',
    () async {
      final output = _Output()..signature = 'A';
      final gate = output.gate()..notifyChanged();
      await output.frame();
      expect(gate.samples, 2);
      output.signature = 'B';
      gate.notifyChanged();
      output.signature = 'A';
      gate.notifyChanged();
      await output.frame();
      expect(gate.samples, 1);
      await output.frame();
      await output.frame();
      expect(await gate.ready, StableOutputResult.stable);
    },
  );

  test(
    'minimum wait remains after three samples without continuous frame polling',
    () async {
      final output = _Output()..signature = 'A';
      final gate = output.gate(minimum: const Duration(milliseconds: 80));
      var completed = false;
      final result = gate.ready.then((value) {
        completed = true;
        return value;
      });
      gate.notifyChanged();
      await output.frame();
      await output.frame();
      expect(completed, isFalse);
      expect(output.frames, isEmpty);
      expect(await result, StableOutputResult.stable);
    },
  );

  test(
    'cancel finishes when frame delivery stops; late frame cannot revive it',
    () async {
      final output = _Output()..signature = 'A';
      final gate = output.gate()..notifyChanged();
      output.cancelled.complete();
      expect(await gate.ready, StableOutputResult.cancelled);
      await output.frame();
      expect(output.frames, isEmpty);
      expect(gate.samples, 1);
    },
  );

  test('timeout finishes even if pending frame never arrives', () async {
    final output = _Output()..signature = 'A';
    final gate = output.gate(timeout: const Duration(milliseconds: 20))
      ..notifyChanged();
    expect(await gate.ready, StableOutputResult.timeout);
    await output.frame();
    expect(output.frames, isEmpty);
  });

  test(
    'PiP notification bypasses blocked frames but cannot bypass cancellation',
    () async {
      final output = _Output()..signature = 'A';
      final gate = output.gate()..notifyChanged();
      output.bypass = true;
      gate.notifyChanged();
      expect(await gate.ready, StableOutputResult.bypass);
      await output.frame();
      expect(output.frames, isEmpty);
      output.current = false;
      final stale = output.gate()..notifyChanged();
      expect(await stale.ready, StableOutputResult.cancelled);
    },
  );
}
