import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class PlayOrPauseButton extends StatelessWidget {
  final PlPlayerController plPlayerController;

  const PlayOrPauseButton({
    super.key,
    required this.plPlayerController,
  });

  @override
  Widget build(BuildContext context) {
    return Obx(
      () {
        final isPlaying = plPlayerController.playerStatus.value.isPlaying;
        return SizedBox(
          width: 42,
          height: 34,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: plPlayerController.onDoubleTapCenter,
            child: Center(
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                semanticLabel: isPlaying ? '暂停' : '播放',
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        );
      },
    );
  }
}
