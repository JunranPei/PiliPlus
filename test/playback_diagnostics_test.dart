import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/video_presentation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _ActiveTraceRegion extends SingleChildRenderObjectWidget {
  const _ActiveTraceRegion({required this.data, required super.child});

  final Map<String, Object?> Function() data;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderPlaybackTraceRegion(
        'active-test',
        data,
        View.of(context).devicePixelRatio,
        isRecording: () => true,
      );
}

class _PaintCounter extends CustomPainter {
  int count = 0;

  @override
  void paint(Canvas canvas, Size size) {
    count++;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.green);
  }

  @override
  bool shouldRepaint(covariant _PaintCounter oldDelegate) => false;
}

void main() {
  testWidgets(
    'presentation retains its unobserved baseline when trace is disabled',
    (tester) async {
      var metadataCalls = 0;
      var taps = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: VideoPresentation(
              width: 320,
              height: 180,
              player: const Texture(textureId: 9),
              poster: const ColoredBox(color: Colors.blue),
              showPoster: true,
              onPlay: () => taps++,
              traceData: () {
                metadataCalls++;
                throw StateError('metadata must not run outside capture');
              },
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        find.byType(PlaybackTraceRegion),
        PlaybackDiagnostics.enabled ? findsNWidgets(2) : findsNothing,
      );
      expect(metadataCalls, 0);
      expect(tester.getSize(find.byType(Texture)), const Size(320, 180));
      await tester.tapAt(const Offset(100, 100));
      expect(taps, 1);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(metadataCalls, 0);
    },
  );

  testWidgets(
    'observer preserves fitted transformed Texture geometry and layer',
    (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final regionKey = GlobalKey();

      Future<void> build({required bool observed}) => tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 20, top: 30),
              child: Transform.translate(
                offset: const Offset(7, 11),
                child: Transform.scale(
                  scale: 1.25,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 320,
                    height: 180,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: 1920,
                        height: 1080,
                        child: observed
                            ? PlaybackTraceRegion(
                                key: regionKey,
                                name: 'texture',
                                data: () => {'sourceGeneration': 7},
                                child: const Texture(textureId: 17),
                              )
                            : const Texture(textureId: 17),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await build(observed: false);
      final originalTexture = tester.renderObject<TextureBox>(
        find.byType(Texture),
      );
      final originalRect = MatrixUtils.transformRect(
        originalTexture.getTransformTo(null),
        Offset.zero & originalTexture.size,
      );
      final originalLayers = tester.layers
          .map((layer) => layer.runtimeType)
          .toList();

      await build(observed: true);
      final region =
          regionKey.currentContext!.findRenderObject()!
              as RenderPlaybackTraceRegion;
      final texture = tester.renderObject<TextureBox>(find.byType(Texture));
      final snapshot = region.snapshot();
      final nodes = snapshot['nodes']! as List<Map<String, Object?>>;
      final textureNode = nodes.singleWhere((node) => node['textureId'] == 17);
      final observedRect = MatrixUtils.transformRect(
        texture.getTransformTo(null),
        Offset.zero & texture.size,
      );

      expect(observedRect, originalRect);
      expect(observedRect.left, closeTo(27, 0.00001));
      expect(observedRect.top, closeTo(41, 0.00001));
      expect(observedRect.width, closeTo(400, 0.00001));
      expect(observedRect.height, closeTo(225, 0.00001));
      expect(region.child, same(texture));
      expect(region.size, texture.size);
      expect(region.isRepaintBoundary, isFalse);
      expect(
        tester.layers.map((layer) => layer.runtimeType).toList(),
        originalLayers,
      );
      expect(snapshot['sourceGeneration'], 7);
      expect(
        textureNode['depth'],
        0,
        reason: 'include the immediate Texture child',
      );
      expect(textureNode['size'], [1920.0, 1080.0]);
      expect(textureNode['globalLogicalRect'], snapshot['globalLogicalRect']);
      expect(
        textureNode['flutterPhysicalRect'],
        snapshot['flutterPhysicalRect'],
      );
      expect(textureNode['freeze'], isFalse);
      expect(snapshot['truncated'], isFalse);
      final physical = snapshot['flutterPhysicalRect']! as List<double>;
      for (var index = 0; index < 4; index++) {
        final logical = (snapshot['globalLogicalRect']! as List<double>)[index];
        expect(physical[index], closeTo(logical * 2, 0.00001));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a transparent observer preserves child taps without a frame loop',
    (
      tester,
    ) async {
      var taps = 0;
      var metadataCalls = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 160,
              height: 90,
              child: PlaybackTraceRegion(
                name: 'input',
                data: () {
                  metadataCalls++;
                  throw StateError('capture is inactive');
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                  child: const ColoredBox(color: Colors.green),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(PlaybackTraceRegion));
      expect(taps, 1);
      expect(metadataCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('throwing diagnostic metadata cannot stop attachment or paint', (
    tester,
  ) async {
    var metadataCalls = 0;
    final painter = _PaintCounter();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 160,
            height: 90,
            child: _ActiveTraceRegion(
              data: () {
                metadataCalls++;
                throw StateError('deliberate diagnostic failure');
              },
              child: CustomPaint(painter: painter),
            ),
          ),
        ),
      ),
    );
    final region = tester.renderObject<RenderPlaybackTraceRegion>(
      find.byType(_ActiveTraceRegion),
    );
    expect(region.attached, isTrue);
    expect(region.size, const Size(160, 90));
    expect(metadataCalls, greaterThanOrEqualTo(2));
    expect(
      painter.count,
      1,
      reason: 'child paint happens despite metadata errors',
    );
    expect(tester.takeException(), isNull);

    final callsAfterFirstFrame = metadataCalls;
    region.markNeedsPaint();
    await tester.pump();
    expect(painter.count, 2);
    expect(metadataCalls, greaterThan(callsAfterFirstFrame));
    expect(tester.takeException(), isNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(region.attached, isFalse);
    expect(tester.takeException(), isNull);
  });
}
