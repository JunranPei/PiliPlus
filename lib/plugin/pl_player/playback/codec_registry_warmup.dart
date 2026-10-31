import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';

/// Prepare Android capability metadata once, independently of source loading.
abstract final class CodecRegistryWarmup {
  static Future<void>? _pending;

  static Future<void> prepare() => _pending ??= _prepare();

  static Future<void> _prepare() async {
    try {
      final result =
          await const MethodChannel(
                'com.personal.piliplus/startup_codecs',
              )
              .invokeMapMethod<String, dynamic>('prepareCodecRegistry')
              .timeout(
                const Duration(seconds: 3),
              );
      if (PlaybackDiagnostics.enabled) {
        // This may finish before the sparse capture file is opened.
        // ignore: avoid_print
        print(
          '[CODEC_REGISTRY_WARMUP] ${jsonEncode({'utcUs': DateTime.now().microsecondsSinceEpoch, ...?result})}',
        );
        PlaybackDiagnostics.event('startup.codecRegistry.result', {...?result});
      }
    } catch (error) {
      if (PlaybackDiagnostics.enabled) {
        // ignore: avoid_print
        print(
          '[CODEC_REGISTRY_WARMUP] ${jsonEncode({'utcUs': DateTime.now().microsecondsSinceEpoch, 'success': false, 'errorType': error.runtimeType.toString()})}',
        );
      }
    }
  }
}
