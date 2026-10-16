import 'dart:ui' as ui;

import 'package:PiliPlus/plugin/pl_player/media3_player.dart';
import 'package:PiliPlus/plugin/pl_player/media3_texture.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/native_subtitle_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Test doubles exercise the original render widgets without loading mpv.
class _OriginalPlayer extends Fake implements NativePlayer {
  _OriginalPlayer(this.native);
  final Media3Player native;
  @override
  PlayerState get state => native.state;
  @override
  PlayerStream get stream => native.stream;
}

class _OriginalVideo extends VideoController {
  _OriginalVideo(Media3Player native)
    : super(_OriginalPlayer(native), const VideoControllerConfiguration()) {
    id.value = native.textureId.value;
    rect.value = native.rect.value;
  }
  @override
  Future<void>? setSize({int? width, int? height}) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.personal.piliplus/media3');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return call.method == 'create' ? {'textureId': 42} : null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final viewport in [const Size(360, 220), const Size(800, 450)]) {
    for (final aspect in <double?>[null, 4 / 3, 16 / 9]) {
      testWidgets('original texture geometry $viewport aspect=$aspect', (
        tester,
      ) async {
        final native = await Media3Player.create();
        native.state.width = 1920;
        native.state.height = 1080;
        native.rect.value = const Rect.fromLTWH(0, 0, 1920, 1080);
        final original = _OriginalVideo(native);
        Future<Rect> bounds(Widget child) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: SizedBox(
                  width: viewport.width,
                  height: viewport.height,
                  child: FittedBox(child: child),
                ),
              ),
            ),
          );
          await tester.pump();
          return tester.getRect(find.byType(Texture));
        }

        final before = await bounds(
          SimpleVideo(controller: original, aspectRatio: aspect),
        );
        final after = await bounds(
          Media3Texture(controller: native, aspectRatio: aspect),
        );
        expect(after, before);
        await tester.pumpWidget(const SizedBox());
        await native.dispose();
        original.id.dispose();
        original.rect.dispose();
      });
    }
    testWidgets('original subtitle pixels $viewport', (tester) async {
      final native = await Media3Player.create();
      native.state.subtitle = const Subtitle.raw('Subtitle one\nSubtitle two');
      final original = _OriginalVideo(native);
      final boundary = GlobalKey();
      const configuration = SubtitleViewConfiguration(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
        style: TextStyle(fontSize: 24, color: Colors.white),
      );
      Future<List<int>> pixels(Widget child) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: boundary,
                child: SizedBox(
                  width: viewport.width,
                  height: viewport.height,
                  child: ColoredBox(color: Colors.black, child: child),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return (await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return bytes!.buffer.asUint8List();
        }))!;
      }

      final before = await pixels(
        SubtitleView(controller: original, configuration: configuration),
      );
      final after = await pixels(
        NativeSubtitleView(controller: native, configuration: configuration),
      );
      expect(after, orderedEquals(before));
      await tester.pumpWidget(const SizedBox());
      await native.dispose();
      original.id.dispose();
      original.rect.dispose();
    });
  }
}
