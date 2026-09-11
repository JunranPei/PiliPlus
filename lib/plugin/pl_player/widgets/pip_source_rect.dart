import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The transformed, visible video bounds in Android window pixels.
/// Measuring only localToGlobal(Offset.zero) loses FittedBox/zoom scaling.
Rect? pipSourceRect(RenderBox? video, RenderBox? viewport, double pixelRatio) {
  if (video == null ||
      viewport == null ||
      !video.attached ||
      !viewport.attached ||
      !video.hasSize ||
      !viewport.hasSize ||
      pixelRatio <= 0) {
    return null;
  }
  final content = MatrixUtils.transformRect(
    video.getTransformTo(null),
    Offset.zero & video.size,
  );
  final clip = MatrixUtils.transformRect(
    viewport.getTransformTo(null),
    Offset.zero & viewport.size,
  );
  final visible = content.intersect(clip);
  if (!visible.isFinite || visible.isEmpty) return null;
  return Rect.fromLTRB(
    (visible.left * pixelRatio).ceilToDouble(),
    (visible.top * pixelRatio).ceilToDouble(),
    (visible.right * pixelRatio).floorToDouble(),
    (visible.bottom * pixelRatio).floorToDouble(),
  );
}

/// Reports after layout/paint, including the initial frame after playback was
/// armed. No timer and no setState loop; native updates are deduplicated by the
/// owner. Place inside FittedBox so the measurement includes its transform.
class PipSourceRectObserver extends SingleChildRenderObjectWidget {
  const PipSourceRectObserver({
    super.key,
    required this.onPaint,
    required super.child,
  });

  final VoidCallback onPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _PipSourceRectObserver(onPaint);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderProxyBox renderObject,
  ) {
    (renderObject as _PipSourceRectObserver).onPaint = onPaint;
  }
}

class _PipSourceRectObserver extends RenderProxyBox {
  _PipSourceRectObserver(this.onPaint);
  VoidCallback onPaint;
  bool _pending = false;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (_pending) return;
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (attached) onPaint();
    });
  }
}
