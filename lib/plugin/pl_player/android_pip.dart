import 'dart:io' show Platform;

import 'package:PiliPlus/utils/device_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum AndroidPipPhase {
  idle,
  entering,
  active,
  leaving;

  bool get keepsVideoOnly => this != idle;
  bool get protectsPlayback => this != idle;
}

/// The only Dart-side source of truth for Android picture-in-picture state.
final class AndroidPip extends ChangeNotifier {
  AndroidPip._() {
    if (Platform.isAndroid) {
      _channel.setMethodCallHandler(_handleNativeCall);
    }
  }

  static final AndroidPip instance = AndroidPip._();
  static const MethodChannel _channel = MethodChannel(
    'com.personal.piliplus/pip',
  );

  static bool get isSupported => Platform.isAndroid && DeviceUtils.sdkInt >= 26;

  AndroidPipPhase _phase = AndroidPipPhase.idle;
  AndroidPipPhase get phase => _phase;
  bool get keepsVideoOnly => _phase.keepsVideoOnly;
  bool get protectsPlayback => _phase.protectsPlayback;
  bool get isActive => _phase == AndroidPipPhase.active;

  int _generation = 0;
  int get generation => _generation;
  Rect? _lastSourceRect;

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method != 'stateChanged') return;
    final arguments = Map<Object?, Object?>.from(call.arguments as Map);
    final phaseName = arguments['phase'] as String?;
    final nextPhase = AndroidPipPhase.values.firstWhere(
      (phase) => phase.name == phaseName,
      orElse: () => AndroidPipPhase.idle,
    );
    final nextGeneration = arguments['generation'] as int? ?? _generation;
    final reason = arguments['reason'];
    final changed = nextPhase != _phase || nextGeneration != _generation;
    _phase = nextPhase;
    _generation = nextGeneration;
    _trace(
      'state phase=${nextPhase.name} generation=$nextGeneration reason=$reason',
    );
    if (changed) notifyListeners();
  }

  Future<bool> configure({
    required int videoWidth,
    required int videoHeight,
    required bool autoEnter,
    required bool isLive,
    required bool isPlaying,
    Rect? sourceRect,
  }) async {
    if (!isSupported) return false;
    final arguments = <String, Object>{
      'videoWidth': videoWidth,
      'videoHeight': videoHeight,
      'autoEnter': autoEnter,
      'isLive': isLive,
      'isPlaying': isPlaying,
      ...?_rectArguments(sourceRect),
    };
    _lastSourceRect = sourceRect;
    _trace(
      'configure video=${videoWidth}x$videoHeight auto=$autoEnter '
      'live=$isLive playing=$isPlaying source=$sourceRect',
    );
    try {
      return await _channel.invokeMethod<bool>('configure', arguments) ?? false;
    } catch (error) {
      _trace('configure failed error=$error');
      return false;
    }
  }

  Future<bool> enter() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('enter') ?? false;
    } catch (error) {
      _trace('enter failed error=$error');
      return false;
    }
  }

  void updateSourceRect(Rect? rect) {
    if (!isSupported || rect == null || rect.isEmpty) return;
    final previous = _lastSourceRect;
    if (previous != null &&
        (previous.left - rect.left).abs() < 1 &&
        (previous.top - rect.top).abs() < 1 &&
        (previous.width - rect.width).abs() < 1 &&
        (previous.height - rect.height).abs() < 1) {
      return;
    }
    _lastSourceRect = rect;
    _trace('sourceRect=$rect phase=${_phase.name}');
    _invokeWithoutWaiting('setSourceRect', _rectArguments(rect));
  }

  void updateActions({required bool isLive, required bool isPlaying}) {
    if (!isSupported) return;
    _invokeWithoutWaiting('updateActions', {
      'isLive': isLive,
      'isPlaying': isPlaying,
    });
  }

  void disableAutoEnter() {
    if (!isSupported) return;
    _invokeWithoutWaiting('disableAutoEnter');
  }

  void _invokeWithoutWaiting(String method, [Map<String, Object>? arguments]) {
    _channel.invokeMethod<void>(method, arguments).catchError((Object error) {
      _trace('$method failed error=$error');
    });
  }

  static Map<String, Object>? _rectArguments(Rect? rect) {
    if (rect == null || rect.isEmpty) return null;
    return {
      'left': rect.left.round(),
      'top': rect.top.round(),
      'width': rect.width.round(),
      'height': rect.height.round(),
    };
  }

  static void _trace(String message) {
    debugPrint('[PIP_DART] $message');
  }
}
