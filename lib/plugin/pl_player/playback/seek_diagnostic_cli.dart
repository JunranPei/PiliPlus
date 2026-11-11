import 'package:flutter/services.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/playback/mpv_async_property_reader.dart';
import 'package:PiliPlus/plugin/pl_player/playback/seek_diagnostic_export.dart';
import 'package:PiliPlus/utils/device_utils.dart';

abstract final class SeekDiagnosticCli {
  static const channel = MethodChannel('piliplus/playback_diagnostics');
  static void install() {
    if (!SeekDiagnosticExport.enabled) return;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'cli.command') throw MissingPluginException();
      final args = Map<String, dynamic>.from(call.arguments as Map);
      if (args['command'] == 'export') {
        return {'path': (await SeekDiagnosticExport.createBundle()).path};
      }
      final controller = PlPlayerController.instance;
      if (controller == null) throw PlatformException(code: 'NO_PLAYER');
      switch (args['command']) {
        case 'seek':
          final ms = (args['positionMs'] as num).toInt();
          if (ms < 0) throw PlatformException(code: 'INVALID_POSITION');
          await controller.seek(Duration(milliseconds: ms));
        case 'play':
          await controller.play();
        case 'pause':
          await controller.pause();
        case 'controls':
          final value = args['value'];
          if (value != 'show' && value != 'hide') {
            throw PlatformException(code: 'INVALID_CONTROLS');
          }
          // Cancel the normal auto-hide timer. Diagnostic UI operations release
          // this hold explicitly after injecting the real touch event.
          controller.controls = false;
          controller.showControls.value = value == 'show';
        case 'fullscreen':
          final value = args['value'];
          if (value != 'on' && value != 'off') {
            throw PlatformException(code: 'INVALID_FULLSCREEN');
          }
          await controller.triggerFullScreen(status: value == 'on');
        case 'pip':
          if (!await controller.enterPip()) {
            throw PlatformException(code: 'PIP_REFUSED');
          }
        case 'speed':
          final speed = double.tryParse(args['value'] as String? ?? '');
          if (speed == null || !speed.isFinite || speed < 0.25 || speed > 4) {
            throw PlatformException(code: 'INVALID_SPEED');
          }
          await controller.setPlaybackSpeed(speed);
        case 'audio-output':
          final output = args['value'];
          if (output != 'audiotrack' && output != 'aaudio') {
            throw PlatformException(code: 'INVALID_OUTPUT');
          }
          await controller.videoPlayerController?.command([
            'set',
            'ao',
            output as String,
          ]);
        case 'status':
          break;
        default:
          throw PlatformException(code: 'INVALID_COMMAND');
      }
      final result = <String, Object?>{
        ...controller.playbackTraceState(),
        'deviceSdk': DeviceUtils.sdkInt,
        'controlsVisible': controller.showControls.value,
        'fullscreen': controller.isFullScreen.value,
        'speed': controller.playbackSpeed,
        'durationMs':
            controller.videoPlayerController?.state.duration.inMilliseconds,
      };
      final player = controller.videoPlayerController;
      if (player != null) {
        final reader = MpvAsyncPropertyReader.native(player);
        const names = [
          'current-ao',
          'options/ao',
          'time-pos',
          'audio-pts',
          'video-pts',
          'seeking',
          'avsync',
          'pause',
        ];
        try {
          final values = await Future.wait(names.map(reader.read))
              .timeout(const Duration(milliseconds: 800));
          result['native'] = {
            for (var i = 0; i < names.length; i++) names[i]: values[i],
          };
        } catch (error) {
          result['nativeError'] = error.toString();
        } finally {
          reader.dispose();
        }
      }
      return result;
    });
  }
}
