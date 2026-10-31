import 'dart:async';
import 'dart:isolate';

import 'package:hive_ce/hive.dart';

import 'package:PiliPlus/plugin/pl_player/playback/parallel_audio_source.dart';
import 'package:PiliPlus/plugin/pl_player/playback/resume_index_hint.dart';
import 'package:PiliPlus/plugin/pl_player/playback/persisted_resume_index_hints.dart';

/// Experimental selected-source prefetch whose byte forwarding stays off the UI
/// isolate. No files other than the two selected tracks are requested.
class IsolatedMediaSources {
  IsolatedMediaSources({required this.headers, this.onEvent});

  final Map<String, String> headers;
  void Function(String, Map<String, Object?>)? onEvent;
  final _ready = Completer<({String video, String audio})>();
  ReceivePort? _responses;
  SendPort? _commands;
  Isolate? _worker;
  Timer? _shutdown;
  bool _closed = false;
  bool _started = false;
  static const _reuseIndex = bool.fromEnvironment('REUSE_RESUME_INDEX');
  static final _indexHints = ResumeIndexHintCache();
  static PersistedResumeIndexHints? _persistedIndexHints;

  static void preparePersistedIndexHints(Box<dynamic> box) {
    if (_reuseIndex && const bool.fromEnvironment('PERSIST_RESUME_INDEX')) {
      _persistedIndexHints ??= PersistedResumeIndexHints(box);
    }
  }

  // The path only predicts an offset. Current URLs/headers still fetch fresh
  // bytes, and native Range/length validation rejects stale predictions.
  static String _indexKey(String kind, String url) =>
      '$kind:${Uri.parse(url).path}';

  Future<({String video, String audio})> start(
    String video,
    String audio, {
    List<String> videoAlternatives = const [],
    List<String> audioAlternatives = const [],
    Duration resumePosition = Duration.zero,
  }) async {
    if (_closed || _started) {
      throw StateError('Transport already used or closed');
    }
    _started = true;
    _ready.future.ignore();
    final videoIndexKey = _reuseIndex ? _indexKey('video', video) : '';
    final audioIndexKey = _reuseIndex ? _indexKey('audio', audio) : '';
    final videoMemoryHint = _reuseIndex ? _indexHints.get(videoIndexKey) : null;
    final audioMemoryHint = _reuseIndex ? _indexHints.get(audioIndexKey) : null;
    final videoHint =
        videoMemoryHint ?? _persistedIndexHints?.get(videoIndexKey);
    final audioHint =
        audioMemoryHint ?? _persistedIndexHints?.get(audioIndexKey);
    if (_reuseIndex) {
      onEvent?.call('isolated.indexHint.lookup', {
        'video': videoHint != null,
        'audio': audioHint != null,
        'videoOrigin': videoMemoryHint != null
            ? 'memory'
            : videoHint != null
            ? 'disk'
            : 'miss',
        'audioOrigin': audioMemoryHint != null
            ? 'memory'
            : audioHint != null
            ? 'disk'
            : 'miss',
      });
    }
    final responses = ReceivePort()
      ..listen((message) {
        if (message is Map) {
          switch (message['type']) {
            case 'index':
              if (_reuseIndex && !_closed) {
                final kind = message['kind'] as String;
                final hint = message['hint'] as ResumeIndexHint;
                final cached = _indexHints.put(
                  kind == 'video' ? videoIndexKey : audioIndexKey,
                  hint,
                );
                onEvent?.call('isolated.indexHint.stored', {
                  'kind': kind,
                  'cached': cached,
                  'bytes': hint.prefix.length,
                });
                final store = _persistedIndexHints;
                if (cached && store != null) {
                  unawaited(
                    store
                        .put(
                          kind == 'video' ? videoIndexKey : audioIndexKey,
                          hint,
                        )
                        .then((bytes) {
                          if (!_closed) {
                            onEvent?.call('isolated.indexHint.persisted', {
                              'kind': kind,
                              'cached': bytes != null,
                              'bytes': bytes,
                            });
                          }
                        }),
                  );
                }
              }
            case 'ready':
              _commands = message['commands'] as SendPort;
              if (_closed) {
                _commands!.send('close');
              } else if (!_ready.isCompleted) {
                _ready.complete((
                  video: message['video'] as String,
                  audio: message['audio'] as String,
                ));
              }
            case 'event':
              onEvent?.call(
                message['name'] as String,
                Map<String, Object?>.from(message['data'] as Map),
              );
          }
        } else {
          // Never log the error message: it can include an authorized URL.
          // Keep only its type and bounded stack frames so a failed forwarding
          // stream does not become an unexplained worker exit.
          if (message is List && message.length == 2) {
            final type = RegExp(
              r'^([A-Za-z][A-Za-z0-9_ ]{0,63})(?=[:(])',
            ).firstMatch(message[0].toString())?.group(1);
            final frames = message[1]
                .toString()
                .split('\n')
                .where((line) => RegExp(r'^#\d+\s').hasMatch(line))
                .take(12)
                .map((line) {
                  final method = line.split(' (').first;
                  final location = RegExp(
                    r'\((dart:[a-z_]+/[^:()\s]+|package:PiliPlus/[^:()\s]+):(\d+):(\d+)\)$',
                  ).firstMatch(line);
                  return {
                    'method': method.replaceAll(
                      RegExp(r'[^#A-Za-z0-9_.$<> ]'),
                      '',
                    ),
                    if (location != null) 'source': location.group(1),
                    if (location != null) 'line': int.parse(location.group(2)!),
                  };
                })
                .toList(growable: false);
            onEvent?.call('isolated.workerError', {
              'type': type ?? 'Unknown',
              'frames': frames,
            });
          }
          if (!_ready.isCompleted) {
            _ready.completeError(StateError('Transport worker exited'));
          }
          onEvent?.call('isolated.closed', {'expected': _closed});
          _shutdown?.cancel();
          _responses?.close();
          _responses = null;
          _worker = null;
        }
      });
    _responses = responses;
    try {
      final worker = await Isolate.spawn(
        _serve,
        {
          'responses': responses.sendPort,
          'video': video,
          'audio': audio,
          'videoAlternatives': videoAlternatives,
          'audioAlternatives': audioAlternatives,
          'headers': headers,
          'resumePositionUs': resumePosition.inMicroseconds,
          'videoIndexHint': videoHint,
          'audioIndexHint': audioHint,
        },
        onExit: responses.sendPort,
        onError: responses.sendPort,
        errorsAreFatal: true,
      );
      _worker = worker;
      if (_closed) worker.kill(priority: Isolate.immediate);
      return await _ready.future.timeout(const Duration(seconds: 2));
    } catch (_) {
      close();
      rethrow;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (!_ready.isCompleted) {
      _ready.future.ignore();
      _ready.completeError(StateError('Transport closed'));
    }
    _commands?.send('close');
    _shutdown = Timer(const Duration(seconds: 1), () {
      _worker?.kill(priority: Isolate.immediate);
      _worker = null;
      _responses?.close();
      _responses = null;
    });
  }

  static Future<void> _serve(Map<String, Object?> config) async {
    final parent = config['responses'] as SendPort;
    final eventClock = const bool.fromEnvironment('RESUME_STAGE_TIMING')
        ? (Stopwatch()..start())
        : null;
    final headers = Map<String, String>.from(config['headers'] as Map);
    final sources = <ParallelAudioSource>[];
    const alignAudio = bool.fromEnvironment('PREFETCH_RESUME_AUDIO_MASTER');
    ParallelAudioSource? audioSource;
    Duration? videoResumeStart;
    final commands = ReceivePort();
    commands.listen((_) {
      for (final source in sources) {
        source.close();
      }
      commands.close();
      Isolate.exit();
    });
    ParallelAudioSource create(String kind) {
      final source = ParallelAudioSource(
        headers: headers,
        resumePosition: Duration(
          microseconds: config['resumePositionUs'] as int,
        ),
        waitForResumeAlignment: alignAudio && kind == 'audio',
        resumeIndexHint: config['${kind}IndexHint'] as ResumeIndexHint?,
        onResumeIndex: _reuseIndex
            ? (hint) => parent.send({
                'type': 'index',
                'kind': kind,
                'hint': hint,
              })
            : null,
        onResumeSegment: alignAudio && kind == 'video'
            ? (position) {
                videoResumeStart = position;
                audioSource?.alignResumeTo(position);
              }
            : null,
        onEvent: (name, data) {
          parent.send({
            'type': 'event',
            'name':
                'isolated.$kind.${name.substring('audio.prefetch.'.length)}',
            'data': {
              ...data,
              if (eventClock != null)
                'workerElapsedUs': eventClock.elapsedMicroseconds,
              if (eventClock != null)
                'workerUtcUs': DateTime.now().microsecondsSinceEpoch,
            },
          });
        },
      );
      if (kind == 'audio') {
        audioSource = source;
        if (videoResumeStart case final position?) {
          source.alignResumeTo(position);
        }
      }
      sources.add(source);
      return source;
    }

    try {
      final urls = await Future.wait([
        create('video').start(
          config['video'] as String,
          alternatives: (config['videoAlternatives'] as List).cast<String>(),
          hedgeAfter: const Duration(
            milliseconds: int.fromEnvironment(
              'MEDIA_HEDGE_DELAY_MS',
              defaultValue: 120,
            ),
          ),
        ),
        create('audio').start(
          config['audio'] as String,
          alternatives: (config['audioAlternatives'] as List).cast<String>(),
          hedgeAfter: const Duration(
            milliseconds: int.fromEnvironment(
              'MEDIA_HEDGE_DELAY_MS',
              defaultValue: 120,
            ),
          ),
        ),
      ]);
      parent.send({
        'type': 'ready',
        'commands': commands.sendPort,
        'video': urls[0],
        'audio': urls[1],
      });
    } catch (_) {
      for (final source in sources) {
        source.close();
      }
      commands.close();
      Isolate.exit();
    }
  }
}
