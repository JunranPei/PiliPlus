import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/webvtt_cues.dart';

/// Media3 backend with the state/stream contract consumed by the existing UI.
/// No NativePlayer or mpv instance is constructed by this adapter.
class Media3Player extends PlatformPlayer {
  Media3Player._(this.playerId)
    : super(configuration: const PlayerConfiguration());

  static const _channel = MethodChannel('com.personal.piliplus/media3');
  static final Map<int, Media3Player> _players = {};
  static int _nextId = 0;
  static final Map<int, ValueChanged<double>> _exportProgress = {};
  static bool _listening = false;
  final int playerId;
  final ValueNotifier<int?> textureId = ValueNotifier(null);
  final ValueNotifier<ui.Rect?> rect = ValueNotifier(null);
  final List<Media> current = [];
  int _sourceId = 0;
  bool _disposed = false;
  final Map<String, String> _headers = {};
  List<WebVttCue>? _externalCues;
  bool _textDisabled = true;
  int _subtitleRevision = 0;
  Completer<void> _firstFrame = Completer<void>();
  Completer<String> _sourceFailure = Completer<String>();
  Future<void> get firstFrame => Future.any<void>([
    _firstFrame.future,
    _sourceFailure.future.then<void>((message) => throw StateError(message)),
  ]);

  static Future<Media3Player> create() async {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        final data = (call.arguments as Map?)?.cast<String, dynamic>();
        if (data == null) return;
        if (call.method == 'exportProgress') {
          _exportProgress[(data['exportId'] as num?)?.toInt()]?.call(
            (data['progress'] as num).toDouble(),
          );
          return;
        }
        _players[(data['playerId'] as num?)?.toInt()]?._event(
          call.method,
          data,
        );
      });
    }
    final player = Media3Player._(++_nextId);
    _players[player.playerId] = player;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('create', {
        'playerId': player.playerId,
      });
      player.textureId.value = (result?['textureId'] as num?)?.toInt();
      player.completer.complete();
      return player;
    } catch (_) {
      _players.remove(player.playerId);
      rethrow;
    }
  }

  Future<void> _command(
    String method, [
    Map<String, Object?> args = const {},
  ]) => _channel.invokeMethod<void>(method, {
    'playerId': playerId,
    'sourceId': _sourceId,
    ...args,
  });

  static Future<bool> exportWebp({
    required int id,
    required String url,
    required String outFile,
    required double start,
    required double duration,
    required String preset,
    required ValueChanged<double> onProgress,
  }) async {
    _exportProgress[id] = onProgress;
    try {
      return await _channel.invokeMethod<bool>('exportWebp', {
            'exportId': id,
            'url': url,
            'outFile': outFile,
            'startMs': (start * 1000).round(),
            'durationMs': (duration * 1000).round(),
            'preset': preset,
          }) ??
          false;
    } finally {
      _exportProgress.remove(id);
    }
  }

  static void cancelExport(int id) {
    unawaited(_channel.invokeMethod<void>('cancelExport', {'exportId': id}));
  }

  Future<void> openSource(
    DataSource source, {
    Duration? seekTo,
    double? volume,
    bool? videoEnabled,
    double? rate,
  }) async {
    if (volume != null) state.volume = volume;
    if (rate != null) state.rate = rate;
    await _open({
      if (source is NetworkSource) ...?source.nativeMetadata,
      'videoUrl': source.videoSource,
      'audioUrl': source.audioSource,
      'positionMs': seekTo?.inMilliseconds ?? 0,
      if (volume != null) 'volume': volume / 100,
      if (videoEnabled != null) 'videoEnabled': videoEnabled,
      if (rate != null) 'speed': rate,
    }, play: false);
  }

  Future<void> _open(Map<String, Object?> args, {required bool play}) async {
    _sourceId++;
    _subtitleRevision++;
    _externalCues = null;
    _textDisabled = true;
    if (!_firstFrame.isCompleted) _firstFrame.complete();
    _firstFrame = Completer<void>();
    _sourceFailure = Completer<String>();
    state
      ..position = Duration(milliseconds: (args['positionMs'] as int?) ?? 0)
      ..duration = Duration(milliseconds: (args['durationMs'] as int?) ?? 0)
      ..buffer = Duration.zero
      ..completed = false
      ..playing = false
      ..buffering = true
      ..subtitle = const Subtitle.raw();
    current
      ..clear()
      ..add(Media(args['videoUrl'] as String));
    state.playlist = Playlist(current.toList());
    playlistController.add(state.playlist);
    playingController.add(false);
    completedController.add(false);
    bufferingController.add(true);
    subtitleController.add(state.subtitle);
    await _command('open', {...args, 'headers': _headers, 'play': play});
  }

  void _event(String type, Map<String, dynamic> data) {
    if (_disposed || (data['sourceId'] as num?)?.toInt() != _sourceId) return;
    if (type == 'firstFrame') {
      if (!_firstFrame.isCompleted) _firstFrame.complete();
      return;
    }
    if (type == 'error') {
      final message = '${data['code']}: ${data['message']}';
      if (!_sourceFailure.isCompleted) _sourceFailure.complete(message);
      errorController.add(message);
      return;
    }
    if (type == 'subtitle') {
      if (_externalCues != null || _textDisabled) return;
      state.subtitle = Subtitle.raw(data['text'] as String? ?? '');
      subtitleController.add(state.subtitle);
      return;
    }
    if (type != 'state') return;
    final wasPlaying = state.playing;
    final wasCompleted = state.completed;
    final wasBuffering = state.buffering;
    final previousDuration = state.duration;
    final previousSize = (state.width, state.height);
    state
      ..playing = data['playWhenReady'] == true && data['ended'] != true
      ..completed = data['ended'] == true
      ..buffering = data['buffering'] == true
      ..position = Duration(milliseconds: (data['positionMs'] as num).toInt())
      ..duration = Duration(milliseconds: (data['durationMs'] as num).toInt())
      ..buffer = Duration(
        milliseconds: (data['bufferedPositionMs'] as num).toInt(),
      )
      ..rate = (data['speed'] as num).toDouble()
      ..width = (data['width'] as num).toInt()
      ..height = (data['height'] as num).toInt();
    if (wasPlaying != state.playing) {
      playingController.add(state.playing);
    }
    if (wasCompleted != state.completed) {
      completedController.add(state.completed);
    }
    if (wasBuffering != state.buffering) {
      bufferingController.add(state.buffering);
    }
    if (previousDuration != state.duration) {
      durationController.add(state.duration);
    }
    if (previousSize != (state.width, state.height)) {
      rect.value = ui.Rect.fromLTWH(
        0,
        0,
        state.width.toDouble(),
        state.height.toDouble(),
      );
      sizeController.add((state.width, state.height));
    }
    positionController.add(state.position);
    bufferController.add(state.buffer);
    _updateExternalSubtitle();
  }

  void _updateExternalSubtitle() {
    final cues = _externalCues;
    if (cues == null || _textDisabled) return;
    final positionMs = state.position.inMilliseconds;
    final next = Subtitle.raw(
      cues
          .where((cue) => cue.startMs <= positionMs && positionMs < cue.endMs)
          .map((cue) => cue.text)
          .join('\n'),
    );
    if (next != state.subtitle) {
      state.subtitle = next;
      subtitleController.add(next);
    }
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final media = playable is Media
        ? playable
        : (playable as Playlist).medias.first;
    await _open({
      'videoUrl': media.uri,
      'positionMs': media.start?.inMilliseconds ?? 0,
    }, play: play);
  }

  @override
  Future<void> play() => _command('play');
  @override
  Future<void> pause() => _command('pause');
  @override
  Future<void> playOrPause() => state.playing ? pause() : play();
  @override
  Future<void> stop() => _command('stop');
  @override
  Future<void> seek(Duration duration) =>
      _command('seek', {'positionMs': duration.inMilliseconds});
  @override
  Future<void> setRate(double rate) => _command('setSpeed', {'speed': rate});
  @override
  Future<void> setVolume(double volume) async {
    state.volume = volume;
    await _command('setVolume', {'volume': volume / 100});
  }

  @override
  Future<void> setPlaylistMode(PlaylistMode playlistMode) =>
      _command('setRepeat', {'repeat': playlistMode == PlaylistMode.single});
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    final revision = ++_subtitleRevision;
    final source = _sourceId;
    final id = track.id;
    String? content;
    if (id.startsWith('memory://')) {
      content = id.substring('memory://'.length);
    } else if (track.uri) {
      final uri = Uri.parse(id);
      if (uri.scheme == 'http' || uri.scheme == 'https') {
        final client = HttpClient();
        try {
          final response = await (await client.getUrl(uri)).close();
          content = await response.transform(const Utf8Decoder()).join();
        } finally {
          client.close();
        }
      } else {
        content = await File(uri.scheme == 'file' ? uri.toFilePath() : id)
            .readAsString();
      }
    }
    if (_disposed || revision != _subtitleRevision || source != _sourceId) {
      return;
    }
    _externalCues = content == null ? null : parseWebVtt(content);
    _textDisabled = id == 'no';
    state.subtitle = const Subtitle.raw();
    subtitleController.add(state.subtitle);
    _updateExternalSubtitle();
    await _command('setTextEnabled', {
      'enabled': !_textDisabled && _externalCues == null,
    });
  }

  @override
  Future<ui.Image?> screenshot() async {
    final encoded = await _channel.invokeMethod<Uint8List>('screenshot', {
      'playerId': playerId,
    });
    if (encoded == null) return null;
    final codec = await ui.instantiateImageCodec(encoded);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  String getProperty(String key) => switch (key) {
    'volume' => state.volume.toString(),
    'hwdec-current' => 'MediaCodec (Media3)',
    _ => '',
  };

  void setMediaHeader({
    String? userAgent,
    String? referer,
    Map<String, String>? headers,
  }) {
    _headers.clear();
    if (userAgent != null) _headers['User-Agent'] = userAgent;
    if (referer != null) _headers['Referer'] = referer;
    if (headers != null) _headers.addAll(headers);
  }

  Future<void> setProperty(String key, String value) async {
    if (key == 'file-local-options/vid') {
      await _command('setVideoEnabled', {'enabled': value != 'no'});
      return;
    }
    throw UnsupportedError('Media3 does not expose property $key');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _players.remove(playerId);
    if (!_firstFrame.isCompleted) _firstFrame.complete();
    await _command('release');
    textureId.dispose();
    rect.dispose();
    await super.dispose();
  }
}
