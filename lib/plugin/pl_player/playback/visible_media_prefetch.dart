import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';
import 'package:PiliPlus/plugin/pl_player/playback/selected_media_warmup.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';

/// Prediction only: playback must match both exact URLs, headers and account
/// before taking a transport. A quality/codec mismatch always opens normally.
({VideoItem video, AudioItem audio})? predictWarmupTracks(
  PlayUrlModel model, {
  required int videoQuality,
  required int audioQuality,
  required List<VideoDecodeFormatType> codecs,
  bool allowResume = false,
}) {
  final videos = model.dash?.video;
  final audios = model.dash?.audio;
  final formats = model.supportFormats;
  if (videos == null ||
      videos.isEmpty ||
      audios == null ||
      audios.isEmpty ||
      formats == null ||
      formats.isEmpty ||
      (!allowResume && model.lastPlayTime > 0)) {
    return null;
  }
  final quality = model.findAvailableVideoQuality(videoQuality);
  final choices = videos.where((v) => v.quality.code == quality).toList();
  if (choices.isEmpty) {
    return null; // Required supplemental quality is not ready.
  }
  final supported = formats
      .firstWhere((v) => v.quality == quality, orElse: () => formats.first)
      .codecs;
  if (supported == null || supported.isEmpty) return null;
  final codec = VideoUtils.selectCodec(supported, codecs);
  final video = choices.firstWhere(
    (v) => v.codecs != null && codec.codes.any(v.codecs!.startsWith),
    orElse: () => choices.first,
  );
  final ids = audios.map((a) => a.id).toList();
  var audioId = ids.findClosestTarget(
    (a) => a <= audioQuality,
    (a, b) => a > b ? a : b,
  );
  if (!ids.contains(audioQuality) && ids.any((a) => a > audioQuality)) {
    audioId = AudioQuality.k192.code;
  }
  return (
    video: video,
    audio: audios.firstWhere(
      (a) => a.id == audioId,
      orElse: () => audios.first,
    ),
  );
}

void prefetchVisibleMedia(PlayUrlModel model, int cid) {
  if (!SelectedMediaWarmup.enabled || !Pref.autoPlayEnable) return;
  try {
    final tracks = predictWarmupTracks(
      model,
      videoQuality: Pref.defaultVideoQa,
      audioQuality: Pref.defaultAudioQa,
      codecs: Pref.preferCodecs,
      allowResume: const bool.fromEnvironment('VISIBLE_RESUME_PRELOAD'),
    );
    if (tracks == null) return;
    final video = VideoUtils.getCdnUrl(tracks.video.playUrls);
    final audio = VideoUtils.getCdnUrl(tracks.audio.playUrls, isAudio: true);
    if (![video, audio].every(
      (url) => const ['http', 'https'].contains(Uri.tryParse(url)?.scheme),
    )) {
      return;
    }
    final started = SelectedMediaWarmup.instance.start(
      scope: Accounts.video,
      video: video,
      audio: audio,
      headers: {'User-Agent': BrowserUa.pc, 'Referer': HttpString.baseUrl},
      start: Duration(milliseconds: model.lastPlayTime),
      videoAlternatives:
          const bool.fromEnvironment('HEDGE_MEDIA_SOURCE') &&
              VideoUtils.cdnService.host == null
          ? tracks.video.playUrls.toList()
          : const [],
      audioAlternatives:
          const bool.fromEnvironment('HEDGE_AUDIO_SOURCE') &&
              VideoUtils.cdnService.host == null
          ? tracks.audio.playUrls.toList()
          : const [],
      onEvent: (event, data) => PlaybackDiagnostics.event(
        'startup.mediaPrefetch.$event',
        {...data, 'cid': cid},
      ),
      prepareEngine: const bool.fromEnvironment('VISIBLE_NATIVE_PRELOAD')
          ? (lease) => PlPlayerController.prepareVisibleMedia(
              lease,
              volume: model.volume,
              cid: cid,
            )
          : null,
    );
    if (started) {
      PlaybackDiagnostics.event('startup.mediaPrefetch.begin', {
        'cid': cid,
        'quality': tracks.video.id,
        'codecs': tracks.video.codecs,
        'audioQuality': tracks.audio.id,
        'startMs': model.lastPlayTime,
        'unclaimedLifetimeMs': 8000,
      });
    }
  } catch (_) {
    SelectedMediaWarmup.instance.clear();
  }
}
