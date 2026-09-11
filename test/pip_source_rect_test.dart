import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/pip_source_rect.dart';

void main() {
  Future<Rect?> measure(
    WidgetTester tester,
    Size contentSize, {
    BoxFit fit = BoxFit.contain,
  }) async {
    final viewport = GlobalKey();
    final content = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 24),
            child: SizedBox(
              key: viewport,
              width: 400,
              height: 225,
              child: FittedBox(
                fit: fit,
                child: SizedBox(
                  key: content,
                  width: contentSize.width,
                  height: contentSize.height,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return pipSourceRect(
      content.currentContext!.findRenderObject()! as RenderBox,
      viewport.currentContext!.findRenderObject()! as RenderBox,
      2,
    );
  }

  testWidgets('landscape hint includes fit transform and window offset', (
    tester,
  ) async {
    expect(
      await measure(tester, const Size(1920, 1080)),
      const Rect.fromLTWH(0, 48, 800, 450),
    );
  });

  testWidgets('portrait hint excludes horizontal letterboxing', (tester) async {
    final rect = (await measure(tester, const Size(1080, 1920)))!;
    expect(rect.top, 48);
    expect(rect.height, 450);
    expect(rect.width / rect.height, closeTo(9 / 16, 0.005));
    expect(rect.center.dx, 400);
  });

  testWidgets('cover fit intersects oversized video with viewport', (
    tester,
  ) async {
    expect(
      await measure(tester, const Size(1080, 1920), fit: BoxFit.cover),
      const Rect.fromLTWH(0, 48, 800, 450),
    );
  });

  testWidgets(
    'initial paint reports when early playback measurement was null',
    (tester) async {
      final key = GlobalKey();
      var reports = 0;
      expect(key.currentContext, isNull);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: PipSourceRectObserver(
            key: key,
            onPaint: () => reports++,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      );
      expect(reports, 1);
      await tester.pump();
      expect(reports, 1, reason: 'observer must not schedule a repaint loop');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(reports, 1);
    },
  );

  test('unmounted content cannot produce an entry hint', () {
    expect(pipSourceRect(null, null, 2), isNull);
  });
}
