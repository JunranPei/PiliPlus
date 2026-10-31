import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';
import 'package:PiliPlus/plugin/pl_player/playback/startup_wait_trace.dart';

/// Opt-in diagnostic build. Samples and timeline events are not display proof.
abstract final class RuntimeProfile {
  static const enabled = bool.fromEnvironment('PLAYBACK_FULL_PROFILE');
  static final _open = <int, dev.TimelineTask>{};
  static int _next = 0;
  static bool _active = false;
  static Timer? _deadline;

  static void initialize() {
    if (!enabled || !kProfileMode) return;
    debugProfilePlatformChannels = true;
    arm();
    dev.registerExtension('ext.piliplus.runtimeProfile', (_, parameters) async {
      switch (parameters['action']) {
        case 'arm':
          arm();
        case 'stop':
          stop();
      }
      final sent = dev.Timeline.now;
      final native = await const MethodChannel('piliplus/playback_diagnostics')
          .invokeMapMethod<String, dynamic>('clock');
      return dev.ServiceExtensionResponse.result(
        jsonEncode({
          'enabled': enabled,
          'active': _active,
          'timelineSendUs': sent,
          'timelineReceiveUs': dev.Timeline.now,
          'native': native,
          'openSpans': _open.length,
        }),
      );
    });
  }

  static void arm() {
    if (!enabled) return;
    stop();
    _active = true;
    _deadline = Timer(const Duration(seconds: 25), stop);
    event('profile.arm');
  }

  static void stop() {
    _deadline?.cancel();
    for (final task in _open.values) {
      task.finish(arguments: {'endReason': 'captureBoundary'});
    }
    _open.clear();
    _active = false;
  }

  static int? begin(String name, [Map<String, Object?> data = const {}]) {
    if (!enabled || !_active || _open.length >= 512) return null;
    final id = ++_next;
    _open[id] = dev.TimelineTask(filterKey: 'PiliPlus')
      ..start(name, arguments: {'requestId': id, ...data});
    return id;
  }

  static void end(int? id, [Map<String, Object?> data = const {}]) {
    if (id == null) return;
    _open.remove(id)?.finish(arguments: {'requestId': id, ...data});
  }

  static void event(String name, [Map<String, Object?> data = const {}]) {
    if (!enabled || !_active) return;
    dev.Timeline.instantSync('PiliPlus.$name', arguments: data);
  }

  /// Existing events can include player state. Mirror scalar identifiers only;
  /// never copy source URLs, headers, bodies, exception text or nested objects.
  static void playbackEvent(String name, Map<String, Object?> data) {
    if (!enabled || !_active) return;
    event(name, {
      for (final key in const [
        'cid',
        'seq',
        'elapsedUs',
        'utcUs',
        'durationMs',
        'width',
        'height',
        'playing',
        'buffering',
        'positionMs',
        'playerId',
        'textureId',
      ])
        if (data[key] case final value?)
          if (value is num || value is bool) key: value,
    });
  }
}

/// Observes the existing adapter; keeps its pooling, retries and response body.
/// The first stream event is Dart delivery, not the first socket media byte.
final class RuntimeProfileAdapter implements HttpClientAdapter {
  RuntimeProfileAdapter(this.inner);
  final HttpClientAdapter inner;
  static const networkTrace = bool.fromEnvironment('PLAYBACK_NETWORK_TRACE');
  static int _requestSequence = 0;

  static HttpClientAdapter wrap(HttpClientAdapter adapter) =>
      RuntimeProfile.enabled || networkTrace
      ? RuntimeProfileAdapter(adapter)
      : adapter;

  static HttpClientAdapter unwrap(HttpClientAdapter adapter) =>
      adapter is RuntimeProfileAdapter ? adapter.inner : adapter;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // A path identifies an API without persisting query strings or addresses.
    final id = RuntimeProfile.begin('HTTP adapter', {
      'method': options.method,
      'path': options.uri.path,
    });
    final sparse = networkTrace && PlaybackDiagnostics.active;
    if (id == null && !sparse) {
      return inner.fetch(options, requestStream, cancelFuture);
    }
    final requestId = ++_requestSequence;
    if (StartupWaitTrace.enabled) {
      options.extra['startupWaitRequestId'] = requestId;
    }
    void record(String event, Map<String, Object?> data) {
      if (sparse) {
        PlaybackDiagnostics.event(event, {
          'httpRequestId': requestId,
          ...data,
        });
      }
    }

    record('http.begin', {
      'method': options.method,
      'host': options.uri.host,
      'path': options.uri.path,
      'scope': 'API adapter delivery; not DNS/TLS or native mpv media I/O',
    });
    var ended = false;
    var bytes = 0;
    void finish(String reason) {
      if (ended) return;
      ended = true;
      RuntimeProfile.end(id, {'endReason': reason, 'bytes': bytes});
      record('http.end', {'reason': reason, 'bytes': bytes});
    }

    if (cancelFuture != null) {
      unawaited(
        cancelFuture.then<void>(
          (_) {
            finish('cancelled');
          },
          onError: (Object _, StackTrace _) {
            finish('cancelFutureError');
          },
        ),
      );
    }
    try {
      final response = await inner.fetch(options, requestStream, cancelFuture);
      RuntimeProfile.event('http.responseHeadersDelivered', {
        'requestId': id,
        'status': response.statusCode,
      });
      record('http.headers', {'status': response.statusCode});
      var first = true;
      response.stream = response.stream.transform(
        StreamTransformer<Uint8List, Uint8List>.fromHandlers(
          handleData: (chunk, sink) {
            bytes += chunk.length;
            if (first) {
              first = false;
              RuntimeProfile.event('http.firstBodyChunkDelivered', {
                'requestId': id,
                'bytes': chunk.length,
              });
              record('http.firstChunk', {'bytes': chunk.length});
            }
            sink.add(chunk);
          },
          handleError: (Object error, StackTrace stack, sink) {
            finish('streamError');
            sink.addError(error, stack);
          },
          handleDone: (sink) {
            finish('bodyEnd');
            sink.close();
          },
        ),
      );
      return response;
    } catch (_) {
      finish('fetchError');
      rethrow;
    }
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
}
