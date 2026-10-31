import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Streams immediately. A single alternate Range request may replace a stalled
/// resume body only after its fresh overlap matches bytes already delivered.
/// Paused consumers are not network stalls; neither timer runs while paused.
class ResumeBodyRecovery {
  ResumeBodyRecovery({
    required this.source,
    required this.alternate,
    required this.headers,
    required this.offset,
    required this.total,
    required this.closePrimary,
    this.progressRace = false,
    this.stallAfter = const Duration(milliseconds: 350),
    this.retryTimeout = const Duration(seconds: 2),
    this.onEvent,
  }) : _tail = Uint8List(progressRace ? 256 * 1024 : 64 * 1024) {
    _output = StreamController<List<int>>(
      onListen: _listen,
      onPause: () => _pause(true),
      onResume: () => _pause(false),
      onCancel: close,
    );
  }

  final Stream<List<int>> source;
  final Uri alternate;
  final Map<String, String> headers;
  final int offset;
  final int total;
  final void Function() closePrimary;
  final bool progressRace;
  final Duration stallAfter;
  final Duration retryTimeout;
  final void Function(String, Map<String, Object?>)? onEvent;
  late final StreamController<List<int>> _output;
  StreamSubscription<List<int>>? _primary;
  StreamSubscription<List<int>>? _backup;
  HttpClient? _retryClient;
  Timer? _stallTimer;
  Timer? _retryTimer;
  Timer? _progressTimer;
  bool _progressSatisfied = false;
  final Uint8List _tail;
  int _tailCursor = 0;
  int _tailLength = 0;
  int _received = 0;
  bool _attempted = false;
  bool _promoted = false;
  bool _paused = false;
  bool _closed = false;

  Stream<List<int>> get stream => _output.stream;

  void _event(String name, [Map<String, Object?> data = const {}]) =>
      onEvent?.call(name, data);

  void _listen() {
    if (_closed) return;
    _primary = source.listen(
      (chunk) {
        if (_closed || _promoted) return;
        if (_retryClient != null && !progressRace) _reject('primary-resumed');
        _emit(chunk);
        _armStall();
        _armProgress();
      },
      onError: (Object error, StackTrace stack) {
        if (!_closed && !_promoted) _fail(error, stack);
      },
      onDone: () {
        if (!_closed && !_promoted) _finish();
      },
    );
  }

  void _emit(List<int> chunk) {
    if (_closed || chunk.isEmpty) return;
    if (_received + chunk.length > total - offset) {
      _fail(const HttpException('Resume body exceeds validated range'));
      return;
    }
    _received += chunk.length;
    if (!_attempted || (progressRace && !_promoted)) {
      // Bounded replay history, including primary progress during a race.
      final count = math.min(chunk.length, _tail.length);
      final from = chunk.length - count;
      final first = math.min(count, _tail.length - _tailCursor);
      _tail.setRange(_tailCursor, _tailCursor + first, chunk, from);
      if (first < count) _tail.setRange(0, count - first, chunk, from + first);
      _tailCursor = (_tailCursor + count) % _tail.length;
      _tailLength = math.min(_tailLength + count, _tail.length);
    }
    _output.add(chunk);
  }

  void _armStall() {
    _stallTimer?.cancel();
    // A mid-body retry needs real overlap. Initial headers/body failures keep
    // the original HTTP/FFmpeg fallback; there is no unverified splice.
    if (_closed ||
        _paused ||
        _attempted ||
        _received == 0 ||
        _received >= total - offset) {
      return;
    }
    _stallTimer = Timer(stallAfter, () => unawaited(_retry()));
  }

  void _armRetryTimeout() {
    _retryTimer?.cancel();
    if (!_closed && !_paused && !_promoted && _retryClient != null) {
      _retryTimer = Timer(retryTimeout, () => _reject('timeout'));
    }
  }

  void _armProgress() {
    if (!progressRace ||
        _closed ||
        _paused ||
        _attempted ||
        _progressSatisfied ||
        _received == 0) {
      return;
    }
    if (_received >= 256 * 1024 || _received >= total - offset) {
      _progressSatisfied = true;
      _progressTimer?.cancel();
      _progressTimer = null;
      return;
    }
    // Delivery never waits for this timer. Only a slow active prefix races.
    _progressTimer ??= Timer(stallAfter, () {
      _progressTimer = null;
      if (!_closed && !_paused && !_attempted && !_progressSatisfied) {
        unawaited(_retry(reason: 'slow-prefix-progress'));
      }
    });
  }

  void _pause(bool paused) {
    if (_closed || _paused == paused) return;
    _paused = paused;
    if (paused) {
      _stallTimer?.cancel();
      _retryTimer?.cancel();
      _progressTimer?.cancel();
      _progressTimer = null;
      _primary?.pause();
      _backup?.pause();
    } else {
      _primary?.resume();
      _backup?.resume();
      _armStall();
      _armRetryTimeout();
      _armProgress();
    }
  }

  Future<void> _retry({String reason = 'no-progress'}) async {
    if (_closed || _paused || _attempted) return;
    _attempted = true;
    _stallTimer?.cancel();
    _progressTimer?.cancel();
    _progressTimer = null;
    final checkpoint = _received;
    final overlap = Uint8List(math.min(_tailLength, 64 * 1024));
    final begin = (_tailCursor - overlap.length + _tail.length) % _tail.length;
    final first = math.min(overlap.length, _tail.length - begin);
    overlap.setRange(0, first, _tail, begin);
    if (first < overlap.length) overlap.setRange(first, overlap.length, _tail);
    final start = offset + checkpoint - overlap.length;
    final client = _retryClient = HttpClient()..autoUncompress = false;
    _event('begin', {
      'reason': reason,
      'receivedBytes': checkpoint,
      'overlapBytes': overlap.length,
      'rangeStart': start,
      'stallMs': stallAfter.inMilliseconds,
    });
    _armRetryTimeout();
    try {
      final request = await client.getUrl(alternate);
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      if (_closed || _retryClient != client) return;
      if (response.statusCode != HttpStatus.partialContent ||
          response.contentLength != total - start ||
          response.headers.value(HttpHeaders.contentRangeHeader) !=
              'bytes $start-${total - 1}/$total' ||
          ![null, 'identity'].contains(
            response.headers.value(HttpHeaders.contentEncodingHeader),
          )) {
        _reject('range-mismatch');
        return;
      }
      var compared = 0;
      _backup = response.listen(
        (chunk) {
          if (_closed || _retryClient != client) return;
          var from = 0;
          while (!_promoted &&
              from < chunk.length &&
              checkpoint - overlap.length + compared < _received) {
            final position = checkpoint - overlap.length + compared;
            int expected;
            if (compared < overlap.length) {
              expected = overlap[compared];
            } else {
              final retainedStart = _received - _tailLength;
              if (position < retainedStart) {
                _reject('comparison-window-exceeded');
                return;
              }
              expected =
                  _tail[(_tailCursor -
                          _tailLength +
                          position -
                          retainedStart +
                          _tail.length) %
                      _tail.length];
            }
            if (expected != chunk[from++]) {
              _reject('overlap-mismatch');
              return;
            }
            compared++;
          }
          if (from == chunk.length) return;
          if (!_promoted) {
            // Catch up to CURRENT primary progress, not just the snapshot.
            // Events are serialized, so no primary byte is skipped/duplicated.
            assert(_received == checkpoint - overlap.length + compared);
            _promoted = true;
            _retryTimer?.cancel();
            _primary?.cancel().ignore();
            _primary = null;
            closePrimary();
            _event('switched', {
              'receivedBytes': _received,
              'matchedBytes': compared,
              'nextOffset': offset + _received,
            });
          }
          _emit(from == 0 ? chunk : chunk.sublist(from));
        },
        onError: (Object error, StackTrace stack) {
          if (_closed || _retryClient != client) return;
          if (_promoted) {
            _fail(error, stack);
          } else {
            _reject('body-error');
          }
        },
        onDone: () {
          if (_closed || _retryClient != client) return;
          if (_promoted) {
            _finish();
          } else {
            _reject('short-overlap');
          }
        },
      );
      if (_paused) _backup!.pause();
    } catch (_) {
      if (!_closed && _retryClient == client) _reject('open-error');
    }
  }

  void _reject(String reason) {
    _event('rejected', {'reason': reason, 'receivedBytes': _received});
    _retryTimer?.cancel();
    _backup?.cancel().ignore();
    _backup = null;
    _retryClient?.close(force: true);
    _retryClient = null;
  }

  void _finish() {
    if (_received != total - offset) {
      _fail(const HttpException('Resume body ended before validated length'));
    } else {
      close().ignore();
    }
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (_closed) return;
    _output.addError(error, stack);
    close().ignore();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _stallTimer?.cancel();
    _retryTimer?.cancel();
    _progressTimer?.cancel();
    _retryClient?.close(force: true);
    _retryClient = null;
    // Closing before a consumer subscribes must never await that consumer.
    _output.close().ignore();
    await Future.wait([
      if (_primary != null) _primary!.cancel(),
      if (_backup != null) _backup!.cancel(),
    ]);
    _event('closed', {'receivedBytes': _received, 'switched': _promoted});
  }
}
