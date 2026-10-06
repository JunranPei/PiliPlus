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
  late MediaQueryData mediaData;
  int disposeCount = 0;

  @override
  void dispose() {
    disposeCount++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    isPipWindow = PipWindowScope.of(context);
    mediaData = MediaQuery.of(context);
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
  testWidgets('native root lock retains player state and original insets', (tester) async {
    const full = Size(400, 900);
    const videoKey = ValueKey('native-root-video');
    await tester.binding.setSurfaceSize(full);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Future<void> show(AndroidPipPhase phase, bool locked, double inset) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(
            size: full, devicePixelRatio: 2,
            padding: EdgeInsets.only(top: inset),
            viewPadding: EdgeInsets.only(top: inset),
          ),
          child: PipViewport(
            phase: phase, nativeRootLocked: locked,
            sourceRect: const Rect.fromLTWH(0, 48, 800, 450),
            child: const _Probe(videoKey: videoKey),
          ),
        ),
      ),
    );
    await show(AndroidPipPhase.idle, false, 24);
    final state = tester.state<_ProbeState>(find.byType(_Probe));
    for (final phase in [AndroidPipPhase.entering, AndroidPipPhase.active, AndroidPipPhase.idle]) {
      await show(phase, true, 0);
      expect(tester.state<_ProbeState>(find.byType(_Probe)), same(state));
      expect(state.disposeCount, 0);
      expect(state.layoutSize, full);
      expect(state.mediaData.padding.top, 24);
      expect(state.isPipWindow, false);
      expect(tester.widget<IgnorePointer>(find.byType(IgnorePointer)).ignoring, true);
    }
    await show(AndroidPipPhase.idle, false, 24);
    expect(tester.state<_ProbeState>(find.byType(_Probe)), same(state));
    expect(tester.widget<IgnorePointer>(find.byType(IgnorePointer)).ignoring, false);
    expect(state.disposeCount, 0);
    expect(tester.takeException(), isNull);
  });

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

      // ACTIVE can precede the actual Activity resize. It must not produce a
      // fullscreen PiP-only frame between the normal page and small window.
      await show(AndroidPipPhase.active, fullWindow);
      expect(tester.state<_ProbeState>(find.byType(_Probe)), same(state));
      expect(state.isPipWindow, isFalse);
      expect(state.layoutSize, fullWindow);

      const pipWindow = Size(200, 213);
      await show(AndroidPipPhase.active, pipWindow);
      expect(tester.state<_ProbeState>(find.byType(_Probe)), same(state));
      expect(state.isPipWindow, isTrue);
      expect(state.mediaSize, pipWindow);
      expect(state.layoutSize, pipWindow);
      expect(tester.getRect(find.byKey(videoKey)), Offset.zero & pipWindow);
      expect(state.disposeCount, 0);

      // Android reports PiP exit before the Activity has grown back. The
      // video-only layout must survive that intermediate small window.
      await show(AndroidPipPhase.idle, pipWindow);
      expect(tester.state<_ProbeState>(find.byType(_Probe)), same(state));
      expect(state.isPipWindow, isTrue);
      expect(state.mediaSize, pipWindow);
      expect(state.layoutSize, pipWindow);
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

      await show(AndroidPipPhase.entering, pipWindow);
      expect(state.isPipWindow, isFalse);
      expect(tester.state<_ProbeState>(find.byType(_Probe)), same(state));

      await show(AndroidPipPhase.active, pipWindow);
      expect(tester.state<_ProbeState>(find.byType(_Probe)), same(state));
      expect(state.isPipWindow, isTrue);
      expect(state.layoutSize, pipWindow);
      expect(state.disposeCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('PiP preserves insets and releases layout on rotated exit', (
    tester,
  ) async {
    const videoKey = ValueKey('rotated-video');
    const landscape = Size(900, 400);
    const portrait = Size(400, 900);
    const pipWindow = Size(228, 128);
    const insets = EdgeInsets.fromLTRB(0, 24, 0, 20);

    Future<void> show(AndroidPipPhase phase, Size window) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: window,
            child: MediaQuery(
              data: MediaQueryData(
                size: window,
                padding: insets,
                viewPadding: insets,
                viewInsets: const EdgeInsets.only(bottom: 100),
              ),
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

    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await show(AndroidPipPhase.idle, landscape);
    final state = tester.state<_ProbeState>(find.byType(_Probe));
    await show(AndroidPipPhase.entering, landscape);
    await show(AndroidPipPhase.entering, pipWindow);
    expect(state.isPipWindow, isFalse);
    await show(AndroidPipPhase.active, pipWindow);
    expect(state.isPipWindow, isTrue);
    expect(state.mediaData.padding, insets);
    expect(state.mediaData.viewPadding, insets);
    expect(state.mediaData.viewInsets.bottom, 100);
    await show(AndroidPipPhase.idle, pipWindow);
    expect(state.isPipWindow, isTrue);
    // One axis grows first: don't expose the detail page at partial bounds.
    await show(AndroidPipPhase.idle, const Size(400, 300));
    expect(state.isPipWindow, isTrue);
    await show(AndroidPipPhase.idle, portrait);
    expect(state.isPipWindow, isFalse);
    expect(state.mediaData.padding, insets);
    expect(state.mediaData.viewPadding, insets);
    expect(state.mediaData.viewInsets.bottom, 100);
    expect(tester.state<_ProbeState>(find.byType(_Probe)), same(state));
    expect(state.disposeCount, 0);
    expect(
      tester.widget<IgnorePointer>(find.byType(IgnorePointer)).ignoring,
      isFalse,
    );
    // A cancelled entry does not leave interaction or PiP layout armed.
    await show(AndroidPipPhase.entering, portrait);
    await show(AndroidPipPhase.idle, portrait);
    expect(state.isPipWindow, isFalse);
    expect(
      tester.widget<IgnorePointer>(find.byType(IgnorePointer)).ignoring,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}
