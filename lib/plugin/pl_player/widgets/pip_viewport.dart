import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:PiliPlus/plugin/pl_player/android_pip_controller.dart';

/// Keep the same page, Texture and layout mounted throughout Android's resize.
/// Only the visible viewport changes; no second player or PiP page is created.
class AndroidPipViewport extends StatelessWidget {
  const AndroidPipViewport({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return child;
    final pip = AndroidPipController.instance;
    return ListenableBuilder(
      listenable: pip,
      builder: (context, child) => PipViewport(
        phase: pip.phase,
        sourceRect: pip.sourceRect,
        child: child!,
      ),
      child: child,
    );
  }
}

/// [sourceRect] is in window pixels, as reported to Android sourceRectHint.
/// This widget must wrap the page, above its MediaQuery-dependent layout.
class PipViewport extends StatefulWidget {
  const PipViewport({
    super.key,
    required this.phase,
    required this.sourceRect,
    required this.child,
  });

  final AndroidPipPhase phase;
  final Rect? sourceRect;
  final Widget child;

  @override
  State<PipViewport> createState() => _PipViewportState();
}

class _PipViewportState extends State<PipViewport> {
  MediaQueryData? _sourceMedia;
  Size? _sourceSize;
  Rect? _entryRect;

  @override
  void didUpdateWidget(PipViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase == AndroidPipPhase.idle &&
        widget.phase != AndroidPipPhase.idle) {
      _entryRect = widget.sourceRect;
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final window = constraints.biggest;
        final source = _sourceSize;
        // Android can resize the Activity before the asynchronous native
        // phase callback reaches Dart. Keep the original page metrics in that
        // gap, otherwise the first PiP frame is laid out from the small
        // window's top-left corner and appears zoomed/cropped.
        final inferredPipResize =
            source != null &&
            window.width < source.width * 0.75 &&
            window.height < source.height * 0.75;
        final protecting =
            widget.phase != AndroidPipPhase.idle || inferredPipResize;
        if (!protecting || _sourceMedia == null) {
          _sourceMedia = media;
          _sourceSize = window;
          _entryRect = widget.sourceRect;
        }

        final sourceSize = _sourceSize!;
        final pixelRect = _entryRect;
        final transform = Matrix4.identity();
        Rect? crop;
        // During the native entry animation the full-size app is still the
        // source. Crop only when Android gives us the destination bounds.
        if (protecting &&
            pixelRect != null &&
            !pixelRect.isEmpty &&
            window.width < sourceSize.width * 0.75 &&
            window.height < sourceSize.height * 0.75) {
          final dpr = _sourceMedia!.devicePixelRatio;
          final rect = Rect.fromLTRB(
            pixelRect.left / dpr,
            pixelRect.top / dpr,
            pixelRect.right / dpr,
            pixelRect.bottom / dpr,
          );
          crop = rect;
          final scale = math.min(
            window.width / rect.width,
            window.height / rect.height,
          );
          transform
            ..setEntry(0, 0, scale)
            ..setEntry(1, 1, scale)
            ..setEntry(
              0,
              3,
              (window.width - rect.width * scale) / 2 - rect.left * scale,
            )
            ..setEntry(
              1,
              3,
              (window.height - rect.height * scale) / 2 - rect.top * scale,
            );
        }
        return ClipRect(
          child: ColoredBox(
            color: const Color(0xFF000000),
            child: Transform(
              transform: transform,
              alignment: Alignment.topLeft,
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: sourceSize.width,
                maxWidth: sourceSize.width,
                minHeight: sourceSize.height,
                maxHeight: sourceSize.height,
                child: ClipRect(
                  clipper: _VideoCrop(crop),
                  child: MediaQuery(
                    data: _sourceMedia!,
                    child: IgnorePointer(
                      ignoring: protecting,
                      child: widget.child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _VideoCrop extends CustomClipper<Rect> {
  const _VideoCrop(this.rect);
  final Rect? rect;

  @override
  Rect getClip(Size size) => rect ?? Offset.zero & size;

  @override
  bool shouldReclip(_VideoCrop oldClipper) => rect != oldClipper.rect;
}
