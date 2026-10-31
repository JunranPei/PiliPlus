import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
// Reuse the exact library selected by MediaKit, including an explicit override.
// This resolver has no public export in the pinned media_kit dependency.
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';

/// Creates one unconfigured decoder while the selected source's headers load.
/// Native ownership transfers only for an exact component name; configuration,
/// output Surface, quality and the precise seek position stay unchanged.
class SelectedCodecReservation {
  SelectedCodecReservation._(this._cancelNative, this.requestId, this.cid);

  static const enabled = bool.fromEnvironment('RESERVE_SELECTED_CODEC');
  static bool _attempted = false;
  final void Function() _cancelNative;
  final int requestId;
  final int? cid;
  bool _finished = false;
  bool _cancelSent = false;

  static SelectedCodecReservation? begin({
    required String? codec,
    required int requestId,
    required int? cid,
  }) {
    if (!enabled || !Platform.isAndroid || _attempted || codec == null) {
      return null;
    }
    final String mime;
    if (codec.startsWith('hev1') || codec.startsWith('hvc1')) {
      mime = 'video/hevc';
    } else if (codec.startsWith('avc1')) {
      mime = 'video/avc';
    } else {
      return null;
    }
    _attempted = true;
    try {
      final path = NativeLibrary.path;
      // Resolve both exports before scheduling work. Ordinary libraries without
      // this experimental ABI retain the original decoder creation path.
      final library = DynamicLibrary.open(path)
        ..lookup<NativeFunction<Int32 Function(Pointer<Utf8>, Int32)>>(
          'mpv_pili_reserve_codec',
        );
      final cancel = library.lookupFunction<Void Function(), void Function()>(
        'mpv_pili_cancel_codec_reservation',
      );
      final lease = SelectedCodecReservation._(cancel, requestId, cid);
      PlaybackDiagnostics.event('startup.codecReservation.scheduled', {
        'requestId': requestId,
        'cid': cid,
        'mime': mime,
      });
      unawaited(
        _runInBackground(path, mime)
            .then<void>((result) {
              lease._finished = true;
              PlaybackDiagnostics.event('startup.codecReservation.finished', {
                'requestId': requestId,
                'cid': cid,
                'result': result,
              });
            })
            .catchError((Object error) {
              lease._finished = true;
              PlaybackDiagnostics.event('startup.codecReservation.failed', {
                'requestId': requestId,
                'cid': cid,
                'type': error.runtimeType.toString(),
              });
            }),
      );
      return lease;
    } catch (error) {
      PlaybackDiagnostics.event('startup.codecReservation.unavailable', {
        'requestId': requestId,
        'cid': cid,
        'type': error.runtimeType.toString(),
      });
      return null;
    }
  }

  void cancel() {
    if (_finished || _cancelSent) return;
    _cancelSent = true;
    // Signalling only. The worker releases an unclaimed result even if this
    // happens before its FFI call starts or before native creation finishes.
    _cancelNative();
    PlaybackDiagnostics.event('startup.codecReservation.cancelRequested', {
      'requestId': requestId,
      'cid': cid,
    });
  }

  // This capture scope contains only strings; no native pointers or leases are
  // accidentally captured by the function sent to the new isolate.
  static Future<int> _runInBackground(String path, String mime) =>
      Isolate.run(() => _reserve(path, mime));

  static int _reserve(String path, String mime) {
    final call = DynamicLibrary.open(path)
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32),
          int Function(Pointer<Utf8>, int)
        >('mpv_pili_reserve_codec');
    final value = mime.toNativeUtf8();
    try {
      // This bounds ready-object retention, not the Android factory execution.
      // The worker lives until ownership transfer or resource release completes.
      return call(value, 5000);
    } finally {
      calloc.free(value);
    }
  }
}
