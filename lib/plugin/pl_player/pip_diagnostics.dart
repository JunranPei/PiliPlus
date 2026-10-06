import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Text-only diagnostics. Never requests a frame, captures a bitmap, or changes
/// playback. Both scheduled Flutter frames and raster timing reports are kept.
abstract final class PipDiagnostics {
  static bool get enabled => kDebugMode && Platform.isAndroid;
  static final _clock = Stopwatch()..start();
  static final _probes = <String, Map<String, Object?> Function()>{};
  static int _untilUs = 0;
  static int _sequence = 0;
  static bool _installed = false;
  static bool _errorHookInstalled = false;
  static IOSink? _file;
  static Timer? _flushTimer;
  static bool _flushing = false;
  static final _pendingFile = StringBuffer();

  static Future<void> openFile(Directory directory) async {
    if (!enabled || _file != null) return;
    await directory.create(recursive: true);
    final path = '${directory.path}${Platform.pathSeparator}'
        'flutter-${DateTime.now().toUtc().microsecondsSinceEpoch}.jsonl';
    final sink = File(path).openWrite();
    _file = sink;
    unawaited(sink.done.catchError((Object error) {
      if (identical(_file, sink)) {
        _file = null;
        _flushTimer?.cancel();
        debugPrintSynchronously('[PIP_TRACE_FILE_ERROR] $error');
      }
    }));
    _flushTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      unawaited(_flushFile(sink));
    });
    debugPrintSynchronously('[PIP_TRACE_FILE] $path');
    event('trace.file', {'path': path, 'flushIntervalMs': 100});
  }

  static Future<void> _flushFile(IOSink sink) async {
    if (_flushing || !identical(_file, sink) || _pendingFile.isEmpty) return;
    _flushing = true;
    final batch = _pendingFile.toString();
    _pendingFile.clear();
    try {
      sink.write(batch);
      await sink.flush();
    } catch (error) {
      if (identical(_file, sink)) _file = null;
      _flushTimer?.cancel();
      debugPrintSynchronously('[PIP_TRACE_FILE_ERROR] $error');
    } finally {
      _flushing = false;
    }
  }

  static void event(String name, [Map<String, Object?> data = const {}]) {
    // Diagnostics must never interrupt a command, widget mount or callback.
    try {
      _event(name, data);
    } catch (error) {
      debugPrintSynchronously('[PIP_TRACE_ERROR] event=$name error=$error');
    }
  }

  static void _event(String name, Map<String, Object?> data) {
    if (!enabled) return;
    // Avoid debugPrint's throttling queue: timestamps describe the observation,
    // not the moment a delayed console message eventually gets flushed.
    final payload = jsonEncode({
      'utcUs': DateTime.now().toUtc().microsecondsSinceEpoch,
      'elapsedUs': _clock.elapsedMicroseconds,
      'seq': ++_sequence,
      'event': name,
      ...data,
    }, toEncodable: (value) => value.toString());
    // Preserve every record without flooding Android's synchronous console
    // bridge during layout. UTC and sequence still describe observation time.
    final file = _file;
    if (file != null) {
      // IOSink rejects add/write while flush is bound to its internal stream.
      // Producers append here; only the serial flusher accesses the sink.
      _pendingFile.writeln(payload);
      return;
    }
    // Dart's Android console path truncates entries around 1 KB even when
    // logcat itself allows more. Keep every physical entry below that limit.
    if (utf8.encode(payload).length <= 700) {
      debugPrintSynchronously('[PIP_TRACE] $payload');
    } else {
      // Logcat has a per-entry byte limit. Preserve giant error/creator chains
      // in numbered segments instead of silently truncating their tail.
      final parts = (payload.length / 120).ceil();
      for (var index = 0; index < parts; index++) {
        final end = (index + 1) * 120;
        debugPrintSynchronously(
          '[PIP_TRACE] ${jsonEncode({
            'event': 'trace.chunk',
            'seq': _sequence,
            'part': index,
            'parts': parts,
            'payload': payload.substring(index * 120, end < payload.length ? end : payload.length),
          })}',
        );
      }
    }
  }

  static void arm(String reason) {
    if (!enabled) return;
    _untilUs = _clock.elapsedMicroseconds + 8000000;
    event('trace.arm', {'reason': reason, 'durationMs': 8000});
    if (!_errorHookInstalled) {
      _errorHookInstalled = true;
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        event('flutter.error', {
          'exception': details.exception.toString(),
          'stack': details.stack?.toString(),
          'library': details.library,
          'context': details.context?.toString(),
          'fullDiagnostics': details.toString(),
        });
        if (previous != null) previous(details);
      };
    }
    if (_installed) return;
    _installed = true;
    SchedulerBinding.instance.addPersistentFrameCallback((timestamp) {
      if (_clock.elapsedMicroseconds > _untilUs) return;
      // Persistent callbacks run after WidgetsBinding.drawFrame. True build
      // and raster start/end times are supplied by FrameTiming below.
      event('frame.afterDrawFrame', {'schedulerUs': timestamp.inMicroseconds});
      SchedulerBinding.instance.addPostFrameCallback((timestamp) {
        event('frame.postFrame', {'schedulerUs': timestamp.inMicroseconds});
        snapshot('postFrame');
      });
    });
    SchedulerBinding.instance.addTimingsCallback((timings) {
      if (_clock.elapsedMicroseconds > _untilUs) return;
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
    if (!enabled) return;
    _probes[name] = probe;
    event('probe.register', {'name': name});
  }

  static void unregister(String name) {
    if (!enabled) return;
    _probes.remove(name);
    event('probe.unregister', {'name': name});
  }

  static void snapshot(String reason) {
    if (!enabled) return;
    for (final entry in _probes.entries.toList()) {
      try {
        event('geometry', {
          'probe': entry.key,
          'reason': reason,
          ...entry.value(),
        });
      } catch (error, stack) {
        event('probe.error', {
          'probe': entry.key,
          'error': error,
          'stack': stack,
        });
      }
    }
  }
}
