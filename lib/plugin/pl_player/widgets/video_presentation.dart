import 'package:flutter/material.dart';

/// Keeps the playback surface mounted while a cover conceals an unready video.
///
/// Supply the same player type and key throughout loading and cover changes.
/// Only the cover changes visibility; the player's layout and painting remain
/// active so it can produce its first frame behind the cover.
class VideoPresentation extends StatelessWidget {
  const VideoPresentation({
    super.key,
    required this.width,
    required this.height,
    required this.player,
    required this.poster,
    required this.showPoster,
    this.loading = false,
    this.onPlay,
  });

  final double width;
  final double height;
  final Widget? player;
  final Widget poster;
  final bool showPoster;
  final bool loading;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          key: const ValueKey('video-presentation-player'),
          child: player ?? const SizedBox.shrink(),
        ),
        Positioned.fill(
          key: const ValueKey('video-presentation-poster'),
          child: IgnorePointer(
            ignoring: !showPoster,
            child: ExcludeSemantics(
              excluding: !showPoster,
              child: Opacity(
                opacity: showPoster ? 1 : 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Preparation may have started paused. Preserve the user's
                  // play intent and let the controller coalesce requests.
                  onTap: showPoster ? onPlay : null,
                  child: ColoredBox(
                    color: Colors.black,
                    child: poster,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (showPoster && loading)
          const Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
