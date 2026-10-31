import 'package:flutter/services.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';

/// One background service lookup; orientation events keep their existing owner.
abstract final class OrientationServiceWarmup {
  static Future<void>? _pending;

  static Future<void> prepare() => _pending ??= _prepare();

  static Future<void> _prepare() async {
    try {
      final result =
          await const MethodChannel(
                'com.personal.piliplus/startup_services',
              )
              .invokeMapMethod<String, dynamic>('prepareOrientationServices')
              .timeout(
                const Duration(seconds: 3),
              );
      if (PlaybackDiagnostics.enabled) {
        // Startup can precede the sparse capture file; preserve this in logcat.
        // ignore: avoid_print
        print(
          '[ORIENTATION_WARMUP] ${DateTime.now().microsecondsSinceEpoch} $result',
        );
        PlaybackDiagnostics.event('startup.orientationServices.ready', {
          ...?result,
        });
      }
    } catch (error) {
      if (PlaybackDiagnostics.enabled) {
        // ignore: avoid_print
        print(
          '[ORIENTATION_WARMUP] ${DateTime.now().microsecondsSinceEpoch} failed ${error.runtimeType}',
        );
      }
    }
  }
}
