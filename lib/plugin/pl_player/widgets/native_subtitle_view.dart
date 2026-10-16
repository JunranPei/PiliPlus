// This file is a part of media_kit (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'package:media_kit_video/media_kit_video.dart'
    show SubtitleViewConfiguration;

// {@template subtitle_view}
// NativeSubtitleView
// ------------
//
// [NativeSubtitleView] widget is used to display the subtitles on top of the [Video].
class NativeSubtitleView extends StatefulWidget {
  // The [VideoController] reference to control this [NativeSubtitleView] output.
  final PlatformPlayer controller;

  // The configuration to be used for the subtitles.
  final SubtitleViewConfiguration configuration;

  final bool enableDragSubtitle;

  final ValueChanged<EdgeInsets>? onUpdatePadding;

  // {@macro subtitle_view}
  const NativeSubtitleView({
    super.key,
    required this.controller,
    required this.configuration,
    this.enableDragSubtitle = false,
    this.onUpdatePadding,
  });

  @override
  NativeSubtitleViewState createState() => NativeSubtitleViewState();
}

class NativeSubtitleViewState extends State<NativeSubtitleView> {
  late Subtitle subtitle = widget.controller.state.subtitle;
  late EdgeInsets padding = widget.configuration.padding;
  late Duration duration = const Duration(milliseconds: 100);

  // The [StreamSubscription] to listen to the subtitle changes.
  StreamSubscription<Subtitle>? subscription;

  // The reference width for calculating the visible text scale factor.
  static const kTextScaleFactorReferenceWidth = 1920.0;
  // The reference height for calculating the visible text scale factor.
  static const kTextScaleFactorReferenceHeight = 1080.0;

  @override
  void initState() {
    subscription = widget.controller.stream.subtitle.listen((value) {
      setState(() {
        subtitle = value;
      });
    });
    super.initState();
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  // Sets the padding to be used for the subtitles.
  //
  // The [duration] argument may be specified to set the duration of the animation.
  void setPadding(
    EdgeInsets padding, {
    Duration duration = const Duration(milliseconds: 100),
  }) {
    if (this.duration != duration) {
      setState(() {
        this.duration = duration;
      });
    }
    setState(() {
      this.padding = padding;
    });
  }

  @override
  void didUpdateWidget(NativeSubtitleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    padding = widget.configuration.padding;
  }

  // {@macro subtitle_view}
  @override
  Widget build(BuildContext context) {
    Widget text(TextStyle style) => Text(
      subtitle.toString(),
      style: style,
      textAlign: widget.configuration.textAlign,
      textScaler: TextScaler.noScaling,
    );

    Widget subtitleView() {
      if (widget.configuration.strokeStyle != null) {
        return Stack(
          clipBehavior: Clip.none,
          children: [
            text(widget.configuration.strokeStyle!),
            text(widget.configuration.style),
          ],
        );
      }
      return text(widget.configuration.style);
    }

    return AnimatedContainer(
      margin: padding,
      duration: duration,
      alignment: Alignment.bottomCenter,
      child: widget.enableDragSubtitle
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) {
                double bottom = clampDouble(
                  padding.bottom - details.delta.dy,
                  0,
                  200,
                );
                padding = padding.copyWith(bottom: bottom);
                setState(() {});
              },
              onVerticalDragEnd: (details) {
                widget.onUpdatePadding?.call(padding);
              },
              child: subtitleView(),
            )
          : subtitleView(),
    );
  }
}
