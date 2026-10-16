import 'package:PiliPlus/plugin/pl_player/widgets/video_presentation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _CounterPainter extends CustomPainter {
  int paints = 0;
  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.green);
  }

  @override
  bool shouldRepaint(covariant _CounterPainter oldDelegate) => false;
}

void main() {
  testWidgets(
    'covered overlay keeps its state and geometry without hiding video paint',
    (tester) async {
      final video = _CounterPainter();
      final overlay = _CounterPainter();
      final overlayKey = GlobalKey();
      Future<void> show(bool covered) => tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: VideoPresentation(
              width: 320,
              height: 180,
              showPoster: covered,
              poster: const ColoredBox(color: Colors.blue),
              player: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(painter: video),
                  VideoOverlayPaint(
                    visible: !covered,
                    child: StatefulBuilder(
                      key: overlayKey,
                      builder: (_, _) => CustomPaint(painter: overlay),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await show(true);
      final state = overlayKey.currentState;
      final bounds = tester.getRect(find.byKey(overlayKey));
      expect(state, isNotNull);
      expect(video.paints, greaterThan(0));
      expect(overlay.paints, 0);
      await show(false);
      expect(overlayKey.currentState, same(state));
      expect(tester.getRect(find.byKey(overlayKey)), bounds);
      expect(overlay.paints, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );
}
