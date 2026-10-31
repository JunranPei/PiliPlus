import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/stable_output_gate.dart';

class _Output {
  String? signature;
  bool current = true;
  bool bypass = false;
  final cancelled = Completer<void>();
  StableOutputResult? result;

  StableOutputGate gate({Duration minimum = Duration.zero}) {
    final gate = StableOutputGate(
      readSignature: () => signature,
      nextFrame: () =>
          throw StateError('Dwell must not request a Flutter frame'),
      isCurrent: () => current,
      shouldBypass: () => bypass,
      cancelled: cancelled.future,
      stableDwell: const Duration(milliseconds: 32),
      minimum: minimum,
      timeout: const Duration(seconds: 1),
    );
    unawaited(gate.ready.then((value) => result = value));
    return gate;
  }
}

void main() {
  testWidgets(
    'waits for a valid unchanged interval without requesting frames',
    (tester) async {
      final output = _Output();
      final gate = output.gate()..notifyChanged();
      await tester.pump(const Duration(milliseconds: 40));
      expect(output.result, isNull);
      output.signature = 'A';
      gate.notifyChanged();
      await tester.pump(const Duration(milliseconds: 31));
      expect(output.result, isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(output.result, StableOutputResult.stable);
      expect(gate.samples, 2); // Initial observation and deadline recheck.
    },
  );

  testWidgets('change away and back restarts the full interval', (
    tester,
  ) async {
    final output = _Output()..signature = 'A';
    final gate = output.gate()..notifyChanged();
    await tester.pump(const Duration(milliseconds: 25));
    output.signature = 'B';
    gate.notifyChanged();
    output.signature = 'A';
    gate.notifyChanged();
    await tester.pump(const Duration(milliseconds: 7));
    expect(output.result, isNull);
    await tester.pump(const Duration(milliseconds: 25));
    expect(output.result, StableOutputResult.stable);
  });

  testWidgets(
    'repeated notifications do not postpone dwell and 120ms floor remains',
    (tester) async {
      final output = _Output()..signature = 'A';
      final gate = output.gate(minimum: const Duration(milliseconds: 120))
        ..notifyChanged();
      await tester.pump(const Duration(milliseconds: 20));
      gate.notifyChanged();
      await tester.pump(const Duration(milliseconds: 12));
      expect(gate.samples, 2);
      expect(output.result, isNull);
      await tester.pump(const Duration(milliseconds: 87));
      expect(output.result, isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(output.result, StableOutputResult.stable);
    },
  );

  testWidgets(
    'deadline rechecks state even if a change notification was missed',
    (tester) async {
      final output = _Output()..signature = 'A';
      final gate = output.gate()..notifyChanged();
      await tester.pump(const Duration(milliseconds: 25));
      output.signature = 'B';
      await tester.pump(const Duration(milliseconds: 7));
      expect(output.result, isNull);
      expect(gate.signature, 'B');
      await tester.pump(const Duration(milliseconds: 32));
      expect(output.result, StableOutputResult.stable);
    },
  );

  testWidgets(
    'cancellation removes the dwell timer and ignores later notifications',
    (tester) async {
      final output = _Output()..signature = 'A';
      final gate = output.gate()..notifyChanged();
      output.cancelled.complete();
      await tester.pump();
      expect(output.result, StableOutputResult.cancelled);
      gate.notifyChanged();
      await tester.pump(const Duration(milliseconds: 100));
      expect(gate.samples, 1);
    },
  );

  testWidgets('PiP bypass and timeout need no output frames', (tester) async {
    final output = _Output();
    final gate = output.gate()..notifyChanged();
    output.bypass = true;
    gate.notifyChanged();
    await tester.pump();
    expect(output.result, StableOutputResult.bypass);
    final absent = _Output();
    absent.gate().notifyChanged();
    await tester.pump(const Duration(seconds: 1));
    expect(absent.result, StableOutputResult.timeout);
  });
}
