import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/android_pip_controller.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/pip_viewport.dart';

class _Page extends StatefulWidget {
  const _Page({required this.videoKey});
  final Key videoKey;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  late Size layoutSize;
  late Size mediaSize;
  int disposeCount = 0;

  @override
  void dispose() {
    disposeCount++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    mediaSize = MediaQuery.sizeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        layoutSize = constraints.biggest;
        return Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.red)),
            Positioned(
              left: 0,
              top: 24,
              width: 400,
              height: 225,
              child: ColoredBox(key: widget.videoKey, color: Colors.green),
            ),
          ],
        );
      },
    );
  }
}

void main() {
  testWidgets(
    'portrait crop excludes the rest of the page even in a wide window',
    (tester) async {
      const videoKey = ValueKey('portrait');
      const page = Size(400, 900);
      const video = Rect.fromLTWH(80, 24, 240, 426);
      final child = Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Colors.red)),
          Positioned.fromRect(
            rect: video,
            child: const ColoredBox(key: videoKey, color: Colors.green),
          ),
        ],
      );
      Future<void> show(AndroidPipPhase phase, Size window) =>
          tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox.fromSize(
                  size: window,
                  child: MediaQuery(
                    data: MediaQueryData(size: window, devicePixelRatio: 3),
                    child: PipViewport(
                      phase: phase,
                      sourceRect: const Rect.fromLTWH(240, 72, 720, 1278),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          );
      await tester.binding.setSurfaceSize(page);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await show(AndroidPipPhase.idle, page);
      await show(AndroidPipPhase.entering, page);
      await show(AndroidPipPhase.active, const Size(200, 213));
      expect(
        tester.getRect(find.byKey(videoKey)),
        const Rect.fromLTWH(40, 0, 120, 213),
      );
      final clip = tester.renderObject<RenderClipRect>(
        find.byType(ClipRect).last,
      );
      expect(clip.clipper!.getClip(page), video);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'entry, PiP resize and exit retain page state and source layout',
    (tester) async {
      const videoKey = ValueKey('video');
      const source = Size(400, 900);
      const rect = Rect.fromLTWH(0, 48, 800, 450);
      Future<void> show(AndroidPipPhase phase, Size window) =>
          tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox.fromSize(
                  size: window,
                  child: MediaQuery(
                    data: MediaQueryData(size: window, devicePixelRatio: 2),
                    child: PipViewport(
                      phase: phase,
                      sourceRect: rect,
                      child: const _Page(videoKey: videoKey),
                    ),
                  ),
                ),
              ),
            ),
          );
      await tester.binding.setSurfaceSize(source);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await show(AndroidPipPhase.idle, source);
      final state = tester.state<_PageState>(find.byType(_Page));
      await show(AndroidPipPhase.entering, source);
      expect(
        tester.getRect(find.byKey(videoKey)),
        const Rect.fromLTWH(0, 24, 400, 225),
      );
      // Insets/metrics may change before the native entry animation commits.
      // Do not move the source while Android is still cropping it.
      await show(AndroidPipPhase.entering, const Size(400, 880));
      expect(
        tester.getRect(find.byKey(videoKey)),
        const Rect.fromLTWH(0, 24, 400, 225),
      );
      // Android can commit the PiP surface size before its mode-change
      // callback reaches Dart. The first small frame must already show the
      // entire video, and receiving `active` must not move it again.
      const destination = Size(200, 112.5);
      await show(AndroidPipPhase.idle, destination);
      expect(tester.getRect(find.byKey(videoKey)), Offset.zero & destination);
      expect(tester.state(find.byType(_Page)), same(state));
      expect(state.layoutSize, source);
      await show(AndroidPipPhase.active, destination);
      expect(tester.getRect(find.byKey(videoKey)), Offset.zero & destination);
      for (final size in [const Size(200, 112.5), const Size(280, 157.5)]) {
        await show(AndroidPipPhase.active, size);
        expect(tester.state(find.byType(_Page)), same(state));
        expect(state.disposeCount, 0);
        expect(state.layoutSize, source);
        expect(state.mediaSize, source);
        expect(tester.getRect(find.byKey(videoKey)), Offset.zero & size);
      }
      await show(AndroidPipPhase.idle, source);
      expect(tester.state(find.byType(_Page)), same(state));
      expect(
        tester.getRect(find.byKey(videoKey)),
        const Rect.fromLTWH(0, 24, 400, 225),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
