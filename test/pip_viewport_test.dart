import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/android_pip_controller.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/pip_viewport.dart';

class _Probe extends StatefulWidget {
  const _Probe({required this.videoKey});

  final Key videoKey;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  late bool isPipWindow;
  late Size mediaSize;
  late Size layoutSize;
  int disposeCount = 0;

  @override
  void dispose() {
    disposeCount++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    isPipWindow = PipWindowScope.of(context);
    mediaSize = MediaQuery.sizeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        layoutSize = constraints.biggest;
        return ColoredBox(
          key: widget.videoKey,
          color: Colors.green,
        );
      },
    );
  }
}

void main() {
  testWidgets(
    'PiP keeps the existing video child and marks only the small window',
    (tester) async {
      const videoKey = ValueKey('video');
      const fullWindow = Size(400, 900);

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
                      sourceRect: const Rect.fromLTWH(0, 0, 800, 450),
                      child: const _Probe(videoKey: videoKey),
                    ),
                  ),
                ),
              ),
            ),
          );

      await tester.binding.setSurfaceSize(fullWindow);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await show(AndroidPipPhase.idle, fullWindow);
      final state = tester.state<_ProbeState>(find.byType(_Probe));
      expect(state.isPipWindow, isFalse);
      expect(state.mediaSize, fullWindow);
      expect(tester.getRect(find.byKey(videoKey)), Offset.zero & fullWindow);

      await show(AndroidPipPhase.entering, fullWindow);
      expect(tester.state<_ProbeState>(find.byType(_Probe)), same(state));
      expect(state.isPipWindow, isFalse);
      expect(state.disposeCount, 0);

      const pipWindow = Size(200, 213);
      await show(AndroidPipPhase.active, pipWindow);
      expect(tester.state<_ProbeState>(find.byType(_Probe)), same(state));
      expect(state.isPipWindow, isTrue);
      expect(state.mediaSize, pipWindow);
      expect(state.layoutSize, pipWindow);
      expect(tester.getRect(find.byKey(videoKey)), Offset.zero & pipWindow);
      expect(state.disposeCount, 0);

      await show(AndroidPipPhase.idle, fullWindow);
      expect(tester.state<_ProbeState>(find.byType(_Probe)), same(state));
      expect(state.isPipWindow, isFalse);
      expect(state.mediaSize, fullWindow);
      expect(state.layoutSize, fullWindow);
      expect(tester.getRect(find.byKey(videoKey)), Offset.zero & fullWindow);
      expect(state.disposeCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a resize before the native active callback keeps the page until PiP starts',
    (tester) async {
      const videoKey = ValueKey('resized-video');
      const fullWindow = Size(400, 900);
      const pipWindow = Size(200, 213);

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
                      sourceRect: null,
                      child: const _Probe(videoKey: videoKey),
                    ),
                  ),
                ),
              ),
            ),
          );

      await tester.binding.setSurfaceSize(fullWindow);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await show(AndroidPipPhase.idle, fullWindow);
      final state = tester.state<_ProbeState>(find.byType(_Probe));

      // The Activity can resize before Android reports that PiP has started.
      // Keep the original page during that system-owned animation.
      await show(AndroidPipPhase.idle, pipWindow);
      expect(tester.state<_ProbeState>(find.byType(_Probe)), same(state));
      expect(state.isPipWindow, isFalse);
      expect(state.layoutSize, pipWindow);
      expect(state.disposeCount, 0);

      await show(AndroidPipPhase.active, pipWindow);
      expect(tester.state<_ProbeState>(find.byType(_Probe)), same(state));
      expect(state.isPipWindow, isTrue);
      expect(state.layoutSize, pipWindow);
      expect(state.disposeCount, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
