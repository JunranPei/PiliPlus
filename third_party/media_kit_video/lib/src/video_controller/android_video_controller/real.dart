/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import 'package:media_kit/media_kit.dart';

// ignore_for_file: implementation_imports
import 'package:media_kit/ffi/ffi.dart';

import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';

/// {@template android_video_controller}
///
/// AndroidVideoController
/// ----------------------
///
/// The [PlatformVideoController] implementation based on native JNI & C/C++ used on Android.
///
/// {@endtemplate}
class AndroidVideoController extends PlatformVideoController {
  /// Whether [AndroidVideoController] is supported on the current platform or not.
  static bool get supported => Platform.isAndroid;

  /// Fixed width of the video output.
  int? width;

  /// Fixed height of the video output.
  int? height;

  // ----------------------------------------------

  bool get androidAttachSurfaceAfterVideoParameters =>
      configuration.androidAttachSurfaceAfterVideoParameters ?? vo == 'gpu';

  /// --vo
  String get vo => configuration.vo ?? 'gpu';

  /// --hwdec
  // Future<String> get hwdec async {
  //   if (_hwdec != null) {
  //     return _hwdec!;
  //   }
  //   bool enableHardwareAcceleration = configuration.enableHardwareAcceleration;
  //   // Enforce software rendering in emulators.
  //   final bool isEmulator = await _channel.invokeMethod('Utils.IsEmulator');
  //   if (isEmulator) {
  //     debugPrint('media_kit: AndroidVideoController: Emulator detected.');
  //     debugPrint('media_kit: AndroidVideoController: Enforcing S/W rendering.');
  //     enableHardwareAcceleration = false;
  //   }
  //   _hwdec =
  //       configuration.hwdec ??
  //       (enableHardwareAcceleration ? 'auto-safe' : 'no');
  //   return _hwdec!;
  // }

  // ----------------------------------------------

  String? _current;

  /// {@macro android_video_controller}
  AndroidVideoController._(super.player, super.configuration) {
    player.onLoadHooks.add(() {
      return _lock.synchronized(() async {
        final mpv = NativePlayer.mpv;
        final ctx = player.ctx;

        // Skip surface re-creation if same resource.
        final name = 'path'.toNativeUtf8();
        final path = mpv.mpv_get_property_string(ctx, name);
        final current = path.toDartString();
        calloc.free(name.cast());
        mpv.mpv_free(path.cast());

        if (_current != current) {
          _current = current;
          // Start a fresh geometry epoch for the new media item.  mpv may
          // report a small RGBA decoder surface before the final hardware
          // output; that transitional report must never become the Flutter
          // rect or the native buffer size.
          _surfaceSizePublished = false;
          // The native platform view owns one SurfaceView for this player.
          // Reusing it across media items and PiP avoids a second output
          // being created during the Activity resize.
          final data = await _channel.invokeMethod(
            'VideoOutputManager.CreateSurface',
            {'handle': player.handle.toString()},
          );
          debugPrint(data.toString());
          if (data is Map) {
            final wid = data['wid'];
            if (wid is num && wid != 0) _wid = wid.toInt();
          }
        }

        // By default, android.view.Surface has a size of 1x1. If we assign --wid here, libmpv will internally start rendering & the first frame will be drawn as a solid color: https://github.com/media-kit/media-kit/issues/339
        // The solution is to assign --wid after android.graphics.SurfaceTexture.setDefaultBufferSize has been called & --android-surface-size has been updated (see inside player.stream.videoParams.listen).

        // Assign --wid here if --vo is not "gpu" or "null" i.e. custom vo/hwdec was passed through [VideoControllerConfiguration].
        try {
          // ----------------------------------------------
          if (!androidAttachSurfaceAfterVideoParameters) {
            player.setOption('wid', _wid.toString());
            player.setOption('vo', vo);
          }
          // ----------------------------------------------
        } catch (exception, stacktrace) {
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
      });
    });
    player.onUnloadHooks.add(() {
      return _lock.synchronized(() async {
        _surfaceSizePublished = false;
        // Release any references to current android.view.Surface.
        //
        // It is important to set --vo=null here for 2 reasons:
        // 1. Allow the native code to drop any references to the android.view.Surface.
        // 2. Resize the android.graphics.SurfaceTexture to next video's resolution before setting --vo=gpu.
        try {
          // ----------------------------------------------
          player.setOption('vo', 'null');
          player.setOption('wid', '0');
          await _channel.invokeMethod('VideoOutputManager.ResetSurfaceSize', {
            'handle': player.handle.toString(),
          });
          // ----------------------------------------------
        } catch (exception, stacktrace) {
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
      });
    });

    _subscription = player.stream.videoParams.listen(
      (event) => _lock.synchronized(() async {
        debugPrintSynchronously(
          '[PLAYER_SURFACE] event=videoParams.raw handle=${player.handle} wid=$_wid published=$_surfaceSizePublished params=$event',
        );
        if (const [0, null].contains(event.dw) ||
            const [0, null].contains(event.dh)) {
          return;
        }

        final int width;
        final int height;
        if (event.rotate == 0 || event.rotate == 180) {
          width = event.dw ?? 0;
          height = event.dh ?? 0;
        } else {
          // width & height are swapped for 90 or 270 degrees rotation.
          width = event.dh ?? 0;
          height = event.dw ?? 0;
        }

        // mpv can publish a decoder/intermediate RGBA size before the final
        // hardware output (for example 960x540 followed by 1920x1080
        // yuv420p).  Do not expose that transient size to Flutter or to the
        // native producer: changing either one after the first frame is what
        // caused the startup scale flash and the stale-frame crop in PiP.
        final pixelFormat = event.pixelformat;
        if (pixelFormat == 'rgba') {
          debugPrint(
            '[PLAYER_SURFACE] event=videoParams.ignored '
            'reason=transitionalRgba size=${width}x$height',
          );
          return;
        }

        // A real source change resets this gate above.  Within one media item
        // keep the first non-RGBA geometry for both the producer and the
        // Flutter rect; later decoder reports must not resize the visible
        // widget while Android is entering or leaving PiP.
        if (_surfaceSizePublished) {
          debugPrintSynchronously(
            '[PLAYER_SURFACE] event=videoParams.skipPublished size=${width}x$height format=$pixelFormat rect=${rect.value}',
          );
          return;
        }
        // Keep one engine texture and update only its final producer buffer
        // size.  The Activity can resize the Flutter root for PiP without a
        // second PlatformView/SurfaceView layout pass.
        try {
          if (vo == 'gpu') {
            final surfaceData = await _channel
                .invokeMethod('VideoOutputManager.SetSurfaceSize', {
                  'handle': player.handle.toString(),
                  'width': width.toString(),
                  'height': height.toString(),
                });

            var nativeSurfaceReady = false;
            if (surfaceData is Map) {
              final nativeWid = surfaceData['wid'];
              if (nativeWid is num && nativeWid != 0) {
                _wid = nativeWid.toInt();
                nativeSurfaceReady = true;
              }
            }

            if (!nativeSurfaceReady) {
              debugPrint(
                '[PLAYER_SURFACE] event=videoParams.retry '
                'reason=nativeSurfaceUnavailable size=${width}x$height',
              );
              return;
            }

            // ----------------------------------------------
            player.setOption('android-surface-size', '${width}x$height');
            if (_wid != null) {
              player.setOption('wid', _wid.toString());
              player.setOption('vo', 'gpu');
            }
            _surfaceSizePublished = true;
          }
          // ----------------------------------------------
        } catch (exception, stacktrace) {
          _surfaceSizePublished = false;
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
        rect.value = Rect.fromLTRB(
          0.0,
          0.0,
          width.toDouble(),
          height.toDouble(),
        );
      }),
    );
  }

  /// {@macro android_video_controller}
  static Future<PlatformVideoController> create(
    Player player,
    VideoControllerConfiguration configuration,
  ) async {
    // Retrieve the native handle of the [Player].
    final handle = player.handle;
    // Return the existing [VideoController] if it's already created.
    if (_controllers.containsKey(handle)) {
      return _controllers[handle]!;
    }

    // Creation:
    final controller = AndroidVideoController._(player, configuration);

    // Register [_dispose] for execution upon [Player.dispose].
    player.release.add(controller._dispose);

    // Store the [VideoController] in the [_controllers].
    _controllers[handle] = controller;

    final data = await _channel.invokeMethod('VideoOutputManager.Create', {
      'handle': handle.toString(),
    });
    debugPrint(data.toString());

    final int? id = data['id'];

    // ----------------------------------------------

    final values = {
      // It is necessary to set vo=null here to avoid SIGSEGV, --wid must be assigned before vo=gpu is set.
      'vo': 'null',
      'hwdec':
          configuration.hwdec ??
          (configuration.enableHardwareAcceleration ? 'auto-safe' : 'no'),
      'vid': 'auto',
      'opengl-es': 'yes',
      'force-window': 'yes',
      'gpu-context': 'android',
      'sub-use-margins': 'no',
      'sub-font-provider': 'none',
      'sub-scale-with-window': 'yes',
      'hwdec-codecs': 'h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1',
    };

    for (final entry in values.entries) {
      final name = entry.key.toNativeUtf8();
      final value = entry.value.toNativeUtf8();
      NativePlayer.mpv.mpv_set_property_string(player.ctx, name, value);
      calloc.free(name);
      calloc.free(value);
    }
    // ----------------------------------------------

    controller.id.value = id;

    // Return the [PlatformVideoController].
    return controller;
  }

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  @override
  Future<void>? setSize({int? width, int? height}) {
    throw UnsupportedError(
      '[AndroidVideoController.setSize] is not available on Android',
    );
  }

  /// Disposes the instance. Releases allocated resources back to the system.
  Future<void> _dispose() async {
    // Dispose the [StreamSubscription]s.
    await _subscription?.cancel();
    _surfaceSizePublished = false;
    // Release the native resources.
    final handle = player.handle;
    try {
      player.setOption('vo', 'null');
      player.setOption('wid', '0');
    } catch (_) {}
    await _channel.invokeMethod('VideoOutputManager.Dispose', {
      'handle': handle.toString(),
    });
    _controllers.remove(handle);
  }

  /// Pointer address to the global object reference of `android.view.Surface` i.e. `(intptr_t)(*android.view.Surface)`.
  int? _wid;

  bool _surfaceSizePublished = false;

  /// [Lock] used to synchronize the [_widthStreamSubscription] & [_heightStreamSubscription].
  final _lock = Lock();

  /// [StreamSubscription] for listening to video [Rect] from [_controller].
  StreamSubscription<VideoParams>? _subscription;

  /// Currently created [AndroidVideoController]s.
  static final _controllers = HashMap<int, AndroidVideoController>();

  /// [MethodChannel] for invoking platform specific native implementation.
  static final _channel =
      const MethodChannel(
        'com.alexmercerind/media_kit_video',
      )..setMethodCallHandler((MethodCall call) async {
        try {
          debugPrint(call.method.toString());
          debugPrint(call.arguments.toString());
          switch (call.method) {
            case 'VideoOutput.Resize':
              {
                final int handle = (call.arguments['handle'] as num).toInt();
                final int id = (call.arguments['id'] as num).toInt();
                final int wid = (call.arguments['wid'] as num).toInt();
                final finalRect = call.arguments['rect'];
                final retiredWid =
                    (call.arguments['retiredWid'] as num?)?.toInt() ?? 0;
                final controller = _controllers[handle];
                if (controller != null) {
                  await controller._onNativeSurfaceChanged(
                    id: id,
                    wid: wid,
                    rect: finalRect,
                    retiredWid: retiredWid,
                  );
                }
                break;
              }
            case 'VideoOutput.WaitUntilFirstFrameRenderedNotify':
              {
                // Notify about updated texture ID & [Rect].
                final int handle = call.arguments['handle'];
                debugPrint(handle.toString());
                // Notify about the first frame being rendered.
                final completer =
                    _controllers[handle]?.waitUntilFirstFrameRenderedCompleter;
                if (!(completer?.isCompleted ?? true)) {
                  completer?.complete();
                }
                break;
              }
            default:
              {
                break;
              }
          }
        } catch (exception, stacktrace) {
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
      });

  Future<void> _onNativeSurfaceChanged({
    required int id,
    required int wid,
    required Object? rect,
    required int retiredWid,
  }) async {
    debugPrintSynchronously(
      '[PLAYER_SURFACE] event=nativeSurface.queued handle=${player.handle} texture=$id wid=$wid retiredWid=$retiredWid rect=$rect',
    );
    await _lock.synchronized(() async {
      debugPrintSynchronously(
        '[PLAYER_SURFACE] event=nativeSurface.begin handle=${player.handle} oldWid=$_wid newWid=$wid',
      );
      this.id.value = id;
      _wid = wid == 0 ? null : wid;
      if (rect is Map) {
        this.rect.value = Rect.fromLTRB(
          (rect['left'] as num).toDouble(),
          (rect['top'] as num).toDouble(),
          ((rect['left'] as num) + (rect['width'] as num)).toDouble(),
          ((rect['top'] as num) + (rect['height'] as num)).toDouble(),
        );
      }
      try {
        // A replacement Surface must be detached from mpv before its old JNI
        // reference is released.  This ordering is synchronous and avoids a
        // use-after-free during Android's surface recreation.
        if (retiredWid != 0) {
          player.setOption('vo', 'null');
          player.setOption('wid', '0');
          await _channel.invokeMethod('VideoOutputManager.ReleaseSurfaceRef', {
            'handle': player.handle.toString(),
            'wid': retiredWid.toString(),
          });
        }
        if (wid == 0) {
          player.setOption('vo', 'null');
          player.setOption('wid', '0');
        } else {
          if (rect is Map) {
            final width = (rect['width'] as num?)?.toInt() ?? 0;
            final height = (rect['height'] as num?)?.toInt() ?? 0;
            if (width > 0 && height > 0) {
              player.setOption('android-surface-size', '${width}x$height');
            }
          }
          player.setOption('wid', wid.toString());
          player.setOption('vo', 'gpu');
        }
      } catch (error, stacktrace) {
        debugPrint(error.toString());
        debugPrint(stacktrace.toString());
      }
      debugPrintSynchronously(
        '[PLAYER_SURFACE] event=nativeSurface.end handle=${player.handle} wid=$_wid texture=${this.id.value} rect=${this.rect.value}',
      );
    });
  }
}
