import 'dart:async';
import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
import 'package:media_kit/media_kit.dart';

/// Observes one load through a separate, read-only mpv client.
///
/// Construct immediately before a serialized [NativePlayer.open] call. This
/// observes mpv's playback restart, not Flutter's presentation of the texture;
/// callers must also wait for their output geometry and keep the texture mounted.
/// Each load, including reopening the same URI, needs a new gate.
class MpvFrameGate {
  MpvFrameGate(
    this._player, {
    required String source,
    Duration timeout = const Duration(seconds: 30),
  }) : _protocol = MpvFrameGateProtocol(
         source: source,
         normalizedSource: Media(source).uri,
       ) {
    // Loading can fail before the owner reaches `await ready`. Observe errors
    // immediately, while preserving them on the original future for its owner.
    _completion.future.ignore();
    try {
      if (timeout <= Duration.zero) {
        throw ArgumentError.value(timeout, 'timeout', 'Must be positive');
      }
      _player.throwIfDisposed();
      _client = NativePlayer.mpv.mpv_create_weak_client(_player.ctx, nullptr);
      if (_client == nullptr) {
        throw const MpvFrameGateException('Could not create frame observer');
      }
      // Subscription changes apply only to this weak client, never the player.
      for (var id = 0; id <= mpv.mpv_event_id.MPV_EVENT_HOOK; id++) {
        NativePlayer.mpv.mpv_request_event(_client, id, 0);
      }
      for (final id in _observedEvents) {
        final result = NativePlayer.mpv.mpv_request_event(_client, id, 1);
        if (result < 0) {
          throw MpvFrameGateException(
            'Could not subscribe to frame event $id (mpv $result)',
          );
        }
      }
      _drainBeforeLoad();
      _trace('armed');
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _poll(),
      );
      _timeoutTimer = Timer(timeout, () {
        _fail(
          TimeoutException(
            'Timed out waiting for the new video frame',
            timeout,
          ),
        );
      });
    } catch (error, stack) {
      _fail(error, stack);
    }
  }

  final NativePlayer _player;
  final int _id = ++_nextId;
  final MpvFrameGateProtocol _protocol;
  final Completer<void> _completion = Completer<void>();
  Pointer<mpv.mpv_handle> _client = nullptr;
  Timer? _pollTimer;
  Timer? _timeoutTimer;

  static int _nextId = 0;
  static const _maxEventsPerPoll = 64;
  static const _observedEvents = [
    mpv.mpv_event_id.MPV_EVENT_START_FILE,
    mpv.mpv_event_id.MPV_EVENT_FILE_LOADED,
    mpv.mpv_event_id.MPV_EVENT_PLAYBACK_RESTART,
    mpv.mpv_event_id.MPV_EVENT_SEEK,
    mpv.mpv_event_id.MPV_EVENT_VIDEO_RECONFIG,
    mpv.mpv_event_id.MPV_EVENT_END_FILE,
    mpv.mpv_event_id.MPV_EVENT_SHUTDOWN,
    mpv.mpv_event_id.MPV_EVENT_QUEUE_OVERFLOW,
  ];

  Future<void> get ready => _completion.future;

  void _drainBeforeLoad() {
    for (var count = 0; count < _maxEventsPerPoll; count++) {
      final event = NativePlayer.mpv.mpv_wait_event(_client, 0).ref;
      if (event.event_id == mpv.mpv_event_id.MPV_EVENT_NONE) return;
      if (event.event_id == mpv.mpv_event_id.MPV_EVENT_SHUTDOWN) {
        throw const MpvFrameGateException('Player stopped before video load');
      }
    }
    // Do not arm against a queue whose pre-load boundary was not established.
    throw const MpvFrameGateException('Could not clear old frame events');
  }

  void _poll() {
    if (_completion.isCompleted) return;
    try {
      _player.throwIfDisposed();
      for (var count = 0; count < _maxEventsPerPoll; count++) {
        var event = NativePlayer.mpv.mpv_wait_event(_client, 0).ref;
        if (event.event_id == mpv.mpv_event_id.MPV_EVENT_NONE) {
          if (!_protocol.hasRestartCandidate) return;
          final path = _player.getProperty('path');
          final vo = _player.getProperty('current-vo');
          final seeking = _player.getProperty('seeking') == 'yes';
          // Property reads synchronize with mpv's core. A VO change during
          // those reads may have queued RECONFIG/SEEK after the old restart.
          // Drain those events before accepting the candidate.
          event = NativePlayer.mpv.mpv_wait_event(_client, 0).ref;
          if (event.event_id == mpv.mpv_event_id.MPV_EVENT_NONE) {
            _protocol.onQueueDrained(
              path: path,
              currentVo: vo,
              seeking: seeking,
            );
            if (_protocol.isReady) {
              _trace('ready vo=$vo');
              _releaseClient();
              _completion.complete();
            }
            return;
          }
        }
        switch (event.event_id) {
          case mpv.mpv_event_id.MPV_EVENT_START_FILE:
            final entry = event.data
                .cast<mpv.mpv_event_start_file>()
                .ref
                .playlist_entry_id;
            _protocol.onStartFile(entry);
            _trace('start entry=$entry');
          case mpv.mpv_event_id.MPV_EVENT_FILE_LOADED:
            _protocol.onFileLoaded(_player.getProperty('path'));
            _trace('loaded matched=${_protocol.hasMatchingFile}');
          case mpv.mpv_event_id.MPV_EVENT_PLAYBACK_RESTART:
            final vo = _player.getProperty('current-vo');
            _protocol.onPlaybackRestart(
              _player.getProperty('path'),
              currentVo: vo,
            );
            _trace('restart vo=$vo candidate=${_protocol.hasRestartCandidate}');
          case mpv.mpv_event_id.MPV_EVENT_SEEK:
          case mpv.mpv_event_id.MPV_EVENT_VIDEO_RECONFIG:
            _protocol.onOutputInvalidated();
            _trace('output-invalidated event=${event.event_id}');
          case mpv.mpv_event_id.MPV_EVENT_END_FILE:
            final end = event.data.cast<mpv.mpv_event_end_file>().ref;
            _protocol.onEndFile(
              end.playlist_entry_id,
              redirected:
                  end.reason ==
                  mpv.mpv_end_file_reason.MPV_END_FILE_REASON_REDIRECT,
              reason: end.reason,
              errorCode: end.error,
            );
            _trace('end entry=${end.playlist_entry_id} reason=${end.reason}');
          case mpv.mpv_event_id.MPV_EVENT_SHUTDOWN:
            throw const MpvFrameGateException(
              'Player stopped before video was ready',
            );
          case mpv.mpv_event_id.MPV_EVENT_QUEUE_OVERFLOW:
            throw const MpvFrameGateException(
              'Frame observer lost playback events',
            );
        }
        if (_protocol.error case final error?) {
          _fail(error);
          return;
        }
      }
    } catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (_completion.isCompleted) return;
    _trace('failed type=${error.runtimeType}');
    _releaseClient();
    _completion.completeError(error, stack ?? StackTrace.current);
  }

  void _trace(String event) {
    if (kDebugMode) debugPrint('[PLAYBACK_FRAME] gate=$_id $event');
  }

  void _releaseClient() {
    _pollTimer?.cancel();
    _timeoutTimer?.cancel();
    _pollTimer = null;
    _timeoutTimer = null;
    final client = _client;
    _client = nullptr;
    if (client != nullptr) NativePlayer.mpv.mpv_destroy(client);
  }

  /// Cancels an unfinished wait with [MpvFrameGateCancelled]. Safe to repeat.
  void dispose() {
    _fail(const MpvFrameGateCancelled());
  }
}

class MpvFrameGateException implements Exception {
  const MpvFrameGateException(this.message);

  final String message;

  @override
  String toString() => 'MpvFrameGateException: $message';
}

class MpvFrameGateCancelled extends MpvFrameGateException {
  const MpvFrameGateCancelled() : super('Video frame wait cancelled');
}

/// Pure event protocol, separated from FFI so stale-load handling is testable.
///
/// The owner establishes the queue boundary before a new open. Playlist entry
/// IDs distinguish old END_FILE events, even when the same URI is reopened.
class MpvFrameGateProtocol {
  MpvFrameGateProtocol({required String source, String? normalizedSource})
    : _sources = {source, ?normalizedSource};

  final Set<String> _sources;
  int? _entryId;
  bool _matchedFileLoaded = false;
  String? _restartVo;
  bool _isReady = false;
  MpvFrameGateException? _error;

  bool get isReady => _isReady;
  MpvFrameGateException? get error => _error;
  bool get isFinished => _isReady || _error != null;
  bool get hasMatchingFile => _matchedFileLoaded;
  bool get hasRestartCandidate => _restartVo != null;

  void onStartFile(int entryId) {
    if (isFinished) return;
    _entryId = entryId;
    _matchedFileLoaded = false;
    _restartVo = null;
  }

  void onFileLoaded(String path) {
    if (isFinished || _entryId == null) return;
    _matchedFileLoaded = _sources.contains(path);
    _restartVo = null;
  }

  void onPlaybackRestart(String path, {required String currentVo}) {
    if (isFinished || !_matchedFileLoaded) return;
    _restartVo = null;
    if (!_sources.contains(path)) {
      _matchedFileLoaded = false;
      return;
    }
    // media_kit initially decodes with vo=null, then attaches its real output.
    // That null output can finish a restart without producing a visible frame.
    if (currentVo.isNotEmpty && currentVo != 'null') _restartVo = currentVo;
  }

  void onOutputInvalidated() {
    if (!isFinished) _restartVo = null;
  }

  /// Accept only after the queue is empty and mpv still uses that output.
  ///
  /// UPDATE_VO rebuilds the output and queues an exact refresh seek in mpv;
  /// its later restart is required. A reconfig event alone never proves a frame.
  void onQueueDrained({
    required String path,
    required String currentVo,
    required bool seeking,
  }) {
    if (isFinished || _restartVo == null) return;
    if (seeking || currentVo != _restartVo || !_sources.contains(path)) {
      _restartVo = null;
      return;
    }
    _isReady = true;
  }

  void onEndFile(
    int entryId, {
    bool redirected = false,
    int reason = 0,
    int errorCode = 0,
  }) {
    if (isFinished || _entryId == null || _entryId != entryId) return;
    _entryId = null;
    _matchedFileLoaded = false;
    _restartVo = null;
    if (!redirected) {
      _error = MpvFrameGateException(
        'Video ended before its first frame (reason $reason, mpv $errorCode)',
      );
    }
  }
}
