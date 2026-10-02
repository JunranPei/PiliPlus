import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  Future<void> _lastCommand = Future<void>.value();
  Rect? _sourceRect;

  Rect? get sourceRect => _sourceRect;

  AndroidPipPhase get phase => _phase;
  int get generation => _generation;
  String? get lastReason => _lastReason;
  bool get isActive => _phase == AndroidPipPhase.active;
  bool get isEntering => _phase == AndroidPipPhase.entering;
  bool get protectsPlayback =>
      _phase != AndroidPipPhase.idle || _autoEnterPending;

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
    final next = switch (state['phase']) {
      'entering' => AndroidPipPhase.entering,
      'active' => AndroidPipPhase.active,
      _ => AndroidPipPhase.idle,
    };
    final generation = (state['generation'] as num?)?.toInt() ?? _generation;
    final reason = state['reason'] as String?;
    final autoEnterPending = state['autoEnterPending'] as bool? ?? false;
    if (next == _phase &&
        generation == _generation &&
        reason == _lastReason &&
        autoEnterPending == _autoEnterPending) {
      return;
    }
    _phase = next;
    _generation = generation;
    _lastReason = reason;
    _autoEnterPending = autoEnterPending;
    debugPrint(
      '[PIP_V2] phase=${_phase.name} generation=$_generation reason=$reason',
    );
    notifyListeners();
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) {
    final command = _lastCommand.then((_) async {
      try {
        return await _channel.invokeMethod<T>(method, arguments);
      } on MissingPluginException {
        return null;
      } on PlatformException catch (error) {
        debugPrint('[PIP_V2] $method failed: ${error.code}');
        return null;
      }
    });
    _lastCommand = command.then<void>((_) {});
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
