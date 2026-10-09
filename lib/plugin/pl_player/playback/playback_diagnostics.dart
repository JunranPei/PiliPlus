import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Opt-in metadata only. Does not request frames or modify playback/surfaces.
/// FrameTiming describes Flutter raster work, not decoded video presentation.
abstract final class PlaybackDiagnostics {
  static const enabled = bool.fromEnvironment('PLAYBACK_TRACE');
  static const _channel = MethodChannel('piliplus/playback_diagnostics');
  static final _clock = Stopwatch()..start();
  static final _probes = <String, Map<String, Object?> Function()>{};
  static final _pending = StringBuffer();
  static int _seq = 0;
  static int _untilUs = 0;
  static int _burstStartUs = 0;
  static int _dropped = 0;
  static int _bytes = 0;
  static bool _installed = false;
  static bool _flushing = false;
  static bool _opening = false;
  static bool _failed = false;
  static IOSink? _sink;
  static Timer? _flushTimer;
  static Timer? _stopTimer;
  static Map<String, Object?> _source = {};

  static bool get active => enabled && _clock.elapsedMicroseconds < _untilUs;

  static void arm(String reason, Map<String, Object?> source) {
    if (!enabled || !Platform.isAndroid) return;
    try {
      final now = _clock.elapsedMicroseconds;
      if (!active) _burstStartUs = now;
      _untilUs = (now + 20000000).clamp(0, _burstStartUs + 120000000);
      _source = Map.of(source);
      _install();
      event('trace.arm', {
        'reason': reason,
        'source': source,
        'untilUs': _untilUs,
      });
      if (_sink == null && !_opening && !_failed) unawaited(_open());
      unawaited(_nativeArm(reason, source));
      _flushTimer ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
        unawaited(_flush());
      });
      _stopTimer?.cancel();
      _stopTimer = Timer(Duration(microseconds: _untilUs - now), () {
        _write('trace.end', {
          'droppedRecords': _dropped,
          'writtenBytes': _bytes,
        });
        _flushTimer?.cancel();
        _flushTimer = null;
        unawaited(_flush());
      });
    } catch (error) {
      debugPrint('[PLAYBACK_TRACE_ERROR] arm ${error.runtimeType}');
    }
  }

  static Future<void> _nativeArm(
    String reason,
    Map<String, Object?> source,
  ) async {
    try {
      await _channel.invokeMethod<void>('arm', {
        'reason': reason,
        'durationMs': 20000,
        'source': source,
      });
    } catch (_) {
      /* Missing diagnostics channel never affects playback. */
    }
  }

  static Future<void> _open() async {
    _opening = true;
    try {
      final sent = _clock.elapsedMicroseconds;
      final config = await _channel.invokeMapMethod<String, dynamic>(
        'configure',
      );
      final received = _clock.elapsedMicroseconds;
      if (config?['directory'] is! String) {
        throw StateError('Missing trace directory');
      }
      final directory = Directory(config!['directory'] as String);
      await directory.create(recursive: true);
      final file = File(
        '${directory.path}/flutter-$pid-${DateTime.now().microsecondsSinceEpoch}.jsonl',
      );
      final sink = file.openWrite();
      _sink = sink;
      unawaited(
        sink.done.catchError((Object error) {
          _failed = true;
          _sink = null;
          debugPrint('[PLAYBACK_TRACE_ERROR] file ${error.runtimeType}');
        }),
      );
      _write('trace.file', {
        'path': file.path,
        'schema': 1,
        'buildMode': kReleaseMode
            ? 'release'
            : kProfileMode
            ? 'profile'
            : 'debug',
        'pid': pid,
      });
      _write('clock.sync', {
        'dartSendUs': sent,
        'dartReceiveUs': received,
        'native': config,
      });
      // Best round-trip interval bounds clock translation; do not use wall time
      // as an exact join key between Flutter, Android and Perfetto.
      for (var i = 0; i < 3; i++) {
        final start = _clock.elapsedMicroseconds;
        final sample = await _channel.invokeMapMethod<String, dynamic>('clock');
        _write('clock.sync', {
          'dartSendUs': start,
          'dartReceiveUs': _clock.elapsedMicroseconds,
          'native': sample,
        });
      }
      debugPrint('[PLAYBACK_TRACE_FILE] ${file.path}');
      await _nativeArm('configure.complete', _source);
      await _flush();
    } catch (error) {
      _failed = true;
      debugPrint('[PLAYBACK_TRACE_ERROR] configure ${error.runtimeType}');
    } finally {
      _opening = false;
    }
  }

  static Future<void> _flush() async {
    final sink = _sink;
    if (_flushing || sink == null || _pending.isEmpty) return;
    _flushing = true;
    final batch = _pending.toString();
    _pending.clear();
    try {
      sink.write(batch);
      await sink.flush();
    } catch (error) {
      _failed = true;
      _sink = null;
      debugPrint('[PLAYBACK_TRACE_ERROR] flush ${error.runtimeType}');
    } finally {
      _flushing = false;
      if (!active && _sink != null && _pending.isNotEmpty) {
        unawaited(_flush());
      }
    }
  }

  static void event(String name, [Map<String, Object?> data = const {}]) {
    if (!active) return;
    _write(name, data);
    if (name == 'media.textureId' || name == 'media.controller.created') {
      // Shorten native observer discovery latency; never wait on playback.
      unawaited(_markNative(name, data));
    }
  }

  static Future<void> _markNative(
    String name,
    Map<String, Object?> data,
  ) async {
    try {
      await _channel.invokeMethod<void>('mark', {'name': name, 'data': data});
    } catch (_) {
      // Channel availability is independent of normal playback.
    }
  }

  static void _write(String name, Map<String, Object?> data) {
    if (!enabled) return;
    try {
      if (_pending.length > 4 * 1024 * 1024 || _bytes > 64 * 1024 * 1024) {
        _dropped++;
        return;
      }
      final line = jsonEncode({
        'event': name,
        'seq': ++_seq,
        'elapsedUs': _clock.elapsedMicroseconds,
        'utcUs': DateTime.now().microsecondsSinceEpoch,
        'source': _source,
        ...data,
      }, toEncodable: (object) => object.toString());
      _bytes += utf8.encode(line).length + 1;
      _pending.writeln(line);
    } catch (error) {
      _dropped++;
      debugPrint('[PLAYBACK_TRACE_ERROR] $name ${error.runtimeType}');
    }
  }

  static void _install() {
    if (_installed) return;
    _installed = true;
    SchedulerBinding.instance.addPersistentFrameCallback((timestamp) {
      if (!active) return;
      event('frame.afterDrawFrame', {'schedulerUs': timestamp.inMicroseconds});
      SchedulerBinding.instance.addPostFrameCallback((timestamp) {
        if (!active) return;
        event('frame.postFrame', {'schedulerUs': timestamp.inMicroseconds});
        final started = _clock.elapsedMicroseconds;
        for (final probe in _probes.entries.toList()) {
          try {
            event('geometry', {
              'probe': probe.key,
              'schedulerUs': timestamp.inMicroseconds,
              ...probe.value(),
            });
          } catch (error) {
            event('probe.error', {
              'probe': probe.key,
              'type': error.runtimeType.toString(),
            });
          }
        }
        event('probe.collection', {
          'collectionUs': _clock.elapsedMicroseconds - started,
          'probeCount': _probes.length,
        });
      });
    });
    SchedulerBinding.instance.addTimingsCallback((timings) {
      if (!active) return;
      for (final timing in timings) {
        event('frame.raster', {
          'number': timing.frameNumber,
          'buildUs': timing.buildDuration.inMicroseconds,
          'rasterUs': timing.rasterDuration.inMicroseconds,
          'totalUs': timing.totalSpan.inMicroseconds,
          'timestamps': {
            for (final phase in FramePhase.values)
              phase.name: timing.timestampInMicroseconds(phase),
          },
        });
      }
    });
  }

  static void register(String name, Map<String, Object?> Function() probe) {
    if (enabled) _probes[name] = probe;
  }

  static void unregister(String name) {
    if (enabled) _probes.remove(name);
  }

  /// Stable process-local identity only; no media URL, cookie or file path.
  static String sourceId(Object? value) =>
      value == null ? 'none' : value.hashCode.toUnsigned(32).toRadixString(16);
}

/// A transparent observer: no repaint boundary, forced frame, or layer changes.
/// Place inside the FittedBox to observe both content size and ancestor scaling.
class PlaybackTraceRegion extends SingleChildRenderObjectWidget {
  const PlaybackTraceRegion({
    super.key,
    required this.name,
    required this.data,
    required super.child,
  });
  final String name;
  final Map<String, Object?> Function() data;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderPlaybackTraceRegion(name, data, View.of(context).devicePixelRatio);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderPlaybackTraceRegion renderObject,
  ) {
    renderObject
      ..data = data
      ..pixelRatio = View.of(context).devicePixelRatio;
  }
}

class RenderPlaybackTraceRegion extends RenderProxyBox {
  RenderPlaybackTraceRegion(
    this.name,
    this.data,
    this.pixelRatio, {
    @visibleForTesting this.isRecording,
  });
  final String name;
  Map<String, Object?> Function() data;
  double pixelRatio;
  @visibleForTesting
  final bool Function()? isRecording;
  bool get _recording => isRecording?.call() ?? PlaybackDiagnostics.active;
  late final _probeName = '$name#${identityHashCode(this)}';
  int _paintCount = 0;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    PlaybackDiagnostics.register(_probeName, snapshot);
    if (_recording) {
      try {
        PlaybackDiagnostics.event('region.attach', {
          'probe': _probeName,
          ...data(),
        });
      } catch (_) {
        // A diagnostic failure must never interrupt normal attachment.
      }
    }
  }

  @override
  void detach() {
    PlaybackDiagnostics.event('region.detach', {'probe': _probeName});
    PlaybackDiagnostics.unregister(_probeName);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (!_recording) return;
    try {
      _paintCount++;
      PlaybackDiagnostics.event('region.paint', {
        'probe': _probeName,
        'paintCount': _paintCount,
        'paintOffset': [offset.dx, offset.dy],
        ...snapshot(),
      });
    } catch (_) {
      // A diagnostic failure must never interrupt normal painting.
    }
  }

  Map<String, Object?> snapshot() {
    final nodes = <Map<String, Object?>>[];
    var visited = 0;
    void visit(RenderObject object, int depth) {
      if (++visited > 80) return;
      if (object is TextureBox ||
          object is RenderImage ||
          object is RenderFittedBox ||
          object is RenderOpacity ||
          object is RenderOffstage) {
        final node = _geometry(object);
        node['depth'] = depth;
        if (object is TextureBox) {
          node.addAll({
            'textureId': object.textureId,
            'freeze': object.freeze,
            'filterQuality': object.filterQuality.name,
          });
        }
        if (object is RenderImage) {
          node.addAll({
            'imageId': object.image == null
                ? null
                : identityHashCode(object.image!),
            'imageWidth': object.image?.width,
            'imageHeight': object.image?.height,
            'fit': object.fit?.name,
            'alignment': object.alignment.toString(),
          });
        }
        if (object is RenderFittedBox) {
          node.addAll({
            'fit': object.fit.name,
            'alignment': object.alignment.toString(),
          });
        }
        if (object is RenderOpacity) node['opacity'] = object.opacity;
        if (object is RenderOffstage) node['offstage'] = object.offstage;
        nodes.add(node);
      }
      object.visitChildren((child) => visit(child, depth + 1));
    }

    // The presentation probe records only its bounds/state. Its video and poster
    // have separate small probes to avoid walking the controls/danmaku tree.
    if (name != 'presentation' && child != null) {
      visit(child!, 0);
    }
    return {
      'name': name,
      'paintCount': _paintCount,
      'dpr': pixelRatio,
      ...data(),
      ..._geometry(this),
      'nodes': nodes,
      'truncated': visited > 80,
    };
  }

  Map<String, Object?> _geometry(RenderObject object) {
    final result = <String, Object?>{
      'renderId': identityHashCode(object),
      'class': object.runtimeType.toString(),
      'attached': object.attached,
    };
    if (object is! RenderBox || !object.hasSize || !object.attached) {
      return result;
    }
    final matrix = object.getTransformTo(null);
    final bounds = MatrixUtils.transformRect(matrix, Offset.zero & object.size);
    result.addAll({
      'size': [object.size.width, object.size.height],
      'globalLogicalRect': [
        bounds.left,
        bounds.top,
        bounds.right,
        bounds.bottom,
      ],
      'flutterPhysicalRect': [
        bounds.left * pixelRatio,
        bounds.top * pixelRatio,
        bounds.right * pixelRatio,
        bounds.bottom * pixelRatio,
      ],
      'matrix': matrix.storage.toList(),
      'constraints': object.constraints.toString(),
    });
    return result;
  }
}
