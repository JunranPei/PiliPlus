import 'dart:async';
import 'dart:ffi';

import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';
import 'package:PiliPlus/plugin/pl_player/playback/startup_wait_trace.dart';
import 'package:ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
import 'package:media_kit/media_kit.dart';

/// Independent property reads, with every reply correlated to its request.
/// The owner awaits a whole snapshot before draining frame events again.
class MpvAsyncPropertyReader {
  MpvAsyncPropertyReader({
    required int Function(int, String) request,
    required void Function() release,
    this.traceClientId,
  }) : _request = request,
       _release = release;

  factory MpvAsyncPropertyReader.native(NativePlayer player) {
    player.throwIfDisposed();
    final client = NativePlayer.mpv.mpv_create_weak_client(player.ctx, nullptr);
    if (client == nullptr) {
      throw StateError('Could not create asynchronous property observer');
    }
    // This client only consumes request replies, not the frame event queue.
    for (var id = 0; id <= mpv.mpv_event_id.MPV_EVENT_HOOK; id++) {
      NativePlayer.mpv.mpv_request_event(client, id, 0);
    }
    Timer? timer;
    late final MpvAsyncPropertyReader reader;
    reader = MpvAsyncPropertyReader(
      traceClientId: StartupWaitTrace.enabled
          ? NativePlayer.mpv.mpv_client_id(client)
          : null,
      request: (id, name) {
        final nativeName = name.toNativeUtf8();
        try {
          return NativePlayer.mpv.mpv_get_property_async(
            client,
            id,
            nativeName.cast<Uint8>(),
            mpv.mpv_format.MPV_FORMAT_STRING,
          );
        } finally {
          calloc.free(nativeName);
        }
      },
      release: () {
        timer?.cancel();
        NativePlayer.mpv.mpv_destroy(client);
      },
    );
    timer = Timer.periodic(const Duration(milliseconds: 4), (_) {
      try {
        if (StartupWaitTrace.active && reader._pending.isNotEmpty) {
          PlaybackDiagnostics.event('mpv.property.poll', {
            'clientId': reader.traceClientId,
            'pending': reader._pending.length,
          });
        }
        player.throwIfDisposed();
        for (var count = 0; count < 64; count++) {
          final event = NativePlayer.mpv.mpv_wait_event(client, 0).ref;
          if (event.event_id == mpv.mpv_event_id.MPV_EVENT_NONE) return;
          if (event.event_id == mpv.mpv_event_id.MPV_EVENT_GET_PROPERTY_REPLY) {
            // Copy the string before the next wait_event invalidates its data.
            String? value;
            if (event.error >= 0 && event.data != nullptr) {
              final property = event.data.cast<mpv.mpv_event_property>().ref;
              if (property.format == mpv.mpv_format.MPV_FORMAT_STRING &&
                  property.data != nullptr) {
                final string = property.data.cast<Pointer<Utf8>>().value;
                if (string != nullptr) value = string.toDartString();
              }
            }
            reader.reply(
              event.reply_userdata,
              value: value,
              error: event.error,
            );
          } else if (event.event_id == mpv.mpv_event_id.MPV_EVENT_SHUTDOWN ||
              event.event_id == mpv.mpv_event_id.MPV_EVENT_QUEUE_OVERFLOW) {
            throw StateError('Property observer stopped or lost replies');
          }
        }
      } catch (error, stack) {
        reader.dispose(error, stack);
      }
    });
    return reader;
  }

  final int Function(int, String) _request;
  final void Function() _release;
  final int? traceClientId;
  final Map<int, Completer<String>> _pending = {};
  int _id = 0;
  bool _disposed = false;

  Future<String> read(String name) {
    if (_disposed) {
      return Future.error(StateError('Property observer disposed'));
    }
    final pending = Completer<String>();
    final id = ++_id;
    _pending[id] = pending;
    try {
      if (StartupWaitTrace.active) {
        PlaybackDiagnostics.event('mpv.property.request.begin', {
          'clientId': traceClientId,
          'propertyRequestId': id,
          'property': name,
        });
      }
      final result = _request(id, name);
      if (StartupWaitTrace.active) {
        PlaybackDiagnostics.event('mpv.property.request.submitted', {
          'clientId': traceClientId,
          'propertyRequestId': id,
          'result': result,
        });
      }
      if (result < 0) {
        _pending.remove(id);
        pending.completeError(
          StateError('Could not request mpv property ($result)'),
        );
      }
    } catch (error, stack) {
      _pending.remove(id);
      pending.completeError(error, stack);
    }
    return pending.future;
  }

  void reply(int id, {String? value, int error = 0}) {
    if (_disposed) return;
    if (StartupWaitTrace.active) {
      PlaybackDiagnostics.event('mpv.property.reply', {
        'clientId': traceClientId,
        'propertyRequestId': id,
        'error': error,
      });
    }
    final pending = _pending.remove(id);
    if (pending == null) return;
    // Match NativePlayer.getProperty: an unavailable path/VO is empty and
    // cannot establish readiness. Submitting a request unsuccessfully fails.
    pending.complete(error < 0 ? '' : (value ?? ''));
  }

  void dispose([Object? error, StackTrace? stack]) {
    if (_disposed) return;
    _disposed = true;
    final pending = _pending.values.toList();
    _pending.clear();
    for (final request in pending) {
      request.completeError(
        error ?? StateError('Property observer disposed'),
        stack,
      );
    }
    _release();
  }
}
