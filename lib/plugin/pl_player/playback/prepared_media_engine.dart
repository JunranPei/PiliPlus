import 'dart:convert' show utf8;

import 'package:PiliPlus/plugin/pl_player/playback/mpv_frame_gate.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

String dashMediaUri(
  String video,
  String audio, {
  required bool uncut,
  bool fileSource = false,
}) {
  final header = uncut ? '!no_chapters;!no_clip;' : '!no_chapters;';
  return 'edl://$header'
      '%${fileSource ? utf8.encode(video).length : video.length}%$video;'
      '!new_stream;$header'
      '%${fileSource ? utf8.encode(audio).length : audio.length}%$audio';
}

class PreparedMediaEngine {
  PreparedMediaEngine({
    required this.player,
    required this.video,
    required this.media,
    required this.settings,
    this.start = Duration.zero,
    this.frameGate,
    required Map<String, String> extras,
  }) : extras = Map.unmodifiable(extras);

  final Player player;
  final VideoController video;
  final String media;
  final String settings;
  final Duration start;
  final MpvFrameGate? frameGate;
  final Map<String, String> extras;

  Map<String, bool> matchReport(
    String media,
    String settings,
    Map<String, String> extras, {
    Duration start = Duration.zero,
  }) {
    final report = {
      'mediaMatches': this.media == media,
      'settingsMatch': this.settings == settings,
      'extrasMatch': mapEquals(this.extras, extras),
      'notPlaying': !player.state.playing,
      'startPositionMatches': this.start == start,
      // open() acknowledges the queued load before its precise seek finishes.
      // The immutable start and lease key bind that pending seek to this load.
      'positionMatches':
          player.state.position == Duration.zero ||
          (start > Duration.zero &&
              (player.state.position - start).abs() <=
                  const Duration(milliseconds: 250)),
      'nativePaused': false,
      'nativeLoaded': false,
      'nativePathMatches': false,
    };
    try {
      report['nativePaused'] = player.getProperty('pause') == 'yes';
      report['nativeLoaded'] = player.getProperty('idle-active') != 'yes';
      report['nativePathMatches'] =
          player.getProperty('path') == Media(media).uri;
    } catch (_) {}
    return report;
  }

  Future<void> dispose() {
    frameGate?.dispose();
    return player.dispose();
  }
}
