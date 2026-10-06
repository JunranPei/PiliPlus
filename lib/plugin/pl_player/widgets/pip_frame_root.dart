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
      builder: (context, child) => LayoutBuilder(
        builder: (context, constraints) =>
            _layout(context, request ?? pip.frameRequest, child!, constraints),
      ),
    );
  }

  Widget _layout(
    BuildContext context,
    PipFrameRequest? target,
    Widget child,
    BoxConstraints constraints,
  ) {
    final media = MediaQuery.of(context);
    final pixel = 1 / media.devicePixelRatio;
    final reserve = target == null ? 0.0 : pixel;
    // A matching native buffer does not prove that Flutter laid out a matching
    // scene. Window insets can temporarily restore full-window engine metrics.
    // Emit no valid acknowledgement for such a scene, even at the same epoch.
    final valid =
        target != null &&
        (media.size.width * media.devicePixelRatio).round() == target.width &&
        (media.size.height * media.devicePixelRatio).round() ==
            target.height + 1 &&
        (constraints.maxWidth * media.devicePixelRatio).round() ==
            target.width &&
        (constraints.maxHeight * media.devicePixelRatio).round() ==
            target.height + 1;
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
            child: ColoredBox(
              color: const Color(0xFF000000),
              child: valid
                  ? CustomPaint(
                      painter: PipFrameMarker(
                        target.epoch,
                        media.devicePixelRatio,
                      ),
                    )
                  : const SizedBox.expand(),
            ),
          ),
      ],
    );
  }
}
