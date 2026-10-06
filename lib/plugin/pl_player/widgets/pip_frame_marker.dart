import 'package:flutter/widgets.dart';

/// Native validates this row in the rendered buffer, then crops it away.
/// A Dart callback cannot establish that the right scene reached the consumer.
class PipFrameRequest {
  const PipFrameRequest({
    required this.epoch,
    required this.width,
    required this.height,
    required this.pip,
  });

  factory PipFrameRequest.fromMap(Map<dynamic, dynamic> value) =>
      PipFrameRequest(
        epoch: (value['epoch'] as num).toInt(),
        width: (value['width'] as num).toInt(),
        height: (value['height'] as num).toInt(),
        pip: value['pip'] as bool,
      );

  final int epoch;
  final int width;
  final int height;
  final bool pip;
}

class PipFrameMarker extends CustomPainter {
  const PipFrameMarker(this.epoch, this.pixelRatio);
  final int epoch;
  final double pixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..isAntiAlias = false;
    final colors = [0x19B76D, epoch, epoch ^ 0xFFFFFF];
    for (var index = 0; index < colors.length; index++) {
      paint.color = Color(0xFF000000 | colors[index]);
      canvas.drawRect(
        Rect.fromLTWH(
          index * 3 / pixelRatio,
          0,
          3 / pixelRatio,
          1 / pixelRatio,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(PipFrameMarker oldDelegate) =>
      epoch != oldDelegate.epoch || pixelRatio != oldDelegate.pixelRatio;
}
