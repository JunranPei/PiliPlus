import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:PiliPlus/plugin/pl_player/pip_diagnostics.dart';

enum AndroidPipPhase { idle, entering, active }

/// Dart facade for the native PiP coordinator.
///
/// The native Activity is the source of truth.  This object only mirrors its
/// state and serializes the few commands that can affect a transition.
final class AndroidPipController extends ChangeNotifier {
  AndroidPipController._() {
    _channel.setMethodCallHandler(_onMethodCall);
    if (Platform.isAndroid) {
      unawaited(_loadState());
    }
  }

  static final AndroidPipController instance = AndroidPipController._();

  static const MethodChannel _channel = MethodChannel(
    'com.personal.piliplus/pip_v2',
  );

  AndroidPipPhase _phase = AndroidPipPhase.idle;
  int _generation = 0;
  String? _lastReason;
  bool _autoEnterPending = false;
  bool _renderHostLocked = false;
  Future<void> _lastCommand = Future<void>.value();
  Rect? _sourceRect;

  Rect? get sourceRect => _sourceRect;

  AndroidPipPhase get phase => _phase;
  int get generation => _generation;
  String? get lastReason => _lastReason;
  bool get isActive => _phase == AndroidPipPhase.active;
  bool get isEntering => _phase == AndroidPipPhase.entering;
  bool get renderHostLocked => _renderHostLocked;
  bool get protectsPlayback =>
      _phase != AndroidPipPhase.idle || _autoEnterPending || _renderHostLocked;

  Future<void> _loadState() async {
    try {
      final state = await _channel.invokeMapMethod<String, dynamic>('getState');
      if (state != null) _applyState(state);
    } on MissingPluginException {
      // The controller is also constructed on desktop and in Flutter tests.
    } on PlatformException catch (error) {
      debugPrint('[PIP_V2] getState failed: ${error.code}');
    }
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method == 'stateChanged' && call.arguments is Map) {
      _applyState(Map<String, dynamic>.from(call.arguments as Map));
    }
    return null;
  }

  void _applyState(Map<String, dynamic> state) {
    PipDiagnostics.arm('stateChanged');
    PipDiagnostics.event('state.receive', {
      'before': _phase.name,
      'beforeGeneration': _generation,
      'native': state,
    });
    final next = switch (state['phase']) {
      'entering' => AndroidPipPhase.entering,
      'active' => AndroidPipPhase.active,
      _ => AndroidPipPhase.idle,
    };
    final generation = (state['generation'] as num?)?.toInt() ?? _generation;
    final reason = state['reason'] as String?;
    final autoEnterPending = state['autoEnterPending'] as bool? ?? false;
    final renderHostLocked = state['renderHostLocked'] as bool? ?? false;
    if (next == _phase &&
        generation == _generation &&
        reason == _lastReason &&
        autoEnterPending == _autoEnterPending &&
        renderHostLocked == _renderHostLocked) {
      return;
    }
    _phase = next;
    _generation = generation;
    _lastReason = reason;
    _autoEnterPending = autoEnterPending;
    _renderHostLocked = renderHostLocked;
    debugPrint(
      '[PIP_V2] phase=${_phase.name} generation=$_generation reason=$reason',
    );
    notifyListeners();
    PipDiagnostics.snapshot('state.notified');
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) {
    PipDiagnostics.event('command.queued', {
      'method': method,
      'arguments': arguments,
    });
    final command = _lastCommand.then((_) async {
      try {
        PipDiagnostics.event('command.begin', {'method': method});
        final result = await _channel.invokeMethod<T>(method, arguments);
        PipDiagnostics.event('command.end', {
          'method': method,
          'result': result,
        });
        return result;
      } on MissingPluginException {
        return null;
      } on PlatformException catch (error) {
        debugPrint('[PIP_V2] $method failed: ${error.code}');
        return null;
      }
    });
    // A failed command still reports its error to its own caller. Do not let
    // that error permanently poison the queue for all later PiP commands.
    _lastCommand = command.then<void>((_) {}, onError: (Object error, StackTrace stack) {
      PipDiagnostics.event('command.failure', {
        'method': method,
        'error': error.toString(),
        'stack': stack.toString(),
      });
    });
    return command;
  }

  Future<bool> configure({
    required int width,
    required int height,
    required bool autoEnter,
    required bool isLive,
    required bool isPlaying,
    Rect? sourceRect,
  }) async {
    if (!Platform.isAndroid) return false;
    if (!protectsPlayback && sourceRect != null) _sourceRect = sourceRect;
    final result = await _invoke<bool>('configure', {
      'width': width,
      'height': height,
      'autoEnter': autoEnter,
      'isLive': isLive,
      'isPlaying': isPlaying,
      if (sourceRect != null) 'sourceRect': _rectMap(sourceRect),
    });
    return result ?? false;
  }

  Future<bool> setSourceRect(Rect rect) async {
    if (!Platform.isAndroid) return false;
    if (protectsPlayback) return false;
    _sourceRect = rect;
    return (await _invoke<bool>('setSourceRect', _rectMap(rect))) ?? false;
  }

  Future<bool> enter() async {
    if (!Platform.isAndroid) return false;
    return (await _invoke<bool>('enter')) ?? false;
  }

  Future<bool> updateActions({
    required bool isLive,
    required bool isPlaying,
  }) async {
    if (!Platform.isAndroid) return false;
    return (await _invoke<bool>('updateActions', {
          'isLive': isLive,
          'isPlaying': isPlaying,
        })) ??
        false;
  }

  Future<bool> disableAutoEnter() async {
    if (!Platform.isAndroid) return false;
    return (await _invoke<bool>('disableAutoEnter')) ?? false;
  }

  Map<String, int> _rectMap(Rect rect) => {
    'left': rect.left.round(),
    'top': rect.top.round(),
    'width': rect.width.round(),
    'height': rect.height.round(),
  };
}
