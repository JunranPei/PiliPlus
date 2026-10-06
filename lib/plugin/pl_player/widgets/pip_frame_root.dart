import 'package:flutter/widgets.dart';
import 'package:PiliPlus/plugin/pl_player/android_pip_controller.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/pip_frame_marker.dart';

/// The verification row belongs to the root scene, never to a Navigator route.
/// Inactive routes can be laid out with zero bounds and must not resize it.
class PipFrameRoot extends StatelessWidget {
  const PipFrameRoot({super.key, required this.child, this.request});
  final Widget child;
  // Injected only by layout tests; production follows the native coordinator.
  final PipFrameRequest? request;

  @override
  Widget build(BuildContext context) {
    final pip = AndroidPipController.instance;
    return ListenableBuilder(
      listenable: pip,
      child: child,
      builder: (context, child) =>
          _layout(context, request ?? pip.frameRequest, child!),
    );
  }

  Widget _layout(BuildContext context, PipFrameRequest? target, Widget child) {
    final media = MediaQuery.of(context);
    final pixel = 1 / media.devicePixelRatio;
    final reserve = target == null ? 0.0 : pixel;
    final contentSize = Size(
      media.size.width,
      (media.size.height - reserve).clamp(0.0, double.infinity),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          bottom: reserve,
          child: MediaQuery(
            data: media.copyWith(size: contentSize),
            child: child,
          ),
        ),
        if (target != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: pixel,
            child: CustomPaint(
              painter: PipFrameMarker(target.epoch, media.devicePixelRatio),
            ),
          ),
      ],
    );
  }
}
