import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:media_kit_video/src/video_controller/video_controller.dart';

/// Displays Android playback through the platform's single native
/// [SurfaceView].  The view stays attached while the Activity enters PiP, so
/// Android resizes one surface instead of handing libmpv from one output to a
/// second output during the transition.
class NativeVideoView extends StatelessWidget {
  const NativeVideoView({super.key, required this.controller});

  final VideoController controller;

  static const viewType = 'com.alexmercerind/media_kit_video/native';

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    return PlatformViewLink(
      key: ValueKey('native-video-${controller.player.handle}'),
      viewType: viewType,
      surfaceFactory: (context, platformController) {
        return AndroidViewSurface(
          controller: platformController as AndroidViewController,
          gestureRecognizers:
              const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        );
      },
      onCreatePlatformView: (params) {
        final platformController =
            PlatformViewsService.initExpensiveAndroidView(
              id: params.id,
              viewType: viewType,
              layoutDirection: TextDirection.ltr,
              creationParams: <String, dynamic>{
                'handle': controller.player.handle.toString(),
              },
              creationParamsCodec: const StandardMessageCodec(),
              onFocus: () => params.onFocusChanged(true),
            )
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
              ..create();
        return platformController;
      },
    );
  }
}
