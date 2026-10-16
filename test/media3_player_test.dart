import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/media3_player.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.personal.piliplus/media3');
  const codec = StandardMethodCodec();
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> native(String method, Map<String, Object?> data) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, data)),
      (_) => done.complete(),
    );
    await done.future;
    await Future<void>.delayed(Duration.zero);
  }

  Map<String, Object?> state(
    Media3Player player,
    int sourceId, {
    bool playing = true,
    bool buffering = false,
    int position = 4500,
  }) => {
    'playerId': player.playerId,
    'sourceId': sourceId,
    'positionMs': position,
    'durationMs': 120000,
    'bufferedPositionMs': 30000,
    'playWhenReady': playing,
    'buffering': buffering,
    'ended': false,
    'speed': 1.0,
    'width': 1920,
    'height': 1080,
  };

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'create') return {'textureId': 42};
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'opening a source applies startup options in one native request',
    () async {
      final player = await Media3Player.create();
      await player.openSource(
        NetworkSource(
          videoSource: 'https://example.com/audio.mp4',
          audioSource: null,
        ),
        volume: 65,
        videoEnabled: false,
        rate: 1.25,
      );
      expect(calls.map((call) => call.method), ['create', 'open']);
      final options = calls.last.arguments as Map;
      expect(options['volume'], .65);
      expect(options['videoEnabled'], isFalse);
      expect(options['speed'], 1.25);
      expect(options['play'], isFalse);
      expect(player.state.volume, 65);
      expect(player.state.rate, 1.25);
      await player.dispose();
    },
  );

  test(
    'native failure releases the first frame wait immediately',
    () async {
      final player = await Media3Player.create();
      await player.openSource(
        NetworkSource(
          videoSource: 'https://example.com/fail.mp4',
          audioSource: null,
        ),
      );
      final failure = expectLater(player.firstFrame, throwsStateError);
      await native('error', {
        'playerId': player.playerId,
        'sourceId': 1,
        'code': 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED',
        'message': 'Network failed',
      });
      await failure;
      await player.dispose();
    },
  );

  test(
    'external captions follow seek without reopening or pausing the source',
    () async {
      final player = await Media3Player.create();
      await player.openSource(
        NetworkSource(
          videoSource: 'https://example.com/video.mp4',
          audioSource: null,
        ),
      );
      await player.play();
      await player.setSubtitleTrack(
        const SubtitleTrack.uri(
          'memory://'
          'WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nFirst caption\n\n'
          '00:00:04.000 --> 00:00:06.000\nSecond caption\n',
        ),
      );
      await native('state', state(player, 1, position: 2000));
      expect(player.state.subtitle.toString(), 'First caption');
      await native('state', state(player, 1, position: 5000));
      expect(player.state.subtitle.toString(), 'Second caption');
      await native('state', state(player, 1, position: 7000));
      expect(player.state.subtitle.toString(), isEmpty);
      await player.setSubtitleTrack(SubtitleTrack.no());
      await native('state', state(player, 1, position: 2000));
      expect(player.state.subtitle.toString(), isEmpty);
      expect(calls.where((call) => call.method == 'open').length, 1);
      expect(calls.where((call) => call.method == 'pause'), isEmpty);
      await player.dispose();
    },
  );

  test(
    'buffering preserves play intent and never sends a pause command',
    () async {
      final player = await Media3Player.create();
      await player.openSource(
        NetworkSource(
          videoSource: 'https://example.com/video.mp4',
          audioSource: null,
        ),
      );
      await player.play();
      final playing = <bool>[];
      final subscription = player.stream.playing.listen(playing.add);
      await native('state', state(player, 1));
      await native('state', state(player, 1, buffering: true, position: 4700));
      expect(player.state.playing, isTrue);
      expect(player.state.buffering, isTrue);
      expect(player.state.position.inMilliseconds, 4700);
      expect(player.state.buffer.inMilliseconds, 30000);
      expect(calls.where((call) => call.method == 'pause'), isEmpty);
      expect(playing, [true]);
      await subscription.cancel();
      await player.dispose();
    },
  );

  test(
    'obsolete source events cannot reveal or change the next video',
    () async {
      final player = await Media3Player.create();
      await player.openSource(
        NetworkSource(
          videoSource: 'https://example.com/first.mp4',
          audioSource: null,
        ),
      );
      await player.openSource(
        NetworkSource(
          videoSource: 'https://example.com/next.mp4',
          audioSource: null,
        ),
      );
      var revealed = false;
      unawaited(player.firstFrame.then((_) => revealed = true));
      await native('state', state(player, 1, position: 80000));
      await native('firstFrame', {'playerId': player.playerId, 'sourceId': 1});
      expect(player.state.position, Duration.zero);
      expect(revealed, isFalse);
      await native('state', state(player, 2));
      await native('firstFrame', {'playerId': player.playerId, 'sourceId': 2});
      expect(revealed, isTrue);
      expect(player.rect.value?.width, 1920);
      await player.dispose();
    },
  );

  test(
    'original UI commands reach the native player with precise seek position',
    () async {
      final player = await Media3Player.create();
      await player.openSource(
        NetworkSource(
          videoSource: 'https://example.com/video.mp4',
          audioSource: null,
        ),
        seekTo: const Duration(milliseconds: 12345),
      );
      await player.seek(const Duration(milliseconds: 67890));
      await player.setRate(1.5);
      await player.pause();
      await player.play();
      expect(calls.map((call) => call.method), [
        'create',
        'open',
        'seek',
        'setSpeed',
        'pause',
        'play',
      ]);
      expect((calls[1].arguments as Map)['positionMs'], 12345);
      expect((calls[2].arguments as Map)['positionMs'], 67890);
      expect((calls[3].arguments as Map)['speed'], 1.5);
      await player.dispose();
    },
  );
}
