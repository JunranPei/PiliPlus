import 'package:PiliPlus/models/video/play/url.dart';

/// Background quality discovery is safe only when the selected streams exist.
abstract final class StartupStreamReadiness {
  static bool hasSelectedTracks(
    PlayUrlModel model, {
    required int videoQuality,
    required Iterable<String> videoCodecPrefixes,
    required int audioQuality,
  }) {
    final dash = model.dash;
    if (dash == null) return false;
    final hasVideo = dash.video?.any((item) {
      final codec = item.codecs;
      return item.id == videoQuality &&
          codec != null &&
          videoCodecPrefixes.any(codec.startsWith) &&
          item.playUrls.isNotEmpty;
    });
    final hasAudio = dash.audio?.any(
      (item) => item.id == audioQuality && item.playUrls.isNotEmpty,
    );
    return hasVideo == true && hasAudio == true;
  }
}
