import 'dart:convert';
import 'dart:ui' as ui;

import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

/// One bounded preparation of the small text/icon atlas used by the video page.
/// Does not mount a player, change navigation, or retain/read image pixels.
abstract final class StartupTextWarmup {
  static const enabled =
      bool.fromEnvironment('STARTUP_TEXT_WARMUP') ||
      bool.fromEnvironment('STARTUP_ACTION_TEXT_WARMUP');
  static bool _started = false;

  static Future<void> prepare(
    BuildContext context, {
    required bool Function() stillCurrent,
  }) async {
    if (_started || !stillCurrent()) return;
    _started = true;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final scaler = MediaQuery.textScalerOf(context);
    final theme = Theme.of(context);
    final samples = <({String name, String text, TextStyle style, bool icon})>[
      if (const bool.fromEnvironment('STARTUP_ACTION_TEXT_WARMUP')) ...[
        for (final item in [
          (name: 'action_like', data: FontAwesomeIcons.thumbsUp),
          (name: 'action_dislike', data: FontAwesomeIcons.thumbsDown),
          (name: 'action_coin', data: FontAwesomeIcons.b),
          (name: 'action_favorite', data: FontAwesomeIcons.star),
          (name: 'action_later', data: FontAwesomeIcons.clock),
          (name: 'action_share', data: FontAwesomeIcons.shareFromSquare),
        ])
          (
            name: item.name,
            text: String.fromCharCode(item.data.codePoint),
            style: TextStyle(
              fontFamily: item.data.fontFamily,
              package: item.data.fontPackage,
              fontSize: 18,
              color: theme.colorScheme.outline,
            ),
            icon: true,
          ),
      ],
      if (const bool.fromEnvironment('STARTUP_TEXT_WARMUP')) ...[
        for (final item in [
          (name: 'dm_on', data: CustomIcons.dm_on),
          (name: 'dm_off', data: CustomIcons.dm_off),
        ])
          (
            name: item.name,
            text: String.fromCharCode(item.data.codePoint),
            style: TextStyle(
              fontFamily: item.data.fontFamily,
              package: item.data.fontPackage,
              fontSize: 22,
              color: Colors.white,
            ),
            icon: true,
          ),
        (
          name: 'video_tabs',
          text: '简介 评论',
          style:
              (TabBarTheme.of(context).labelStyle ??
                      theme.textTheme.titleSmall ??
                      const TextStyle())
                  .copyWith(fontSize: 13, color: Colors.white),
          icon: false,
        ),
        (
          name: 'danmaku_prompt',
          text: '发弹幕',
          style: (theme.textTheme.labelLarge ?? const TextStyle()).copyWith(
            fontSize: 12,
            color: Colors.white,
          ),
          icon: false,
        ),
      ],
    ];
    for (final sample in samples) {
      // Navigation/backgrounding cancels remaining work. An already submitted
      // raster request cannot be interrupted; its image is always released.
      if (!stillCurrent()) break;
      final watch = Stopwatch()..start();
      final recorder = ui.PictureRecorder();
      ui.Picture? picture;
      ui.Image? image;
      final painter = TextPainter(
        text: TextSpan(text: sample.text, style: sample.style),
        textDirection: TextDirection.ltr,
        textScaler: sample.icon ? TextScaler.noScaling : scaler,
      );
      try {
        final canvas = Canvas(recorder)..scale(ratio);
        painter
          ..layout(maxWidth: 240)
          ..paint(canvas, const Offset(4, 4));
        final layoutUs = watch.elapsedMicroseconds;
        picture = recorder.endRecording();
        image = await picture.toImage(
          (256 * ratio).ceil(),
          (64 * ratio).ceil(),
        );
        _record({
          'item': sample.name,
          'layoutUs': layoutUs,
          'rasterUs': watch.elapsedMicroseconds - layoutUs,
          'devicePixelRatio': ratio,
          'fontFamily': sample.style.fontFamily,
          'fontSize': sample.style.fontSize,
          'colorArgb': sample.style.color?.toARGB32(),
          'stillCurrent': stillCurrent(),
        });
      } catch (error) {
        _record({
          'item': sample.name,
          'errorType': error.runtimeType.toString(),
        });
      } finally {
        image?.dispose();
        picture?.dispose();
        if (recorder.isRecording) recorder.endRecording().dispose();
        painter.dispose();
      }
    }
  }

  static void _record(Map<String, Object?> values) {
    if (!PlaybackDiagnostics.enabled) return;
    // A first-home warmup can precede the current source's sparse trace arm.
    debugPrint(
      '[TEXT_WARMUP] ${DateTime.now().microsecondsSinceEpoch} '
      '${jsonEncode(values)}',
    );
    PlaybackDiagnostics.event('startup.textAtlas.ready', values);
  }
}
