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
          // It is important to use a new android.view.Surface each time a new video-output is created because: https://stackoverflow.com/a/21564236
          // Not doing so will cause MediaCodec usage inside libavcodec to incorrectly fail with error (because this android.view.Surface would be used twice):
          // "native_window_api_connect returned an error: Invalid argument (-22)" & next less-efficient hwdec will be used redundantly.

          // Create a new android.view.Surface & obtain object reference to it.
          // NOTE: Previous android.view.Surface & object reference is internally released/destroyed by the method.
          final data = await _channel.invokeMethod(
            'VideoOutputManager.CreateSurface',
            {'handle': ctx.address.toString()},
          );
          debugPrint(data.toString());
          // Save the android.view.Surface object reference for usage inside player.stream.videoParams.listen.
          _wid = data['wid'];
        }

        // By default, android.view.Surface has a size of 1x1. If we assign --wid here, libmpv will internally start rendering & the first frame will be drawn as a solid color: https://github.com/media-kit/media-kit/issues/339
        // The solution is to assign --wid after android.graphics.SurfaceTexture.setDefaultBufferSize has been called & --android-surface-size has been updated (see inside player.stream.videoParams.listen).

        // Assign --wid here if --vo is not "gpu" or "null" i.e. custom vo/hwdec was passed through [VideoControllerConfiguration].
        try {
          if (_nativePipWid != null) {
            // PiP owns the real SurfaceView while it is active.  Keep the
            // Flutter output untouched until native PiP asks us to restore it.
            player.setOption('wid', _nativePipWid.toString());
            player.setOption('vo', 'gpu');
            return;
          }
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
      return _lock.synchronizedSync(() {
        // Release any references to current android.view.Surface.
        //
        // It is important to set --vo=null here for 2 reasons:
        // 1. Allow the native code to drop any references to the android.view.Surface.
        // 2. Resize the android.graphics.SurfaceTexture to next video's resolution before setting --vo=gpu.
        try {
          // ----------------------------------------------
          player.setOption('vo', 'null');
          player.setOption('wid', '0');
          // ----------------------------------------------
        } catch (exception, stacktrace) {
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
      });
    });

    _subscription = player.stream.videoParams.listen(
      (event) => _lock.synchronized(() async {
        if (const [0, null].contains(event.dw) ||
            const [0, null].contains(event.dh) ||
            _wid == null) {
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

        // Keep the previous rect while the native SurfaceTexture is resized.
        // Publishing Rect.zero removes SimpleVideo's Texture and causes a black
        // PiP frame; the final rect below is enough to update its layout.
        try {
          if (vo == 'gpu') {
            if (_nativePipWid != null) {
              final nativeSize = _nativePipSurfaceSize;
              if (nativeSize != null) {
                player.setOption('android-surface-size', nativeSize);
              }
              player.setOption('wid', _nativePipWid.toString());
              player.setOption('vo', 'gpu');
              rect.value = Rect.fromLTRB(
                0.0,
                0.0,
                width.toDouble(),
                height.toDouble(),
              );
              return;
            }
            // NOTE: Only required for --vo=gpu
            // With --vo=gpu, we need to update the android.graphics.SurfaceTexture size & notify libmpv to re-create vo.
            // In native Android, this kind of rendering is done with android.view.SurfaceView + android.view.SurfaceHolder, which offers onSurfaceChanged to handle this.
            final surfaceData = await _channel
                .invokeMethod('VideoOutputManager.SetSurfaceTextureSize', {
                  'handle': player.handle.toString(),
                  'width': width.toString(),
                  'height': height.toString(),
                });

            // SurfaceProducer may replace the backing Surface while the PiP
            // bounds change. Use the new native reference before reattaching
            // libmpv, otherwise one frame can still target the old Surface.
            if (surfaceData is Map) {
              final nativeWid = surfaceData['wid'];
              if (nativeWid is num && nativeWid != 0) {
                _wid = nativeWid.toInt();
              }
            }

            // ----------------------------------------------
            player.setOption('android-surface-size', '${width}x$height');
            player.setOption('wid', _wid.toString());
            player.setOption('vo', 'gpu');
          }
          // ----------------------------------------------
        } catch (exception, stacktrace) {
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
    // Release the native resources.
    final handle = player.handle;
    _controllers.remove(handle);
    await _channel.invokeMethod('VideoOutputManager.Dispose', {
      'handle': handle.toString(),
    });
  }

  /// Pointer address to the global object reference of `android.view.Surface` i.e. `(intptr_t)(*android.view.Surface)`.
  int? _wid;

  /// Global reference and size of the native SurfaceView used in PiP.
  int? _nativePipWid;
  String? _nativePipSurfaceSize;

  /// [Lock] used to synchronize the [_widthStreamSubscription] & [_heightStreamSubscription].
  final _lock = Lock();

  /// [StreamSubscription] for listening to video [Rect] from [_controller].
  StreamSubscription<VideoParams>? _subscription;

  /// Currently created [AndroidVideoController]s.
  static final _controllers = HashMap<int, AndroidVideoController>();

  /// Switch libmpv to/from the Activity-owned PiP SurfaceView.
  static Future<void> applyNativePipSurface(Map<String, dynamic> data) async {
    final handle = (data['handle'] as num?)?.toInt();
    final wid = (data['wid'] as num?)?.toInt() ?? 0;
    if (handle == null) return;
    final controller = _controllers[handle];
    if (controller == null) return;
    await controller._lock.synchronized(() async {
      try {
        if (wid != 0 && data['visible'] == true) {
          controller._nativePipWid = wid;
          final width = (data['width'] as num?)?.toInt() ?? 0;
          final height = (data['height'] as num?)?.toInt() ?? 0;
          if (width > 0 && height > 0) {
            controller._nativePipSurfaceSize = '${width}x$height';
            controller.player.setOption(
              'android-surface-size',
              controller._nativePipSurfaceSize!,
            );
          }
          controller.player.setOption('wid', wid.toString());
          controller.player.setOption('vo', 'gpu');
        } else {
          controller._nativePipWid = null;
          controller._nativePipSurfaceSize = null;
          controller.player.setOption('vo', 'null');
          controller.player.setOption('wid', '0');
          if (controller._wid != null) {
            final width = controller.player.state.width;
            final height = controller.player.state.height;
            if (width > 0 && height > 0) {
              controller.player.setOption(
                'android-surface-size',
                '${width}x$height',
              );
            }
            controller.player.setOption('wid', controller._wid.toString());
            controller.player.setOption('vo', 'gpu');
          }
        }
      } catch (error, stacktrace) {
        debugPrint(error.toString());
        debugPrint(stacktrace.toString());
      }
    });
  }

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
                final int handle = call.arguments['handle'];
                final int id = call.arguments['id'];
                final int wid = call.arguments['wid'];
                final finalRect = call.arguments['rect'];
                final controller = _controllers[handle];
                if (controller != null) {
                  controller.id.value = id;
                  controller._wid = wid == 0 ? null : wid;
                  if (finalRect is Map) {
                    controller.rect.value = Rect.fromLTRB(
                      (finalRect['left'] as num).toDouble(),
                      (finalRect['top'] as num).toDouble(),
                      ((finalRect['left'] as num) + (finalRect['width'] as num))
                          .toDouble(),
                      ((finalRect['top'] as num) + (finalRect['height'] as num))
                          .toDouble(),
                    );
                  }
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
}
