import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/plugin/pl_player/playback/startup_stream_readiness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PlayUrlModel response({
    int quality = 80,
    String codec = 'hev1.1.6.L120.90',
    String? videoUrl = 'https://media.example/video.m4s',
    List<String>? videoBackups,
    int audioQuality = 30280,
    String? audioUrl = 'https://media.example/audio.m4s',
  }) => PlayUrlModel.fromJson({
    'dash': {
      'video': [
        {
          'id': quality,
          'base_url': videoUrl,
          'backup_url': videoBackups,
          'codecs': codec,
        },
      ],
      'audio': [
        {'id': audioQuality, 'base_url': audioUrl, 'codecs': 'mp4a.40.2'},
      ],
    },
    'support_formats': [
      {
        'quality': 80,
        'codecs': ['hev1', 'avc1'],
      },
      {
        'quality': 64,
        'codecs': ['hev1', 'avc1'],
      },
    ],
  });

  bool ready(PlayUrlModel model) => StartupStreamReadiness.hasSelectedTracks(
    model,
    videoQuality: 80,
    videoCodecPrefixes: ['hev1', 'hvc1'],
    audioQuality: 30280,
  );

  test(
    'unrelated missing qualities do not block selected complete streams',
    () {
      final model = response();
      expect(model.missingVideoQualityBelowHighest, 64);
      expect(ready(model), isTrue);
    },
  );

  test('a different available quality cannot replace the selected quality', () {
    expect(ready(response(quality: 120)), isFalse);
  });

  test('an available AVC stream cannot replace the selected HEVC stream', () {
    expect(ready(response(codec: 'avc1.640028')), isFalse);
  });

  test('a lower audio quality cannot stand in for the selected audio', () {
    expect(ready(response(audioQuality: 30216)), isFalse);
  });

  test('video metadata without a usable URL still requires discovery', () {
    expect(ready(response(videoUrl: null)), isFalse);
  });

  test('a supplied backup URL is sufficient for the existing CDN selector', () {
    expect(
      ready(
        response(videoUrl: null, videoBackups: ['https://media.example/v']),
      ),
      isTrue,
    );
  });

  test('audio metadata without a usable URL still requires discovery', () {
    expect(ready(response(audioUrl: null)), isFalse);
  });

  test('non DASH sources keep the existing preparation path', () {
    expect(ready(PlayUrlModel()), isFalse);
  });
}
