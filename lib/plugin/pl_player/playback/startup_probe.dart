import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';
import 'package:media_kit/media_kit.dart';

/// Explicit opt-in experiment. Ordinary builds cannot read a probe config or
/// replace media. Local mode retains the network source's EDL and player options
/// so the comparison changes media I/O, not the page or playback handshake.
abstract final class StartupProbe {
  static const directory = String.fromEnvironment('PLAYBACK_STARTUP_PROBE_DIR');
  static const enabled = PlaybackDiagnostics.enabled && directory != '';
  static const verbose =
      PlaybackDiagnostics.enabled &&
      bool.fromEnvironment('PLAYBACK_STARTUP_VERBOSE');
  static const deep = verbose && bool.fromEnvironment('PLAYBACK_STARTUP_DEEP');
  static int _messages = 0;
  static final Map<String, int> _deepCounts = {};

  static void beginSource() {
    if (verbose) _messages = 0;
    if (deep) _deepCounts.clear();
  }

  static Future<({String video, String? audio})> resolve(
    DataSource source,
    int? cid,
  ) async {
    final original = (video: source.videoSource, audio: source.audioSource);
    if (!enabled || source is! NetworkSource) return original;
    final config = jsonDecode(
      await File('$directory/config.json').readAsString(),
    ) as Map<String, dynamic>;
    if (config['cid'] != cid) return original;
    _messages = 0;
    final mode = config['mode'] as String;
    PlaybackDiagnostics.event('startup.probe', {'cid': cid, 'mode': mode});
    if (mode == 'record') {
      await File('$directory/selected-source.json').writeAsString(
        jsonEncode({
          'cid': cid,
          'video': original.video,
          'audio': original.audio,
          'headers': {
            'User-Agent': BrowserUa.pc,
            'Referer': HttpString.baseUrl,
          },
        }),
      );
      return original;
    }
    if (!const ['remote', 'local', 'loopback'].contains(mode)) {
      throw StateError('Unknown startup probe mode');
    }
    final video = config['video'] as String;
    final audio = config['audio'] as String?;
    for (final value in [video, if (audio != null && audio.isNotEmpty) audio]) {
      if (mode == 'local') {
        if (!value.startsWith('$directory/fixtures/') ||
            value.contains('..') ||
            !File(value).existsSync()) {
          throw StateError(
            'Startup fixture is missing or outside probe directory',
          );
        }
      } else {
        final uri = Uri.parse(value);
        if (mode == 'remote' && uri.scheme != 'https' ||
            mode == 'loopback' &&
                (uri.scheme != 'http' || uri.host != '127.0.0.1')) {
          throw StateError('Unexpected startup probe URL scheme/host');
        }
      }
    }
    PlaybackDiagnostics.event('startup.source.resolved', {
      'mode': mode,
      'cid': cid,
      'videoId': PlaybackDiagnostics.sourceId(video),
      'audioId': PlaybackDiagnostics.sourceId(audio),
    });
    return (video: video, audio: audio);
  }

  // Deliberately retain only milestone names. libmpv debug messages may contain
  // signed URLs and request headers, which must not enter the general trace.
  static void onLog(PlayerLog log) {
    if (!verbose || !PlaybackDiagnostics.active || _messages >= 512) return;
    final text = log.text.toLowerCase();
    if (deep) {
      // Store only classified milestones, never raw URLs, headers or packets.
      for (final entry in const <String, String>{
        'request: get': 'http.request',
        'header=\'http/': 'http.response.line',
        'http/1.1 206': 'http.response.partial',
        'http/1.1 200': 'http.response.ok',
        'before avformat_find_stream_info': 'demux.probe.begin',
        'after avformat_find_stream_info': 'demux.probe.end',
        'mediacodec ': 'codec.message',
        'started successfully': 'codec.started',
        'queued input buffer': 'codec.input.queued',
        'got output buffer': 'codec.output.received',
        'output mediaformat changed': 'codec.output.format',
        'flushing': 'codec.flush',
        'av_read_frame': 'demux.packet.read',
        'received frame': 'decoder.frame.received',
      }.entries) {
        if (text.contains(entry.key)) {
          final key = '${entry.value}|${log.prefix}';
          final count = (_deepCounts[key] ?? 0) + 1;
          _deepCounts[key] = count;
          if (count <= 3) {
            final size = RegExp(r'\bsize=(\d+)').firstMatch(text);
            final pts = RegExp(r'\bts=(-?\d+)').firstMatch(text);
            PlaybackDiagnostics.event('startup.deep', {
              'stage': entry.value,
              'prefix': log.prefix,
              'level': log.level,
              'occurrence': count,
              if (size != null) 'size': int.tryParse(size[1]!),
              if (pts != null) 'pts': int.tryParse(pts[1]!),
              'timing': 'Dart log delivery, not native call time or display',
            });
          }
        }
      }
    }
    for (final entry in const <String, String>{
      'opening segment': 'edl.segment.open',
      'starting connection attempt': 'connect.begin',
      'successfully connected': 'connect.end',
      'request: get': 'http.request',
      'http/1.1 2': 'http.response.success',
      'http/1.1 4': 'http.response.error',
      'before avformat_find_stream_info': 'demux.probe.begin',
      'after avformat_find_stream_info': 'demux.probe.end',
      'detected file format': 'demux.detected',
      'opening decoder': 'decoder.open',
      'selected codec': 'decoder.selected',
      'using hardware decoding': 'decoder.hardware',
      'using software decoding': 'decoder.software',
      'both surface and native_window are null': 'decoder.surface.missing',
      'reconfiguring': 'output.reconfigure',
      'vo: [': 'output.configured',
      'first video frame after restart shown': 'mpv.firstFrame',
      'starting video playback': 'mpv.video.start',
      'starting audio playback': 'mpv.audio.start',
      'cache underrun': 'cache.underrun',
    }.entries) {
      if (text.contains(entry.key)) {
        _messages++;
        PlaybackDiagnostics.event('startup.mpv', {
          'stage': entry.value,
          'prefix': log.prefix,
          'level': log.level,
          'timing':
              'Dart delivery time; mpv milestone is not display presentation',
        });
        break;
      }
    }
  }
}
