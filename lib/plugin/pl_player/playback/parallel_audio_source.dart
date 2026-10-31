import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/plugin/pl_player/playback/bounded_body_warmup.dart';
import 'package:PiliPlus/plugin/pl_player/playback/mp4_resume_range.dart';
import 'package:PiliPlus/plugin/pl_player/playback/resume_index_hint.dart';
import 'package:PiliPlus/plugin/pl_player/playback/resume_body_recovery.dart';

/// Starts a selected track's HTTP request before mpv consumes that track.
/// Only the winning response is streamed,
/// with bounded replay prefixes; an optional predicted resume response can
/// supply a matching seek. Other seeks redirect to origin.
/// Ownership follows the loaded source, not page preparation callbacks.
class ParallelAudioSource {
  ParallelAudioSource({
    required this.headers,
    this.headerWait = const Duration(seconds: 3),
    this.streamForwarding = const bool.fromEnvironment('STREAM_MEDIA_FORWARD'),
    this.cancelClosedDelivery = const bool.fromEnvironment(
      'CANCEL_CLOSED_MEDIA_DELIVERY',
    ),
    this.resumePosition = Duration.zero,
    this.resumePresentationTime = const bool.fromEnvironment(
      'PREFETCH_RESUME_PRESENTATION_TIME',
    ),
    this.resumeBodyWarmup = const bool.fromEnvironment('PREFETCH_RESUME_BODY'),
    this.resumeSegmentBodyWarmup = const bool.fromEnvironment(
      'PREFETCH_RESUME_SEGMENT_BODY',
    ),
    this.hedgeResumePrefetch = const bool.fromEnvironment(
      'HEDGE_RESUME_PREFETCH',
    ),
    this.hedgeFreshResumePrefetch = const bool.fromEnvironment(
      'HEDGE_FRESH_RESUME_PREFETCH',
    ),
    this.resumeIndexHint,
    this.boundedResumeInit = const bool.fromEnvironment('BOUNDED_RESUME_INIT'),
    this.initialBodyHedge = const bool.fromEnvironment('HEDGE_INITIAL_BODY'),
    this.resumeBodyHedge = const bool.fromEnvironment('HEDGE_RESUME_BODY'),
    this.resumeBodyFailover = const bool.fromEnvironment(
      'RESUME_BODY_FAILOVER',
    ),
    this.resumeBodyProgressRace = const bool.fromEnvironment(
      'RESUME_BODY_PROGRESS_RACE',
    ),
    this.onResumeIndex,
    this.waitForResumeAlignment = false,
    this.onResumeSegment,
    this.onEvent,
  });

  static const enabled = bool.fromEnvironment('PARALLEL_AUDIO_SOURCE');
  static const _prefixLimit = 256 * 1024;
  final Map<String, String> headers;
  final Duration headerWait;
  final bool streamForwarding;
  final bool cancelClosedDelivery;
  final Duration resumePosition;
  final bool resumePresentationTime;
  final bool resumeBodyWarmup;
  final bool resumeSegmentBodyWarmup;
  final bool hedgeResumePrefetch;
  final bool hedgeFreshResumePrefetch;
  final ResumeIndexHint? resumeIndexHint;
  final bool boundedResumeInit;
  final bool initialBodyHedge;
  final bool resumeBodyHedge;
  final bool resumeBodyFailover;
  final bool resumeBodyProgressRace;
  final void Function(ResumeIndexHint)? onResumeIndex;
  final bool waitForResumeAlignment;
  final void Function(Duration)? onResumeSegment;
  final void Function(String, Map<String, Object?>)? onEvent;
  final HttpClient _client = HttpClient()..autoUncompress = false;
  final Uint8List _prefix = Uint8List(_prefixLimit);
  HttpServer? _server;
  Uri? _original;
  Uri? _resumePrimary;
  Uri? _resumeBackup;
  Duration _resumeHedgeDelay = const Duration(milliseconds: 120);
  Future<HttpClientResponse?>? _opening;
  HttpClient? _hedgeClient;
  Timer? _hedgeTimer;
  Completer<HttpClientResponse?>? _selection;
  bool _closed = false;
  bool _claimed = false;
  int _initialOffset = 0;
  int? _initialEnd;
  int? _expectedTotal;
  int? _resourceLength;
  int _resumeScannedLength = 0;
  bool _indexPublished = false;
  bool _hintAttempted = false;
  Duration? _alignedResumePosition;
  ParallelAudioSource? _resumeSource;
  BoundedBodyWarmup? _bodyWarmup;
  ResumeBodyRecovery? _bodyRecovery;
  int? _selectionBodyLimit;
  final _pendingInitialBodies = <BoundedBodyWarmup>{};
  int _prefixLength = 0;
  int receivedBytes = 0;
  int deliveredBytes = 0;
  static const _transferTrace = bool.fromEnvironment('STARTUP_TRANSFER_TRACE');
  Stopwatch? _transferClock;
  int _lastProgressUs = -100000;

  Future<String> start(
    String original, {
    List<String> alternatives = const [],
    Duration hedgeAfter = const Duration(milliseconds: 120),
  }) async {
    final uri = Uri.parse(original);
    if (!const ['https', 'http'].contains(uri.scheme)) return original;
    _original = uri;
    _resumePrimary = uri;
    // Alignment may arrive while the local server bind is awaiting. Publish
    // both endpoints first so that early audio resume can race them too.
    final backup = alternatives
        .map(Uri.tryParse)
        .whereType<Uri>()
        .where(
          (v) =>
              const ['https', 'http'].contains(v.scheme) &&
              v.authority != uri.authority,
        )
        .firstOrNull;
    _resumeBackup = backup;
    _resumeHedgeDelay = hedgeAfter;
    final hint = resumeIndexHint;
    if (boundedResumeInit &&
        resumePosition > Duration.zero &&
        hint != null &&
        hint.prefix.length <= 64 * 1024 &&
        mp4ResumeRange(
              hint.prefix,
              resumePosition,
              totalBytes: hint.totalBytes,
            ) !=
            null) {
      // The hint only establishes that this track has a small initialization
      // section. Fetch fresh bytes; never serve its cached bytes to the decoder.
      _initialEnd = 64 * 1024 - 1;
    }
    if (_transferTrace) _transferClock = Stopwatch()..start();
    // Binding is local and does not await any upstream network response.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      return original;
    }
    _server = server;
    server.listen((request) {
      unawaited(
        _serve(request).catchError((Object error) {
          _event(_closed ? 'delivery.cancelled' : 'delivery.error', {
            'type': error.runtimeType.toString(),
          });
          request.response.close().ignore();
        }),
      );
    });
    _opening = backup == null
        ? _open(uri)
        : _openHedged(uri, backup, hedgeAfter);
    _prepareResumeHint();
    return 'http://127.0.0.1:${server.port}/audio';
  }

  void _event(String name, [Map<String, Object?> data = const {}]) {
    onEvent?.call('audio.prefetch.$name', data);
  }

  /// At most one backup connection, only after the preferred endpoint is slow
  /// or fails. Initial-body racing optionally waits for a small fresh prefix
  /// before choosing a response. Losing sockets close before native consumption.
  Future<HttpClientResponse?> _openHedged(
    Uri primary,
    Uri backup,
    Duration delay,
  ) {
    final selected = _selection = Completer<HttpClientResponse?>();
    final hedge = _hedgeClient = HttpClient()..autoUncompress = false;
    var startedBackup = false;
    var failures = 0;
    Future<void> attempt(Uri uri, HttpClient client, HttpClient loser) async {
      var response = await _open(uri, client: client);
      if (_closed || selected.isCompleted) return;
      BoundedBodyWarmup? warmup;
      final selectionBodyLimit =
          _selectionBodyLimit ??
          (initialBodyHedge &&
                  resumePosition > Duration.zero &&
                  resumeIndexHint != null &&
                  _initialOffset == 0
              ? math.max(
                  8192,
                  math.min(resumeIndexHint!.prefix.length, 64 * 1024),
                )
              : null);
      if (response != null &&
          _length(response) != null &&
          selectionBodyLimit != null) {
        final limit = math.min(
          response.contentLength,
          selectionBodyLimit,
        );
        warmup = BoundedBodyWarmup(
          response,
          limit: limit,
          onEvent: _selectionBodyLimit == null
              ? null
              : (name, data) => _event('bodyWarmup.$name', data),
        );
        _pendingInitialBodies.add(warmup);
        final ready = await warmup.ready;
        _pendingInitialBodies.remove(warmup);
        _event(
          _selectionBodyLimit == null
              ? 'initialBody.ready'
              : 'bodyWarmup.ready',
          {
            'host': uri.host,
            'backup': uri == backup,
            'ready': ready,
            'limit': limit,
            'prefetchedBytes': warmup.prefetchedBytes,
          },
        );
        if (_closed || selected.isCompleted || !ready) {
          await warmup.close();
          if (_closed || selected.isCompleted) return;
          response = null;
        }
      }
      if (response != null && _length(response) != null) {
        _bodyWarmup = warmup;
        _original = uri;
        _hedgeTimer?.cancel();
        loser.close(force: true);
        _event('selected', {
          'host': uri.host,
          'backup': uri == backup,
          'bodyPrefetchedBytes': warmup?.prefetchedBytes ?? 0,
        });
        selected.complete(response);
      } else {
        client.close(force: true);
        if (++failures == 2) selected.complete(null);
      }
    }

    void startBackup() {
      if (_closed || selected.isCompleted || startedBackup) return;
      startedBackup = true;
      _event('hedge', {'host': backup.host});
      unawaited(attempt(backup, hedge, _client));
    }

    unawaited(
      attempt(primary, _client, hedge).then((_) {
        if (!selected.isCompleted) startBackup();
      }),
    );
    _hedgeTimer = Timer(delay, startBackup);
    return selected.future;
  }

  Future<HttpClientResponse?> _open(Uri uri, {HttpClient? client}) async {
    try {
      _event('begin', {'host': uri.host, 'requestedEnd': _initialEnd});
      final request = await (client ?? _client).getUrl(uri);
      headers.forEach(request.headers.set);
      request.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$_initialOffset-${_initialEnd ?? ''}',
      );
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      _event('headers', {
        'status': response.statusCode,
        'host': uri.host,
        'requestedEnd': _initialEnd,
        'contentLength': response.contentLength,
      });
      return response;
    } catch (error) {
      if (_closed || (_selection?.isCompleted ?? false)) {
        _event('cancelled', {
          'reason': _closed ? 'source-closed' : 'hedge-loser',
          'host': uri.host,
        });
      } else {
        _event('error', {'type': error.runtimeType.toString()});
      }
      return null;
    }
  }

  int? _length(HttpClientResponse response) {
    if (response.headers.value(HttpHeaders.contentEncodingHeader) case final v?
        when v != 'identity') {
      return null;
    }
    final length = response.contentLength;
    if (length <= 0) return null;
    if (response.statusCode == 200 && _initialOffset == 0) return length;
    if (response.statusCode != 206) return null;
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
      response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
    );
    if (match == null) return null;
    final total = int.parse(match[3]!);
    final end = int.parse(match[2]!);
    final requestedEnd = _initialEnd;
    return int.parse(match[1]!) == _initialOffset &&
            total > _initialOffset &&
            (end == total - 1 ||
                (requestedEnd != null &&
                    end == math.min(requestedEnd, total - 1))) &&
            length == end - _initialOffset + 1 &&
            (_expectedTotal == null || total == _expectedTotal)
        ? total
        : null;
  }

  Future<void> _redirect(HttpRequest request, String reason) async {
    _event('fallback', {'reason': reason});
    request.response
      ..statusCode = HttpStatus.temporaryRedirect
      ..contentLength = 0;
    request.response.headers.set(HttpHeaders.locationHeader, _original!);
    await request.response.close();
  }

  Future<void> _serve(HttpRequest request) async {
    if (request.uri.path != '/audio' ||
        !const ['GET', 'HEAD'].contains(request.method)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final upstream = await _opening!.timeout(headerWait, onTimeout: () => null);
    if (_closed) return;
    final total = upstream == null ? null : _length(upstream);
    if (upstream == null || total == null) {
      await _redirect(request, 'headers-unavailable-or-unsupported');
      return;
    }
    _resourceLength = total;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final match = range == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    if (range != null && match == null) {
      await _redirect(request, 'range-form');
      return;
    }
    final start = match == null ? 0 : int.parse(match[1]!);
    var end = match == null || match[2]!.isEmpty
        ? total - 1
        : math.min(int.parse(match[2]!), total - 1);
    if (start >= total || start > end) {
      request.response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..contentLength = 0;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$total',
      );
      await request.response.close();
      return;
    }
    final cached =
        start >= _initialOffset && end < _initialOffset + _prefixLength;
    final firstRangeMatches =
        start == _initialOffset ||
        (_initialOffset > 0 &&
            start > _initialOffset &&
            start - _initialOffset <= _prefixLimit);
    if (request.method != 'HEAD' &&
        !cached &&
        (_claimed || !firstRangeMatches)) {
      final resume = _resumeSource;
      if (resume != null &&
          start >= resume._initialOffset &&
          start - resume._initialOffset <= _prefixLimit) {
        _event('resume.claim', {
          'start': start,
          'predictedStart': resume._initialOffset,
        });
        await resume._serve(request);
        return;
      }
      _event('seek.miss', {
        'start': start,
        'end': end,
        'predictedStart': resume?._initialOffset,
      });
      await _redirect(request, 'seek-or-reopen');
      return;
    }
    if (request.method != 'HEAD' && !cached) {
      final availableEnd = _initialOffset + upstream.contentLength - 1;
      if (availableEnd < end) {
        if (range == null) {
          await _redirect(request, 'bounded-initial-without-range');
          return;
        }
        // A 206 response describes the supplied subrange, retaining total file
        // length. FFmpeg can request any further bytes through normal Range.
        end = availableEnd;
        _event('initial.bounded', {'start': start, 'end': end, 'total': total});
      }
    }
    final response = request.response
      ..statusCode = range == null ? HttpStatus.ok : HttpStatus.partialContent
      ..contentLength = end - start + 1
      ..bufferOutput = false
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (range != null) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$total',
      );
    }
    if (upstream.headers.contentType case final type?) {
      response.headers.contentType = type;
    }
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    if (cached) {
      response.add(
        Uint8List.sublistView(
          _prefix,
          start - _initialOffset,
          end + 1 - _initialOffset,
        ),
      );
      await response.close();
      return;
    }
    _claimed = true;
    _event('delivery.begin');
    final body = _bodyWarmup?.stream ?? _bodyRecovery?.stream ?? upstream;
    if (cancelClosedDelivery) {
      var rangeComplete = false;
      Stream<List<int>> rangeBody() async* {
        var position = _initialOffset;
        await for (final chunk in body) {
          if (_closed) break;
          _retainChunk(chunk);
          final from = math.max(0, start - position);
          final to = math.min(chunk.length, end + 1 - position);
          position += chunk.length;
          rangeComplete = position > end;
          if (to > from) {
            deliveredBytes += to - from;
            yield from == 0 && to == chunk.length
                ? chunk
                : chunk.sublist(from, to);
          }
          if (rangeComplete) break;
        }
      }

      try {
        // One subscription propagates downstream cancellation to the upstream
        // iterator. Repeated add/flush calls can silently succeed after the
        // HTTP sink has stopped accepting bytes, leaving the origin draining.
        await response.addStream(rangeBody());
      } finally {
        // This instance's one live response is consumed or abandoned. Keep its
        // server and replay prefix for HEAD/cached seeks/redirects; a predicted
        // resume owns different clients and must remain alive.
        _client.close(force: true);
        _hedgeClient?.close(force: true);
        _bodyWarmup?.close().ignore();
        _bodyRecovery?.close().ignore();
        _event('delivery.upstreamClosed', {
          'rangeComplete': rangeComplete,
          'receivedBytes': receivedBytes,
          'deliveredBytes': deliveredBytes,
        });
      }
    } else if (streamForwarding &&
        start == _initialOffset &&
        end == total - 1) {
      // A single sink subscription preserves socket backpressure without
      // rebuilding the sink's subscription for every small flush. The prefix
      // remains bounded; the rest is never collected into an in-memory body.
      await response.addStream(
        body.map((chunk) {
          _retainChunk(chunk);
          deliveredBytes += chunk.length;
          return chunk;
        }),
      );
    } else {
      var position = _initialOffset;
      await for (final chunk in body) {
        if (_closed) break;
        _retainChunk(chunk);
        final from = math.max(0, start - position);
        final to = math.min(chunk.length, end + 1 - position);
        if (to > from) {
          response.add(
            from == 0 && to == chunk.length ? chunk : chunk.sublist(from, to),
          );
          deliveredBytes += to - from;
          await response.flush();
        }
        position += chunk.length;
        if (position > end) break;
      }
    }
    await response.close();
    _event('delivery.end', {
      'receivedBytes': receivedBytes,
      'deliveredBytes': deliveredBytes,
    });
  }

  void _retainChunk(List<int> chunk) {
    if (receivedBytes == 0) _event('firstChunk', {'bytes': chunk.length});
    receivedBytes += chunk.length;
    if (_transferTrace) {
      final elapsed = _transferClock!.elapsedMicroseconds;
      if (elapsed <= 8000000 && elapsed - _lastProgressUs >= 100000) {
        _lastProgressUs = elapsed;
        _event('body.progress', {
          'workerElapsedUs': elapsed,
          'workerUtcUs': DateTime.now().microsecondsSinceEpoch,
          'receivedBytes': receivedBytes,
          'deliveredBytesBeforeChunk': deliveredBytes,
        });
      }
    }
    final retained = math.min(chunk.length, _prefixLimit - _prefixLength);
    if (retained > 0) {
      _prefix.setRange(_prefixLength, _prefixLength + retained, chunk);
      _prefixLength += retained;
      _publishResumeIndex();
      _prepareResume();
    }
  }

  void _publishResumeIndex() {
    if (_indexPublished || onResumeIndex == null || _resourceLength == null) {
      return;
    }
    final prefix = Uint8List.sublistView(
      _prefix,
      0,
      math.min(_prefixLength, 64 * 1024),
    );
    // Collect the index on a zero-position first watch too, without issuing a
    // target request. A subsequent resume chooses its own current position.
    if (mp4ResumeRange(
          prefix,
          const Duration(microseconds: 1),
          totalBytes: _resourceLength!,
        ) ==
        null) {
      return;
    }
    _indexPublished = true;
    onResumeIndex!(
      ResumeIndexHint(
        prefix: Uint8List.fromList(prefix),
        totalBytes: _resourceLength!,
      ),
    );
  }

  /// Align a slave track before its single speculative response is started.
  /// A late update never replaces an already opened response or native seek.
  void alignResumeTo(Duration position) {
    if (_closed || _resumeSource != null || position < Duration.zero) return;
    _alignedResumePosition = position;
    _resumeScannedLength = 0;
    _event('resume.align', {
      'requestedUs': resumePosition.inMicroseconds,
      'predictionTargetUs': position.inMicroseconds,
    });
    _prepareResumeHint();
    _prepareResume();
  }

  void _prepareResumeHint() {
    final hint = resumeIndexHint;
    if (_closed ||
        _hintAttempted ||
        hint == null ||
        _original == null ||
        resumePosition <= Duration.zero ||
        _resumeSource != null ||
        (waitForResumeAlignment && _alignedResumePosition == null)) {
      return;
    }
    _hintAttempted = true;
    final range = mp4ResumeRange(
      hint.prefix,
      _alignedResumePosition ?? resumePosition,
      totalBytes: hint.totalBytes,
      preferPreviousAtBoundary: !resumePresentationTime,
    );
    if (range == null || range.offset < _prefixLimit) return;
    _event('resume.indexHint', {'bytes': hint.prefix.length});
    _openResume(range, hint.totalBytes, fromHint: true);
  }

  void _prepareResume() {
    if (_closed ||
        resumePosition <= Duration.zero ||
        (waitForResumeAlignment && _alignedResumePosition == null) ||
        _resumeSource != null ||
        _resourceLength == null ||
        _resumeScannedLength == _prefixLength) {
      return;
    }
    _resumeScannedLength = _prefixLength;
    final range = mp4ResumeRange(
      Uint8List.sublistView(_prefix, 0, _prefixLength),
      _alignedResumePosition ?? resumePosition,
      totalBytes: _resourceLength!,
      preferPreviousAtBoundary: !resumePresentationTime,
    );
    if (range == null || range.offset < _prefixLimit) return;
    _openResume(range, _resourceLength!);
  }

  void _openResume(
    Mp4ResumeRange range,
    int totalBytes, {
    bool fromHint = false,
  }) {
    // Keep reading while the decoder is being prepared when the selected
    // segment is larger than the replay prefix. Claim never waits for this
    // limit, and unusually large segments remain bounded to 1 MiB.
    final bodyWarmupLimit = resumeSegmentBodyWarmup
        ? math.max(_prefixLimit, math.min(range.length, 1024 * 1024))
        : _prefixLimit;
    final resume = _resumeSource =
        ParallelAudioSource(
            headers: headers,
            headerWait: headerWait,
            streamForwarding: streamForwarding,
            cancelClosedDelivery: cancelClosedDelivery,
            onEvent: (name, data) => _event(
              'resume.${name.substring('audio.prefetch.'.length)}',
              data,
            ),
          )
          .._initialOffset = range.offset
          .._expectedTotal = totalBytes
          .._selectionBodyLimit = resumeBodyHedge ? bodyWarmupLimit : null
          .._original = _original;
    if (_transferTrace) resume._transferClock = Stopwatch()..start();
    _event('resume.plan', {
      'requestedUs': resumePosition.inMicroseconds,
      'presentationTimePrediction': resumePresentationTime,
      'predictionTargetUs':
          (_alignedResumePosition ?? resumePosition).inMicroseconds,
      'segmentStartUs': range.startUs,
      'offset': range.offset,
      'segmentBytes': range.length,
      'bodyWarmupLimit': resumeBodyWarmup ? bodyWarmupLimit : 0,
    });
    // The exact native Range still governs consumption. Optional body warming
    // reads up to the selected bound plus one chunk, then pauses the upstream.
    // This is separate from the existing 256 KiB replay prefix filled on claim.
    // A fast initialization response does not guarantee a fast target range.
    // For fresh indexes retain its winner as preferred, but allow the other
    // current API endpoint to compete. Never race an endpoint against itself.
    final hedge = fromHint ? hedgeResumePrefetch : hedgeFreshResumePrefetch;
    final backup = hedge
        ? [_resumePrimary, _resumeBackup]
              .whereType<Uri>()
              .where(
                (uri) => uri.authority != _original!.authority,
              )
              .firstOrNull
        : null;
    final opening = backup == null
        ? resume._open(_original!)
        : resume._openHedged(_original!, backup, _resumeHedgeDelay);
    resume._opening = opening.then((response) {
      final alternate = [_resumePrimary, _resumeBackup]
          .whereType<Uri>()
          .where((uri) => uri.authority != resume._original!.authority)
          .firstOrNull;
      if (resumeBodyFailover &&
          alternate != null &&
          resume._bodyWarmup == null &&
          !resume._closed &&
          response != null &&
          resume._length(response) != null) {
        resume._bodyRecovery = ResumeBodyRecovery(
          source: response,
          alternate: alternate,
          headers: headers,
          offset: range.offset,
          total: totalBytes,
          progressRace: resumeBodyProgressRace,
          closePrimary: () {
            resume._client.close(force: true);
            resume._hedgeClient?.close(force: true);
          },
          onEvent: (name, data) => resume._event('bodyRecovery.$name', data),
        );
        resume._event('bodyRecovery.armed', {
          'offset': range.offset,
          'progressRace': resumeBodyProgressRace,
        });
      }
      if (resumeBodyWarmup &&
          resume._bodyWarmup == null &&
          !resume._closed &&
          response != null &&
          resume._length(response) != null) {
        resume._bodyWarmup = BoundedBodyWarmup(
          resume._bodyRecovery?.stream ?? response,
          limit: bodyWarmupLimit,
          onEvent: (name, data) => resume._event('bodyWarmup.$name', data),
        );
      }
      return response;
    });
    onResumeSegment?.call(Duration(microseconds: range.startUs));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final body in _pendingInitialBodies.toList()) {
      body.close().ignore();
    }
    _bodyWarmup?.close().ignore();
    _bodyRecovery?.close().ignore();
    _hedgeTimer?.cancel();
    if (_selection case final selection? when !selection.isCompleted) {
      selection.complete(null);
    }
    _client.close(force: true);
    _hedgeClient?.close(force: true);
    _resumeSource?.close();
    _resumeSource = null;
    _server?.close(force: true).ignore();
    _event('closed', {
      'receivedBytes': receivedBytes,
      'deliveredBytes': deliveredBytes,
    });
  }
}
