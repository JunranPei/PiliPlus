import 'package:flutter/widgets.dart';
import 'package:PiliPlus/plugin/pl_player/media3_player.dart';

/// The original SimpleVideo geometry with Media3 providing the Flutter texture.
class Media3Texture extends StatelessWidget {
  const Media3Texture({
    super.key,
    required this.controller,
    this.fill = const Color(0xff000000),
    this.aspectRatio,
  });

  final Media3Player controller;
  final Color fill;
  final double? aspectRatio;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller.textureId, controller.rect]),
    builder: (context, _) {
      final id = controller.textureId.value;
      final rect = controller.rect.value;
      if (id == null || rect == null || rect.width < 1 || rect.height < 1) {
        return const SizedBox.shrink();
      }
      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      return SizedBox(
        width: aspectRatio == null
            ? rect.width / pixelRatio
            : rect.height / pixelRatio * aspectRatio!,
        height: rect.height / pixelRatio,
        child: Stack(
          children: [
            Texture(textureId: id, filterQuality: FilterQuality.low),
            if (rect.width <= 1.0 && rect.height <= 1.0)
              Positioned.fill(child: ColoredBox(color: fill)),
          ],
        ),
      );
    },
  );
}
