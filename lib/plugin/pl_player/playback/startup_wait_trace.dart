import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';
import 'package:dio/dio.dart';

/// Diagnostic boundaries only; never log bodies, headers, cookies, or URLs.
abstract final class StartupWaitTrace {
  static const enabled = bool.fromEnvironment('STARTUP_WAIT_TRACE');
  static int _sequence = 0;
  static bool get active => enabled && PlaybackDiagnostics.active;

  static Map<String, Object?> request(RequestOptions options) => {
    'httpRequestId': options.extra['startupWaitRequestId'],
    'path': options.uri.path,
  };

  static T sync<T>(
    String name,
    T Function() operation, [
    Map<String, Object?> data = const {},
  ]) {
    if (!active) return operation();
    final id = ++_sequence;
    final clock = Stopwatch()..start();
    PlaybackDiagnostics.event('wait.span.begin', {
      'spanId': id,
      'name': name,
      ...data,
    });
    try {
      return operation();
    } finally {
      final elapsed = clock.elapsedMicroseconds;
      PlaybackDiagnostics.event('wait.span.end', {
        'spanId': id,
        'name': name,
        'synchronous': true,
        'durationUs': elapsed,
      });
    }
  }

  static Future<T> wait<T>(
    String name,
    Future<T> Function() operation, [
    Map<String, Object?> data = const {},
  ]) {
    if (!active) return operation();
    final id = ++_sequence;
    final clock = Stopwatch()..start();
    PlaybackDiagnostics.event('wait.span.begin', {
      'spanId': id,
      'name': name,
      ...data,
    });
    try {
      final result = operation();
      final submitUs = clock.elapsedMicroseconds;
      return result.whenComplete(() {
        final elapsed = clock.elapsedMicroseconds;
        PlaybackDiagnostics.event('wait.span.end', {
          'spanId': id,
          'name': name,
          'synchronous': false,
          'submitUs': submitUs,
          'durationUs': elapsed,
        });
      });
    } catch (_) {
      PlaybackDiagnostics.event('wait.span.end', {
        'spanId': id,
        'name': name,
        'synchronous': true,
        'durationUs': clock.elapsedMicroseconds,
        'submissionFailed': true,
      });
      rethrow;
    }
  }
}

/// Retains Dio's exact transformer and JSON decoder, including its threshold.
final class StartupWaitTransformer extends Transformer {
  StartupWaitTransformer._(this.inner);
  final Transformer inner;
  static final _requestZoneKey = Object();

  static Transformer wrap(BackgroundTransformer original) {
    if (!StartupWaitTrace.enabled) return original;
    final decode = original.jsonDecodeCallback;
    original.jsonDecodeCallback = (text) => StartupWaitTrace.sync(
      'http.json.decode.submit',
      () => decode(text),
      {
        ...?Zone.current[_requestZoneKey] as Map<String, Object?>?,
        'characters': text.length,
      },
    );
    return StartupWaitTransformer._(original);
  }

  @override
  Future<String> transformRequest(RequestOptions options) =>
      inner.transformRequest(options);

  @override
  Future<dynamic> transformResponse(
    RequestOptions options,
    ResponseBody responseBody,
  ) => StartupWaitTrace.wait(
    'http.transform',
    () => runZoned(
      () => inner.transformResponse(options, responseBody),
      zoneValues: {_requestZoneKey: StartupWaitTrace.request(options)},
    ),
    StartupWaitTrace.request(options),
  );
}
