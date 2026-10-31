import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/playback/orientation_service_warmup.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'one pending lookup times out safely and absorbs a late failure',
    (
      tester,
    ) async {
      const channel = MethodChannel('com.personal.piliplus/startup_services');
      final native = Completer<Object?>();
      var calls = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) {
        expect(call.method, 'prepareOrientationServices');
        calls++;
        return native.future;
      });
      final first = OrientationServiceWarmup.prepare();
      final second = OrientationServiceWarmup.prepare();
      expect(identical(first, second), isTrue);
      await tester.pump();
      expect(calls, 1);
      await tester.pump(const Duration(seconds: 4));
      await Future.wait([first, second]);
      native.completeError(PlatformException(code: 'activity-destroyed'));
      await tester.pump();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    },
  );
}
