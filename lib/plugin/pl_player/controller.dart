import 'dart:async' show Completer, StreamSubscription, Timer, unawaited;
import 'dart:convert' show ascii;
import 'dart:io' show Platform;
import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/user/danmaku_rule.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_shot/data.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/pages/setting/models/play_settings.dart'
    show kMaxVolume;
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/android_pip_controller.dart';
import 'package:PiliPlus/plugin/pl_player/playback/isolated_media_sources.dart';
import 'package:PiliPlus/plugin/pl_player/playback/selected_media_warmup.dart';
import 'package:PiliPlus/plugin/pl_player/playback/selected_codec_reservation.dart';
import 'package:PiliPlus/plugin/pl_player/playback/prepared_media_engine.dart';
import 'package:PiliPlus/plugin/pl_player/playback/prepared_resource.dart';
import 'package:PiliPlus/plugin/pl_player/playback/mpv_frame_gate.dart';
import 'package:PiliPlus/plugin/pl_player/playback/mpv_async_property_reader.dart';
import 'package:PiliPlus/plugin/pl_player/playback/android_audio_output_policy.dart';
import 'package:PiliPlus/plugin/pl_player/playback/parallel_audio_source.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_source_queue.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_start.dart';
import 'package:PiliPlus/plugin/pl_player/playback/source_preparation.dart';
import 'package:PiliPlus/plugin/pl_player/playback/startup_probe.dart';
import 'package:PiliPlus/plugin/pl_player/playback/stable_output_gate.dart';
import 'package:PiliPlus/plugin/pl_player/playback/startup_audio_decode_queue.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/double_tap_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/duration.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/asset_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/box_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/ios/pip_helper.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart'
    show DeviceOrientation, HapticFeedback, KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:path/path.dart' as path;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

typedef PlayCallback = Future<void>? Function();
typedef PlayOwner = ({String tag, Type type});

class _WarmupAudioNormalization with AudioNormalizationMixin {}

class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
  Player? _videoPlayerController;
  VideoController? _videoController;
  final _sourceQueue = PlaybackSourceQueue();
  PlaybackSourceRequest? _loadedSourceRequest;
  MpvFrameGate? _sourceFrameGate;
  bool _sourceFrameReady = false;
  bool get _requiresSourceFrame =>
      const bool.fromEnvironment('SOURCE_FRAME_READY_GATE') &&
      !isLive &&
      !onlyPlayAudio.value;
  ParallelAudioSource? _parallelAudioSource;
  IsolatedMediaSources? _isolatedMediaSources;
  Timer? _startupReadAheadTimer;
  int? _startupReadAheadRevision;
  StartupAudioDecodeQueue? _startupAudioDecodeQueue;

  void _restoreStartupReadAhead(int revision, String reason) {
    if (_startupReadAheadRevision != revision) return;
    _startupReadAheadTimer?.cancel();
    _startupReadAheadTimer = null;
    _startupReadAheadRevision = null;
    if (_sourceRevision != revision || _videoPlayerController == null) return;
    final player = _videoPlayerController!;
    try {
      final before = player.getProperty('cache-secs');
      player
        ..setProperty('cache-secs', buffer['cache-secs']!)
        ..setProperty(
          'demuxer-hysteresis-secs',
          buffer['demuxer-hysteresis-secs']!,
        );
      PlaybackDiagnostics.event('startup.readAhead.restored', {
        'sourceRevision': revision,
        'reason': reason,
        'beforeSeconds': before,
        'afterSeconds': player.getProperty('cache-secs'),
        'hysteresisSeconds': player.getProperty('demuxer-hysteresis-secs'),
      });
    } catch (error) {
      PlaybackDiagnostics.event('startup.readAhead.restoreError', {
        'sourceRevision': revision,
        'type': error.runtimeType.toString(),
      });
    }
  }

  Object? _readySourceOwner;
  Object? _sourceOwner;
  int _sourceRevision = 0;
  int? _diagnosticRequest;
  String? _diagnosticSource;
  Future<void> Function()? _pendingFrameReady;
  int _pendingFrameReadyRevision = 0;
  VoidCallback? _traceRectChanged;
  VoidCallback? _traceIdChanged;
  VideoController? _traceVideoController;

  Map<String, Object?> playbackTraceState() {
    final state = _videoPlayerController?.state;
    final rect = _videoController?.rect.value;
    return {
      'requestId': _diagnosticRequest,
      'sourceRevision': _sourceRevision,
      'owner': _sourceOwner == null ? null : identityHashCode(_sourceOwner!),
      'readyOwner': _readySourceOwner == null
          ? null
          : identityHashCode(_readySourceOwner!),
      'cid': cid,
      'mediaSourceId': _diagnosticSource,
      'playerId': _videoPlayerController == null
          ? null
          : identityHashCode(_videoPlayerController!),
      'videoControllerId': _videoController == null
          ? null
          : identityHashCode(_videoController!),
      'textureId': _videoController?.id.value,
      'textureRect': rect == null
          ? null
          : [rect.left, rect.top, rect.right, rect.bottom],
      'decodedDisplaySize': state == null ? null : [state.width, state.height],
      'positionMs': state?.position.inMilliseconds,
      'playing': state?.playing,
      'buffering': state?.buffering,
      'requestedSize': [width, height],
      'fit': videoFit.value.name,
      'flipX': flipX.value,
      'flipY': flipY.value,
      'onlyAudio': onlyPlayAudio.value,
      'isLive': isLive,
    };
  }

  void _installPlaybackTrace() {
    if (!PlaybackDiagnostics.enabled) return;
    final controller = _videoController!;
    _traceVideoController = controller;
    _traceRectChanged = () =>
        PlaybackDiagnostics.event('media.textureRect', playbackTraceState());
    _traceIdChanged = () =>
        PlaybackDiagnostics.event('media.textureId', playbackTraceState());
    controller.rect.addListener(_traceRectChanged!);
    controller.id.addListener(_traceIdChanged!);
    PlaybackDiagnostics.register(
      'player#${identityHashCode(this)}',
      playbackTraceState,
    );
    PlaybackDiagnostics.event('media.controller.created', playbackTraceState());
  }

  Future<void> Function()? _reloadSource;

  bool hasSourceFor(Object owner, int? cid) =>
      _readySourceOwner == owner && this.cid == cid && _videoController != null;

  void cancelSource(Object owner) {
    _sourceQueue.cancel(owner);
    if (_sourceOwner == owner) {
      _startupAudioDecodeQueue?.restore('source-cancelled');
      _startupAudioDecodeQueue = null;
      _sourceRevision++;
      _pendingFrameReady = null;
    }
  }

  static PlPlayerController? _instance;

  PlayerStatus playerStatus = .paused;

  final Rx<DataStatus> dataStatus = Rx(.none);

  Duration? seekToPos;
  bool hasToasted = false;
  final RxBool isSeeking = false.obs;

  final RxInt position = RxInt(0);
  final RxInt seekPosition = RxInt(0);
  int get progress => isSeeking.value ? seekPosition.value : position.value;

  int get positionInMilliseconds =>
      videoPlayerController?.state.position.inMilliseconds ?? 0;

  final RxInt buffered = RxInt(0);

  final RxInt duration = RxInt(0);

  int durationInMilliseconds = 0;

  void updateDuration(Duration value) {
    duration.value = value.inSeconds;
    durationInMilliseconds = value.inMilliseconds;
  }

  int _playerCount = 0;
  int get playerCount => _playerCount;

  late double lastPlaybackSpeed = 1.0;
  final RxDouble _playbackSpeed = Pref.playSpeedDefault.obs;
  late final RxDouble _longPressSpeed = Pref.longPressSpeedDefault.obs;

  final RxDouble volume = RxDouble(
    PlatformUtils.isDesktop ? Pref.desktopVolume : 1.0,
  );
  final setSystemBrightness = Pref.setSystemBrightness;

  final RxDouble brightness = (-1.0).obs;

  final RxBool showControls = false.obs;

  final RxBool showBrightnessStatus = false.obs;

  final RxBool longPressStatus = false.obs;

  final RxBool controlsLock = false.obs;

  final RxBool isFullScreen = false.obs;
  bool isLive = false;

  bool _isVertical = false;

  final Rx<VideoFitType> videoFit = Rx(.contain);

  late final RxBool continuePlayInBackground =
      Pref.continuePlayInBackground.obs;

  // 记录历史记录
  int? _aid;
  String? _bvid;
  int? cid;
  int? _epid;
  int? _seasonId;
  int? _pgcType;
  VideoType _videoType = VideoType.ugc;
  int _heartDuration = 0;
  int? width;
  int? height;

  late final tryLook = !Accounts.get(AccountType.video).isLogin && Pref.p1080;

  late DataSource dataSource;

  Timer? _timer;
  StreamSubscription? _subForSeek;

  Box setting = GStorage.setting;

  // final Durations durations;

  String get bvid => _bvid!;

  /// 视频播放速度
  double get playbackSpeed => _playbackSpeed.value;

  // 长按倍速
  double get longPressSpeed => _longPressSpeed.value;

  /// [videoPlayerController] instance of Player
  Player? get videoPlayerController => _videoPlayerController;

  /// [videoController] instance of Player
  VideoController? get videoController => _videoController;

  bool isMuted = false;

  /// 听视频
  late final RxBool onlyPlayAudio = false.obs;

  /// 镜像
  late final RxBool flipX = false.obs;

  late final RxBool flipY = false.obs;

  final RxBool isBuffering = true.obs;

  /// 全屏方向
  // ignore: unnecessary_getters_setters
  bool get isVertical => _isVertical;

  set isVertical(bool value) {
    _isVertical = value;
  }

  /// 弹幕开关
  late final RxBool enableShowDanmaku = Pref.enableShowDanmaku.obs;
  late final RxBool enableShowLiveDanmaku = Pref.enableShowLiveDanmaku.obs;
  RxBool get enableShowDanmakuAdaptive =>
      isLive ? enableShowLiveDanmaku : enableShowDanmaku;

  late final bool autoPiP = Pref.autoPiP;
  bool get isPipMode =>
      (Platform.isAndroid && AndroidPipController.instance.protectsPlayback) ||
      (Platform.isIOS && IOSPipHelper.isActive) ||
      (PlatformUtils.isDesktop && isDesktopPip);
  late bool isDesktopPip = false;
  late Rect _lastWindowBounds;
  static Rect? _lastPipBounds;

  Rect _adjustPipBounds(Rect lastRect, Size size, double aspectRatio) {
    final lastSize = lastRect.size;
    final lastOrientation = lastSize.orientation;
    final orientation = size.orientation;

    if (lastOrientation != orientation) {
      final double width, height;
      switch (orientation) {
        case .portrait:
          if (lastSize.width > size.height) {
            height = min(lastSize.width, _lastWindowBounds.size.height);
            width = height * aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
        case .landscape:
          if (lastSize.height > size.width) {
            width = lastSize.height;
            height = width / aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
      }

      return _lastPipBounds = Rect.fromLTWH(
        lastRect.left,
        lastRect.top,
        width,
        height,
      );
    }
    return _lastPipBounds = Rect.fromLTWH(
      lastRect.left,
      lastRect.top,
      lastSize.width,
      lastSize.width / aspectRatio,
    );
  }

  bool updatePipBounds() {
    if (isDesktopPip) {
      windowManager.getBounds().then((rect) {
        if (isDesktopPip) _lastPipBounds = rect;
      });
      return true;
    }
    return false;
  }

  late final showWindowTitleBar = Pref.showWindowTitleBar;
  late final RxBool isAlwaysOnTop = false.obs;
  Future<void> setAlwaysOnTop(bool value) {
    isAlwaysOnTop.value = value;
    return windowManager.setAlwaysOnTop(value);
  }

  Future<void> exitDesktopPip() {
    isDesktopPip = false;
    return Future.wait([
      if (showWindowTitleBar)
        windowManager.setTitleBarStyle(TitleBarStyle.normal),
      windowManager.setMinimumSize(const Size(400, 700)),
      windowManager.setBounds(_lastWindowBounds),
      setAlwaysOnTop(false),
      windowManager.setAspectRatio(0),
    ]);
  }

  Future<void> enterDesktopPip() async {
    if (isFullScreen.value) return;

    isDesktopPip = true;

    _lastWindowBounds = await windowManager.getBounds();

    if (showWindowTitleBar) {
      windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }

    const shortSide = 280.0;
    const minShortSide = 160.0;
    final Size size;
    final Size minimumSize;
    final state = videoPlayerController!.state;
    int width = state.width;
    int height = state.height;
    if (width == 0) width = this.width ?? 16;
    if (height == 0) height = this.height ?? 9;
    final aspectRatio = width / height;
    if (height > width) {
      size = Size(shortSide, shortSide / aspectRatio);
      minimumSize = Size(minShortSide, minShortSide / aspectRatio);
    } else {
      size = Size(shortSide * aspectRatio, shortSide);
      minimumSize = Size(minShortSide * aspectRatio, minShortSide);
    }

    await windowManager.setMinimumSize(minimumSize);
    setAlwaysOnTop(true);
    if (_lastPipBounds != null) {
      windowManager.setBounds(
        _adjustPipBounds(_lastPipBounds!, size, aspectRatio),
      );
    } else {
      windowManager.setSize(size);
    }
    windowManager.setAspectRatio(width / height);
  }

  void toggleDesktopPip() {
    if (isDesktopPip) {
      exitDesktopPip();
    } else {
      enterDesktopPip();
    }
  }

  int desktopPipSizeLevel = 0; // 0: 小, 1: 中, 2: 大

  Future<void> resizeDesktopPip() async {
    if (!PlatformUtils.isDesktop || !isDesktopPip) return;

    desktopPipSizeLevel = (desktopPipSizeLevel + 1) % 3;

    final state = videoPlayerController!.state;
    int width = state.width;
    int height = state.height;
    if (width == 0) {
      width = this.width ?? 16;
    }
    if (height == 0) {
      height = this.height ?? 9;
    }

    // 三档的基础高度/宽度调节：280.0, 380.0, 480.0
    double baseSize = 280.0 + (desktopPipSizeLevel * 100.0);

    final Size size;
    if (height > width) {
      size = Size(baseSize, baseSize * height / width);
    } else {
      size = Size(baseSize * width / height, baseSize);
    }

    // 先临时解除 AspectRatio 比例锁定，必须用 await 严格等待执行完毕
    await windowManager.setAspectRatio(0);
    await windowManager.setMinimumSize(size);
    await windowManager.setSize(size);
    // 缩放完成后，重新锁定 AspectRatio，保证小窗画面完美比例填充且不产生畸变
    await windowManager.setAspectRatio(width / height);
  }

  late bool _isAutoEnterPip = false;
  bool get isAutoEnterPip => _isAutoEnterPip;
  bool get isEnteringPip =>
      Platform.isAndroid && AndroidPipController.instance.isEntering;
  set isEnteringPip(bool _) {}
  ui.Rect? Function()? getVideoRectCallback;

  static bool get _isCurrVideoPage {
    final routing = Get.routing;
    if (routing.route is! GetPageRoute) {
      return false;
    }
    return _isVideoPage(routing.current);
  }

  static bool _isVideoPage(String routeName) {
    return routeName == '/videoV' || routeName == '/liveRoom';
  }

  Future<bool> enterPip({bool autoEnter = false}) async {
    if (!_isCurrVideoPage) return false;
    if (Platform.isIOS) {
      final player = videoPlayerController;
      final textureId = videoController?.id.value;
      if (player == null || textureId == null || !IOSPipHelper.isAvailable) {
        return false;
      }
      final state = player.state;
      IOSPipHelper.enter(
        textureId,
        width: state.width == 0 ? width : state.width,
        height: state.height == 0 ? height : state.height,
        autoEnter: autoEnter,
        state: _iosPipState(state),
      );
      return true;
    }
    if (!Platform.isAndroid) return false;
    final player = videoPlayerController;
    if (player == null || !player.state.playing) return false;

    final state = player.state;
    final configured = await AndroidPipController.instance.configure(
      autoEnter: autoEnter,
      width: state.width == 0 ? (width ?? 16) : state.width,
      height: state.height == 0 ? (height ?? 9) : state.height,
      isLive: isLive,
      // media_kit's player state is updated before the derived Rx status;
      // use it here so an auto-entry request is never armed as paused during
      // the short play-state propagation window.
      isPlaying: player.state.playing,
      sourceRect: getVideoRectCallback?.call(),
    );
    if (!configured) return false;
    if (!_isCurrVideoPage || videoPlayerController != player) {
      await AndroidPipController.instance.disableAutoEnter();
      return false;
    }
    if (autoEnter) return true;
    return AndroidPipController.instance.enter();
  }

  void _disableAutoEnterPip() {
    // Android retains Activity PiP parameters across player routes. Clear them
    // even when this player was entered manually or the preference is off.
    if (Platform.isAndroid) {
      unawaited(AndroidPipController.instance.disableAutoEnter());
    } else if (Platform.isIOS && _isAutoEnterPip) {
      IOSPipHelper.disableAutoEnter();
    }
  }

  void _armAutoEnterPipAfterStableOutput() {
    if (!Platform.isAndroid ||
        !_isAutoEnterPip ||
        !_isCurrVideoPage ||
        _videoPlayerController?.state.playing != true) {
      if (Platform.isAndroid && !_isCurrVideoPage) _disableAutoEnterPip();
      return;
    }
    // PlaybackStart has already completed its presentation gate here. Arm
    // Android's gesture entry only after the current texture is a visible,
    // stable output; do not add the channel round-trip to play()'s wait.
    unawaited(enterPip(autoEnter: true));
  }

  Map<String, Object> _iosPipState(PlayerState state, [Duration? position]) {
    return {
      'isPlaying': playerStatus.isPlaying,
      'isBuffering': isBuffering.value,
      'isLive': isLive,
      'position': (position ?? state.position).inMilliseconds,
      'duration': durationInMilliseconds,
      'speed': state.rate,
    };
  }

  void _updateIOSPip([Duration? position]) {
    if (Platform.isIOS && IOSPipHelper.needsUpdate) {
      if (_videoPlayerController case final player?) {
        IOSPipHelper.update(_iosPipState(player.state, position));
      }
    }
  }

  // 弹幕相关配置
  late final enableTapDm = PlatformUtils.isMobile && Pref.enableTapDm;
  late RuleFilter filters = Pref.danmakuFilterRule;
  // 关联弹幕控制器
  DanmakuController<DanmakuExtra>? danmakuController;
  bool showDanmaku = true;
  Set<int> dmState = <int>{};
  late final mergeDanmaku = Pref.mergeDanmaku;
  late final String midHash = getCrc32(
    ascii.encode(Accounts.main.mid.toString()),
    0,
  ).toRadixString(16);
  late final RxDouble danmakuOpacity = Pref.danmakuOpacity.obs;

  late List<double> speedList = Pref.speedList;
  late bool enableAutoLongPressSpeed = Pref.enableAutoLongPressSpeed;
  late final showControlDuration = Pref.enableLongShowControl
      ? const Duration(seconds: 30)
      : const Duration(seconds: 3);
  // 字幕
  late double subtitleFontScale = Pref.subtitleFontScale;
  late double subtitleFontScaleFS = Pref.subtitleFontScaleFS;
  late int subtitlePaddingH = Pref.subtitlePaddingH;
  late int subtitlePaddingB = Pref.subtitlePaddingB;
  late double subtitleBgOpacity = Pref.subtitleBgOpacity;
  final bool showVipDanmaku = Pref.showVipDanmaku; // loop unswitching
  late double subtitleStrokeWidth = Pref.subtitleStrokeWidth;
  late int subtitleFontWeight = Pref.subtitleFontWeight;

  // settings
  late final showFSActionItem = Pref.showFSActionItem;
  late final enableShrinkVideoSize = Pref.enableShrinkVideoSize;
  late final darkVideoPage = Pref.darkVideoPage;
  late final enableSlideVolumeBrightness = Pref.enableSlideVolumeBrightness;
  late final enableSlideFS = Pref.enableSlideFS;
  late final enableDragSubtitle = Pref.enableDragSubtitle;
  late final fastForBackwardDuration = Duration(
    seconds: Pref.fastForBackwardDuration,
  );

  late final horizontalSeasonPanel = Pref.horizontalSeasonPanel;
  late final preInitPlayer = Pref.preInitPlayer;
  late final showRelatedVideo = Pref.showRelatedVideo;
  late final showVideoReply = Pref.showVideoReply;
  late final showBangumiReply = Pref.showBangumiReply;
  late final reverseFromFirst = Pref.reverseFromFirst;
  late final horizontalPreview = Pref.horizontalPreview;
  late final showDmChart = Pref.showDmChart;
  late final showViewPoints = Pref.showViewPoints;
  late final showFsScreenshotBtn = Pref.showFsScreenshotBtn;
  late final showFsLockBtn = Pref.showFsLockBtn;
  late final keyboardControl = Pref.keyboardControl;
  late final uiScale = Pref.uiScale;

  late final bool autoEnterFullScreen = Pref.autoEnterFullScreen;
  late final bool autoExitFullscreen = Pref.autoExitFullscreen;
  late final bool autoPlayEnable = Pref.autoPlayEnable;
  late final bool enableVerticalExpand = Pref.enableVerticalExpand;
  late final bool pipNoDanmaku = Pref.pipNoDanmaku;

  late final bool tempPlayerConf = Pref.tempPlayerConf;

  late int? cacheVideoQa = PlatformUtils.isMobile ? null : Pref.defaultVideoQa;
  late int cacheAudioQa = Pref.defaultAudioQa;
  bool enableHeart = true;
  late final String? hwdec = Pref.enableHA ? Pref.hardwareDecoding : null;

  late final progressType = Pref.btmProgressBehavior;
  late final enableQuickDouble = Pref.enableQuickDouble;
  late final fullScreenGestureReverse = Pref.fullScreenGestureReverse;

  late final isRelative = Pref.useRelativeSlide;
  late final offset = isRelative
      ? Pref.sliderDuration / 100
      : Pref.sliderDuration * 1000;

  num get sliderScale => isRelative ? durationInMilliseconds * offset : offset;

  // 播放顺序相关
  late PlayRepeat playRepeat = Pref.playRepeat;

  TextStyle get subTitleStyle => TextStyle(
    height: 1.5,
    fontSize:
        16 * (isFullScreen.value ? subtitleFontScaleFS : subtitleFontScale),
    letterSpacing: 0.1,
    wordSpacing: 0.1,
    color: Colors.white,
    fontWeight: FontWeight.values[subtitleFontWeight],
    backgroundColor: subtitleBgOpacity == 0
        ? null
        : Colors.black.withValues(alpha: subtitleBgOpacity),
  );

  late final Rx<SubtitleViewConfiguration> subtitleConfig = getSubConfig.obs;

  SubtitleViewConfiguration get getSubConfig {
    final subTitleStyle = this.subTitleStyle;
    return SubtitleViewConfiguration(
      style: subTitleStyle,
      strokeStyle: subtitleBgOpacity == 0
          ? subTitleStyle.copyWith(
              color: null,
              background: null,
              backgroundColor: null,
              foreground: Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = subtitleStrokeWidth,
            )
          : null,
      padding: EdgeInsets.only(
        left: subtitlePaddingH.toDouble(),
        right: subtitlePaddingH.toDouble(),
        bottom: subtitlePaddingB.toDouble(),
      ),
      textScaleFactor: 1,
    );
  }

  void updateSubtitleStyle() {
    subtitleConfig.value = getSubConfig;
  }

  void onUpdatePadding(EdgeInsets padding) {
    subtitlePaddingB = padding.bottom.round().clamp(0, 200);
    putSubtitleSettings();
  }

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(
    PlayCallback? playCallBack, {
    PlayOwner? playOwner,
  }) {
    _playCallBack = playCallBack;
    _playOwner = playOwner;
  }

  static PlayOwner? _playOwner;
  static PlayOwner? get playOwner => _playOwner;
  static PlayCallback? _playCallBack;

  static Future<void>? playIfExists() {
    return _playCallBack?.call();
  }

  // try to get PlayerStatus
  static PlayerStatus? getPlayerStatusIfExists() {
    return _instance?.playerStatus;
  }

  static Future<void>? pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) {
    if (_instance?.playerStatus.isPlaying ?? false) {
      return _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
    return null;
  }

  static Future<void>? seekToIfExists(
    Duration position, {
    bool isSeek = true,
  }) {
    return _instance?.seekTo(position, isSeek: isSeek);
  }

  static double? getVolumeIfExists() {
    return _instance?.volume.value;
  }

  static Future<void>? setVolumeIfExists(
    double volumeNew, {
    bool showIndicator = true,
  }) {
    return _instance?.setVolume(volumeNew, showIndicator: showIndicator);
  }

  Box video = GStorage.video;

  bool visible = true;

  DeviceOrientation? _orientation;
  late final checkIsAutoRotate = Platform.isAndroid && mode != .gravity;
  StreamSubscription<OrientationParams>? _orientationListener;

  void _stopOrientationListener() {
    _orientationListener?.cancel();
    _orientationListener = null;
  }

  void _onOrientationChanged(OrientationParams param) {
    _orientation = param.orientation;
    if (Platform.isIOS && !visible) return;
    final orientation = param.orientation;
    final isFullScreen = this.isFullScreen.value;
    if (checkIsAutoRotate &&
        param.isAutoRotate != true &&
        (!isFullScreen ||
            _isVertical ||
            orientation == .portraitUp ||
            orientation == .portraitDown)) {
      return;
    }
    switch (orientation) {
      case .portraitUp:
        if (!_isVertical && controlsLock.value) return;
        if (!horizontalScreen && !_isVertical && isFullScreen) {
          if (!isManualFS) {
            triggerFullScreen(status: false, orientation: orientation);
          }
        } else {
          portraitUpMode();
        }
      case .portraitDown:
        if (!horizontalScreen) return;
        if (!_isVertical && controlsLock.value) return;
        portraitDownMode();
      case .landscapeLeft:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeLeftMode();
        }
      case .landscapeRight:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeRightMode();
        }
    }
  }

  // 添加一个私有构造函数
  PlPlayerController._() {
    if (PlatformUtils.isMobile) {
      _orientationListener = NativeDeviceOrientationPlatform.instance
          .onOrientationChanged(
            checkIsAutoRotate: checkIsAutoRotate,
            angleDegrees: Platform.isAndroid ? Pref.angleDegrees : null,
          )
          .listen(_onOrientationChanged);
    }

    if (!Accounts.heartbeat.isLogin || Pref.historyPause) {
      enableHeart = false;
    }

    _isAutoEnterPip =
        autoPiP &&
        (Platform.isAndroid || (Platform.isIOS && IOSPipHelper.isAvailable));
  }

  // 获取实例 传参
  static PlPlayerController getInstance({bool isLive = false}) {
    // 如果实例尚未创建，则创建一个新实例
    return (_instance ??= PlPlayerController._())
      ..isLive = isLive
      .._playerCount += 1;
  }

  bool get processing => _sourceQueue.busy;

  // offline
  bool get isFileSource => dataSource is FileSource;

  // 初始化资源
  Future<void> setDataSource(
    DataSource dataSource, {
    bool isLive = false,
    bool autoplay = true,
    // 初始化播放位置
    Duration? seekTo,
    // 初始化播放速度
    double speed = 1.0,
    int? width,
    int? height,
    Duration? duration,
    // 方向
    bool? isVertical,
    // 记录历史记录
    int? aid,
    String? bvid,
    int? cid,
    int? epid,
    int? seasonId,
    int? pgcType,
    VideoType? videoType,
    VoidCallback? onInit,
    Object? owner,
    Future<void> Function()? onPrepared,
    Future<void> Function()? onFrameReady,
    Future<void> Function()? onReload,
    Volume? volume,
    bool autoFullScreenFlag = false,
  }) async {
    await _sourceQueue.run(owner ?? this, (request) async {
      try {
        _startupAudioDecodeQueue?.restore('source-replaced');
        _startupAudioDecodeQueue = null;
        _loadedSourceRequest = request;
        _diagnosticRequest = request.id;
        if (SelectedCodecReservation.enabled &&
            dataSource is NetworkSource &&
            !isLive &&
            autoplay &&
            seekTo != null &&
            seekTo > Duration.zero &&
            hwdec != null &&
            hwdec != 'no' &&
            !onlyPlayAudio.value &&
            !const bool.fromEnvironment('STARTUP_NDK_CODEC')) {
          final reservation = SelectedCodecReservation.begin(
            codec: dataSource.videoCodec,
            requestId: request.id,
            cid: cid,
          );
          if (reservation != null) {
            unawaited(request.cancelled.then((_) => reservation.cancel()));
          }
        }
        if (PlaybackDiagnostics.enabled) {
          PlaybackDiagnostics.event('source.prepare.begin', {
            'requestId': request.id,
            'owner': identityHashCode(owner ?? this),
            'cid': cid,
            'previous': playbackTraceState(),
          });
        }
        _readySourceOwner = null;
        _sourceOwner = owner ?? this;
        _sourceRevision++;
        _startupReadAheadTimer?.cancel();
        _startupReadAheadTimer = null;
        _startupReadAheadRevision = null;
        // The first mpv output only proves that the source can render.  The
        // Android surface may still receive its final video parameters when
        // play() starts.  Keep the presentation callback pending until that
        // second handoff has settled, otherwise the poster exposes the
        // intermediate texture geometry for one or more frames.
        _pendingFrameReady = null;
        _pendingFrameReadyRevision = _sourceRevision;
        _reloadSource = onReload;
        if (kDebugMode) {
          debugPrint('[PLAYBACK] prepare request=${request.id} cid=$cid');
        }
        this.isLive = isLive;
        _videoType = videoType ?? VideoType.ugc;
        this.width = width;
        this.height = height;
        this.dataSource = dataSource;
        // 初始化视频倍速
        // _playbackSpeed.value = speed;
        // 初始化数据加载状态
        dataStatus.value = DataStatus.loading;
        // 初始化全屏方向
        _isVertical = isVertical ?? false;
        _aid = aid;
        _bvid = bvid;
        this.cid = cid;
        _epid = epid;
        _seasonId = seasonId;
        _pgcType = pgcType;

        if (showSeekPreview) {
          _clearPreview();
        }
        cancelLongPressTimer();
        if (_videoPlayerController != null &&
            _videoPlayerController!.state.playing) {
          await pause(notify: false);
        }

        request.checkCurrent();
        if (_playerCount == 0) return false;
        // 配置Player 音轨、字幕等等
        await _createVideoController(
          dataSource,
          seekTo,
          volume,
          request: request,
          onPrepared: onPrepared,
          // Autoplay must start as soon as mpv accepts the source.  The
          // presentation callback below keeps the poster in front until the
          // post-play surface handoff is stable.  Only paused/preloaded media
          // needs the old-frame gate before returning to the caller.
          waitForFrame:
              owner != null && !isLive && !onlyPlayAudio.value && !autoplay,
        );
        request.checkCurrent();

        if (_playerCount == 0) {
          _removeListeners();
          _videoPlayerController?.dispose();
          _videoPlayerController = null;
          _videoController = null;
          return false;
        }

        // 获取视频时长 00:00
        updateDuration(duration ?? _videoPlayerController!.state.duration);
        position.value = buffered.value = seekTo?.inSeconds ?? 0;

        if (autoFullScreenFlag && autoEnterFullScreen) {
          triggerFullScreen(status: true);
        }

        await _initializePlayer();
        request.checkCurrent();
        _readySourceOwner = owner ?? this;
        if (PlaybackDiagnostics.enabled) {
          PlaybackDiagnostics.event('source.gate.ready', playbackTraceState());
        }
        dataStatus.value = DataStatus.loaded;
        onInit?.call();
        if (onFrameReady != null) {
          _pendingFrameReady = onFrameReady;
          _pendingFrameReadyRevision = _sourceRevision;
        }
        request.checkCurrent();
        if (autoplay) await play();
        if (kDebugMode) {
          debugPrint(
            '[PLAYBACK] ready request=${request.id} cid=$cid autoplay=$autoplay',
          );
        }
        return true;
      } on PlaybackSourceCancelled {
        PlaybackDiagnostics.event('source.cancelled', {
          'requestId': request.id,
          'cid': cid,
        });
        rethrow;
      } catch (err, stackTrace) {
        if (!request.isCurrent) return false;
        dataStatus.value = DataStatus.error;
        PlaybackDiagnostics.event('source.error', {
          'requestId': request.id,
          'cid': cid,
          'errorType': err.runtimeType.toString(),
        });
        if (kDebugMode) {
          debugPrint(stackTrace.toString());
          debugPrint('plPlayer err:  $err');
        }
        return false;
      }
    });
  }

  String? shadersDirPath;
  Future<String> get copyShadersToExternalDirectory async {
    if (shadersDirPath != null) {
      return shadersDirPath!;
    }

    return shadersDirPath = await AssetUtils.getOrCopy(
      'assets/shaders',
      Assets.mpvAnime4KShaders.followedBy(Assets.mpvAnime4KShadersLite),
      path.join(appSupportDirPath, 'anime_shaders'),
    );
  }

  late final isAnim = _pgcType == 1 || _pgcType == 4;
  late final Rx<SuperResolutionType> superResolutionType =
      (isAnim ? Pref.superResolutionType : SuperResolutionType.disable).obs;
  Future<void> setShader([SuperResolutionType? type, NativePlayer? pp]) async {
    if (type == null) {
      type = superResolutionType.value;
    } else {
      superResolutionType.value = type;
      if (isAnim && !tempPlayerConf) {
        setting.put(SettingBoxKey.superResolutionType, type.index);
      }
    }
    pp ??= _videoPlayerController!;
    switch (type) {
      case SuperResolutionType.disable:
        return pp.command(const ['change-list', 'glsl-shaders', 'clr', '']);
      case SuperResolutionType.efficiency:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShadersLite,
          ),
        ]);
      case SuperResolutionType.quality:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShaders,
          ),
        ]);
    }
  }

  static Future<({Player player, VideoController video})>? _standbyEngine;
  static String? _standbySettings;
  static Object? _visiblePreparedToken;

  /// A single paused real source, with no playback owner, history or audio focus.
  static void prepareVisibleMedia(
    MediaWarmupLease lease, {
    required Volume? volume,
    required int cid,
  }) {
    if (!const bool.fromEnvironment('VISIBLE_NATIVE_PRELOAD') ||
        !Platform.isAndroid ||
        _instance != null ||
        _visiblePreparedToken != null ||
        Pref.superResolutionType != SuperResolutionType.disable ||
        const bool.fromEnvironment('STARTUP_READ_AHEAD') ||
        const bool.fromEnvironment('STARTUP_TCP_NODELAY')) {
      return;
    }
    final token = _visiblePreparedToken = Object();
    final settings = _engineSettings();
    final extras = Pref.initBuffer(Pref.playSpeedDefault);
    _WarmupAudioNormalization().audioFilterExtras(volume, map: extras);
    final pending = _standbyEngine;
    final standbyMatches = _standbySettings == settings;
    _standbyEngine = null;
    PlaybackDiagnostics.event('startup.nativePreload.begin', {
      'cid': cid,
      'startMs': lease.start.inMilliseconds,
    });
    lease.preparedEngine = PreparedResource(
      load: () async {
        ({Player player, VideoController video})? engine;
        MpvFrameGate? frameGate;
        try {
          if (pending != null) {
            engine = await pending;
            if (!standbyMatches) {
              await engine.player.dispose();
              engine = null;
            }
          }
          engine ??= await _createEngine(
            hwdec: Pref.enableHA ? Pref.hardwareDecoding : null,
            desktopVolume: 1.0,
            warmOutput: true,
          );
          final urls = await lease.urls;
          final media = dashMediaUri(
            urls.video,
            urls.audio,
            uncut: const bool.fromEnvironment('UNCUT_DASH_TRACKS'),
          );
          if (_engineSettings() != settings) {
            throw StateError('Preload settings changed');
          }
          if (const bool.fromEnvironment('SOURCE_FRAME_READY_GATE')) {
            frameGate = MpvFrameGate(engine.player, source: media);
          }
          await engine.player.open(
            Media(media, start: lease.start, extras: extras),
            play: false,
          );
          PlaybackDiagnostics.event('startup.nativePreload.openAccepted', {
            'cid': cid,
            'requestedStartMs': lease.start.inMilliseconds,
            'playerId': identityHashCode(engine.player),
            'playing': engine.player.state.playing,
            'positionMs': engine.player.state.position.inMilliseconds,
            'textureId': engine.video.id.value,
            'cacheSeconds': extras['cache-secs'],
            'cacheMaxBytes': extras['demuxer-max-bytes'],
          });
          return PreparedMediaEngine(
            player: engine.player,
            video: engine.video,
            media: media,
            settings: settings,
            start: lease.start,
            frameGate: frameGate,
            extras: extras,
          );
        } catch (error) {
          frameGate?.dispose();
          await engine?.player.dispose();
          PlaybackDiagnostics.event('startup.nativePreload.failed', {
            'cid': cid,
            'errorType': error.runtimeType.toString(),
          });
          rethrow;
        }
      },
      dispose: (engine) async {
        await engine.dispose();
        PlaybackDiagnostics.event('startup.nativePreload.closed', {'cid': cid});
      },
      onReleased: () {
        if (identical(_visiblePreparedToken, token)) {
          _visiblePreparedToken = null;
        }
      },
    );
  }

  static String _engineSettings() => [
    Pref.videoSync,
    Pref.audioOutput,
    Pref.playerVolume,
    Pref.enableHA,
    Pref.hardwareDecoding,
    Pref.autosync,
    Pref.superResolutionType,
  ].join('|');

  static void _standbyMark(
    String event, [
    Map<String, Object?> data = const {},
  ]) {
    if (PlaybackDiagnostics.enabled) {
      // This diagnostic marker must remain visible in release-mode logcat.
      // ignore: avoid_print
      print(
        '[PLAYER_STANDBY] ${DateTime.now().microsecondsSinceEpoch} $event $data',
      );
    }
  }

  /// Reserve exactly one engine, without creating a playback owner, opening
  /// media, requesting URLs, audio focus, or attaching a source Surface.
  static Future<void> prepareStandby() async {
    if (!Platform.isAndroid || _instance != null || _standbyEngine != null) {
      return;
    }
    _standbySettings = _engineSettings();
    _standbyMark('begin');
    final pending = _createEngine(
      hwdec: Pref.enableHA ? Pref.hardwareDecoding : null,
      desktopVolume: 1.0,
      warmOutput: true,
    );
    _standbyEngine = pending;
    try {
      final engine = await pending;
      _standbyMark('ready', {
        'playerId': identityHashCode(engine.player),
        'mediaCount': engine.player.current.length,
        'playing': engine.player.state.playing,
      });
    } catch (error) {
      if (identical(_standbyEngine, pending)) _standbyEngine = null;
      _standbyMark('failed', {'errorType': error.runtimeType.toString()});
    }
  }

  static Future<({Player player, VideoController video})> _createEngine({
    required String? hwdec,
    required double desktopVolume,
    bool warmOutput = false,
  }) async {
    PlaybackDiagnostics.event('startup.player.create.begin');
    String ao = Pref.audioOutput;
    if (ao == 'opensles,aaudio,audiotrack') {
      ao = 'audiotrack,aaudio,opensles';
    }
    if (Platform.isAndroid &&
        const bool.fromEnvironment('STARTUP_AAUDIO_FIRST')) {
      ao = 'aaudio,audiotrack,opensles';
    }
    ao = AndroidAudioOutputPolicy.apply(ao);
    const codecOperatingRate = int.fromEnvironment(
      'STARTUP_CODEC_OPERATING_RATE',
    );
    // Experimental: keep decoder waits off the playback thread without a
    // multi-frame hardware buffer backlog. Remains off in ordinary builds.
    final videoDecodeQueue =
        Platform.isAndroid &&
        const bool.fromEnvironment('STARTUP_VIDEO_DECODE_QUEUE');
    final decoderOptions = <String>[
      if (const bool.fromEnvironment('STARTUP_NDK_CODEC')) 'ndk_codec=1',
      if (const bool.fromEnvironment('SKIP_UNUSED_CODEC_FLUSH'))
        'skip_unused_flush=1',
      if (codecOperatingRate > 0) 'operating_rate=$codecOperatingRate',
    ];
    final opt = {
      'video-sync': Pref.videoSync,
      if (Platform.isAndroid) 'ao': ao,
      'volume':
          (PlatformUtils.isMobile ? Pref.playerVolume : desktopVolume * 100)
              .toString(),
      'volume-max': kMaxVolume.toString(),
      if (hwdec != null && hwdec != 'no')
        'hwdec': Platform.isAndroid ? 'mediacodec' : hwdec,
      if (Platform.isAndroid) 'profile': 'fast',
      if (videoDecodeQueue) ...{
        'vd-queue-enable': 'yes',
        'vd-queue-max-samples': '1',
        'vd-queue-max-bytes': '16777216',
        'vd-queue-max-secs': '0.05',
      },
      // Decode a bounded audio lead while video is seeking. The existing audio
      // output path still clips to the actual video PTS before starting sound.
      if (Platform.isAndroid &&
          const bool.fromEnvironment('STARTUP_AUDIO_DECODE_QUEUE')) ...{
        'ad-queue-enable': 'yes',
        'ad-queue-max-secs': '2',
        'ad-queue-max-bytes': '1048576',
        'ad-queue-max-samples': '192000',
      },
      if (Platform.isAndroid &&
          const bool.fromEnvironment('STARTUP_FILTERED_AUDIO_LEAD'))
        'pili-filtered-audio-lead': 'yes',
      if (Platform.isWindows) 'gpu-api': 'd3d11',
      'vd-lavc-fast': 'yes',
      'vd-lavc-dr': 'yes',
      'vd-lavc-threads': '0',
      if (Platform.isAndroid && decoderOptions.isNotEmpty)
        'vd-lavc-o': decoderOptions.join(','),
    };
    final configuredAutosync = Pref.autosync;
    final autosync =
        Platform.isAndroid &&
            const bool.fromEnvironment('STARTUP_AUTOSYNC_ZERO')
        ? '0'
        : configuredAutosync;
    if (autosync != '0' ||
        (Platform.isAndroid &&
            const bool.fromEnvironment('STARTUP_AUTOSYNC_ZERO'))) {
      opt['autosync'] = autosync;
    }
    PlaybackDiagnostics.event('startup.sync.options', {
      'configuredAutosync': configuredAutosync,
      'effectiveAutosync': autosync,
      'videoSync': opt['video-sync'],
      'audioOutput': ao,
      'videoDecodeQueueFrames': videoDecodeQueue ? 1 : 0,
    });

    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: const bool.fromEnvironment('SEEK_RUNTIME_TRACE')
            ? .debug
            : StartupProbe.deep
            ? .trace
            : StartupProbe.verbose
            ? .debug
            : kDebugMode
            ? .warn
            : .error,
        options: opt,
      ),
    );

    if (PlaybackDiagnostics.enabled) {
      PlaybackDiagnostics.event('startup.sync.applied', {
        'autosync': player.getProperty('options/autosync'),
        'videoSync': player.getProperty('options/video-sync'),
      });
      PlaybackDiagnostics.event('startup.decoder.options', {
        'ndkRequested':
            Platform.isAndroid &&
            const bool.fromEnvironment('STARTUP_NDK_CODEC'),
        'operatingRateRequested': Platform.isAndroid ? codecOperatingRate : 0,
        'decoderOptions': player.getProperty('options/vd-lavc-o'),
      });
      player.onLoadHooks.add(() {
        PlaybackDiagnostics.event('startup.surfaceHook.begin');
      });
    }
    PlaybackDiagnostics.event('startup.player.create.end');
    PlaybackDiagnostics.event('startup.videoController.create.begin');

    try {
      final video = await VideoController.create(
        player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: hwdec != null,
          // The Android fork of media_kit provides a MediaCodec-backed output
          // which attaches the decoder surface without the GPU output's second
          // SurfaceTexture resize/reconfigure pass.  The startup probe showed
          // that this is the first visible-output bottleneck after play(); keep
          // desktop and iOS on their existing platform defaults.
          vo: Platform.isAndroid ? 'mediacodec_embed' : null,
          // Attach the Android surface immediately. Waiting for video parameters
          // makes the loading cover disappear before the first picture on slow
          // streams and regresses startup against the original player.
          androidAttachSurfaceAfterVideoParameters: false,
          hwdec: Platform.isAndroid ? 'mediacodec' : hwdec,
        ),
      );

      if (PlaybackDiagnostics.enabled) {
        player.onLoadHooks.add(() {
          PlaybackDiagnostics.event('startup.surfaceHook.end');
        });
      }

      if (PlaybackDiagnostics.enabled) {
        PlaybackDiagnostics.event('startup.output.config', {
          'requestedVo': Platform.isAndroid ? 'mediacodec_embed' : 'default',
          'attachSurfaceAfterVideoParameters': false,
          'hwdec': Platform.isAndroid ? 'mediacodec' : hwdec,
        });
      }

      player.setMediaHeader(
        userAgent: BrowserUa.pc,
        referer: HttpString.baseUrl,
      );
      PlaybackDiagnostics.event('startup.videoController.create.end');

      if (warmOutput) {
        await (video as dynamic).prepareStandbyOutput();
      }
      return (player: player, video: video);
    } catch (_) {
      await player.dispose();
      rethrow;
    }
  }

  Future<Player> _initPlayer({PreparedMediaEngine? prepared}) async {
    assert(_videoPlayerController == null);
    if (prepared != null) {
      _videoController = prepared.video;
      _installPlaybackTrace();
      _startListeners(prepared.player);
      return prepared.player;
    }
    final pending = _standbyEngine;
    final matches = _standbySettings == _engineSettings();
    _standbyEngine = null;
    ({Player player, VideoController video})? engine;
    if (pending != null) {
      try {
        final prepared = await pending;
        if (matches) {
          engine = prepared;
          _standbyMark('claimed', {
            'playerId': identityHashCode(prepared.player),
            'mediaCount': prepared.player.current.length,
          });
        } else {
          await prepared.player.dispose();
          _standbyMark('discarded-settings-changed');
        }
      } catch (_) {
        // A failed speculative creation must retain normal on-demand startup.
      }
    }
    final selected =
        engine ??
        await _createEngine(
          hwdec: hwdec,
          desktopVolume: volume.value,
        );
    _videoController = selected.video;
    _installPlaybackTrace();
    _startListeners(selected.player);
    return selected.player;
  }

  late final buffer = Pref.initBuffer(_playbackSpeed.value);
  late final liveBuffer = Pref.initLiveBuffer();

  // 配置播放器
  Future<void> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume, {
    required PlaybackSourceRequest request,
    Future<void> Function()? onPrepared,
    required bool waitForFrame,
  }) async {
    isBuffering.value = false;
    _heartDuration = 0;
    danmakuController?.clear();

    var player = _videoPlayerController;
    MediaWarmupLease? earlyWarm;
    PreparedMediaEngine? prepared;

    if (const bool.fromEnvironment('VISIBLE_NATIVE_PRELOAD') &&
        player == null &&
        !waitForFrame &&
        !isLive &&
        !onlyPlayAudio.value &&
        !StartupProbe.enabled &&
        dataSource is NetworkSource &&
        (seekTo == null ||
            seekTo == Duration.zero ||
            const bool.fromEnvironment('VISIBLE_RESUME_PRELOAD')) &&
        dataSource.audioSource?.isNotEmpty == true) {
      try {
        earlyWarm = await SelectedMediaWarmup.instance.take(
          scope: Accounts.video,
          video: dataSource.videoSource,
          audio: dataSource.audioSource!,
          start: seekTo ?? Duration.zero,
          headers: {'User-Agent': BrowserUa.pc, 'Referer': HttpString.baseUrl},
          onEvent: (event, data) => PlaybackDiagnostics.event(event, {
            ...data,
            'requestId': request.id,
            'cid': cid,
          }),
        );
        if (earlyWarm?.preparedEngine != null) {
          prepared = await earlyWarm!.preparedEngine!.take();
          final urls = await earlyWarm.urls;
          final expectedExtras = Map<String, String>.of(buffer);
          audioFilterExtras(volume, map: expectedExtras);
          final expectedMedia = dashMediaUri(
            urls.video,
            urls.audio,
            uncut: const bool.fromEnvironment('UNCUT_DASH_TRACKS'),
          );
          final match = prepared?.matchReport(
            expectedMedia,
            _engineSettings(),
            expectedExtras,
            start: seekTo ?? Duration.zero,
          );
          if (match == null || !match.values.every((value) => value)) {
            await prepared?.dispose();
            prepared = null;
            earlyWarm.close();
            earlyWarm = null;
            PlaybackDiagnostics.event('startup.nativePreload.miss', {
              'cid': cid,
              'match': match,
            });
          }
        }
        request.checkCurrent();
      } catch (_) {
        await prepared?.dispose();
        prepared = null;
        earlyWarm?.close();
        earlyWarm = null;
        request.checkCurrent();
      }
    }

    if (player == null) {
      player = await _initPlayer(prepared: prepared);
      if (_playerCount == 0) {
        earlyWarm?.close();
        _removeListeners();
        player.dispose();
        player = null;
        _videoController = null;
        return;
      }
      _videoPlayerController = player;
      if (earlyWarm != null) _isolatedMediaSources = earlyWarm.transport;
      if (isAnim && superResolutionType.value != .disable) {
        await setShader();
      }
    }

    request.checkCurrent();
    if (!SourcePreparation.enabled && onPrepared != null) {
      await Future.any<void>([
        onPrepared(),
        request.cancelled.then<void>(
          (_) => throw const PlaybackSourceCancelled(),
        ),
      ]);
    }
    request.checkCurrent();

    final Map<String, String> extras = {};
    if (const bool.fromEnvironment('STARTUP_TCP_NODELAY') &&
        dataSource is NetworkSource &&
        !isLive) {
      extras['stream-lavf-o'] = 'tcp_nodelay=1';
    }

    if (dataSource is FileSource) {
      extras['cache'] = 'no';
    } else {
      if (isLive) {
        extras.addAll(liveBuffer);
      } else {
        extras.addAll(buffer);
      }
    }

    final source = StartupProbe.enabled
        ? await StartupProbe.resolve(dataSource, cid)
        : (video: dataSource.videoSource, audio: dataSource.audioSource);
    _parallelAudioSource?.close();
    _parallelAudioSource = null;
    if (_isolatedMediaSources != earlyWarm?.transport) {
      _isolatedMediaSources?.close();
    }
    _isolatedMediaSources = null;
    if (SelectedMediaWarmup.enabled &&
        (onlyPlayAudio.value ||
            isLive ||
            StartupProbe.enabled ||
            dataSource is! NetworkSource ||
            (seekTo != null &&
                seekTo != Duration.zero &&
                !const bool.fromEnvironment('VISIBLE_RESUME_PRELOAD')) ||
            source.audio == null ||
            source.audio!.isEmpty)) {
      SelectedMediaWarmup.instance.clear();
    }
    String video = source.video;
    if (source.audio case var audio? when (audio.isNotEmpty)) {
      if (onlyPlayAudio.value) {
        video = audio;
      } else {
        if ((ParallelAudioSource.enabled ||
                const bool.fromEnvironment('ISOLATED_MEDIA_SOURCES')) &&
            dataSource is NetworkSource &&
            !isLive &&
            !StartupProbe.enabled &&
            (seekTo == null ||
                seekTo == Duration.zero ||
                const bool.fromEnvironment('PARALLEL_RESUME_MEDIA'))) {
          // Resume still passes its exact Media.start below. The transport
          // warms initialization and optionally a predicted resume range.
          // Other seeks redirect to origin with the Range header. A zero-start
          // prepared decoder is never adopted for a nonzero resume.
          final headers = {
            'User-Agent': BrowserUa.pc,
            'Referer': HttpString.baseUrl,
          };
          void onEvent(String event, Map<String, Object?> data) {
            PlaybackDiagnostics.event(event, {
              ...data,
              'requestId': request.id,
              'cid': cid,
            });
          }

          if (const bool.fromEnvironment('ISOLATED_MEDIA_SOURCES')) {
            MediaWarmupLease? warm = earlyWarm;
            if (SelectedMediaWarmup.enabled && warm == null) {
              try {
                warm = await SelectedMediaWarmup.instance.take(
                  scope: Accounts.video,
                  video: video,
                  audio: audio,
                  headers: headers,
                  start: seekTo ?? Duration.zero,
                  onEvent: onEvent,
                );
              } catch (_) {
                // Failed speculation leaves ordinary transport setup available.
              }
              try {
                request.checkCurrent();
              } catch (_) {
                warm?.transport.close();
                rethrow;
              }
            }
            if (warm?.preparedEngine != null && prepared == null) {
              // Existing/paused playback cannot adopt the speculative engine.
              // Its transport may already be consumed, so close both and open
              // an ordinary source instead of leaving a second player alive.
              warm!.close();
              warm = null;
            }
            final transport =
                warm?.transport ??
                IsolatedMediaSources(headers: headers, onEvent: onEvent);
            _isolatedMediaSources = transport;
            try {
              if (warm != null) {
                PlaybackDiagnostics.event('startup.mediaPrefetch.claim', {
                  'cid': cid,
                  'requestId': request.id,
                });
              }
              final urls =
                  await (warm?.urls ??
                      transport.start(
                        video,
                        audio,
                        videoAlternatives: dataSource.videoAlternatives,
                        audioAlternatives: dataSource.audioAlternatives,
                        resumePosition:
                            const bool.fromEnvironment('PREFETCH_RESUME_RANGE')
                            ? seekTo ?? Duration.zero
                            : Duration.zero,
                      ));
              request.checkCurrent();
              video = urls.video;
              audio = urls.audio;
            } catch (_) {
              transport.close();
              _isolatedMediaSources = null;
              request.checkCurrent();
              // Setup failure leaves both original URLs intact.
            }
          } else {
            final transport = ParallelAudioSource(
              headers: headers,
              onEvent: onEvent,
            );
            _parallelAudioSource = transport;
            try {
              final url = await transport.start(audio);
              request.checkCurrent();
              audio = url;
            } catch (_) {
              transport.close();
              _parallelAudioSource = null;
              request.checkCurrent();
            }
          }
        }
        // Each network DASH track here is one complete resource, with no EDL
        // trims or offsets. mpv's normal timeline marks its first packet as a
        // new segment and resets the decoder; no_clip avoids that boundary.
        // Keep regular timeline semantics for local files and nested EDLs.
        final uncutTracks =
            const bool.fromEnvironment('UNCUT_DASH_TRACKS') &&
            dataSource is NetworkSource &&
            !isLive &&
            const ['http', 'https'].contains(Uri.tryParse(video)?.scheme) &&
            const ['http', 'https'].contains(Uri.tryParse(audio)?.scheme);
        if (const bool.fromEnvironment('UNCUT_DASH_TRACKS')) {
          PlaybackDiagnostics.event('source.timeline', {
            'uncutTracks': uncutTracks,
          });
        }
        // delay_open needs an explicit length.
        video = dashMediaUri(
          video,
          audio,
          uncut: uncutTracks,
          fileSource: isFileSource,
        );
      }
      audioFilterExtras(volume, map: extras);
    }

    assert(!isLive || seekTo == null);
    if (const bool.fromEnvironment('STARTUP_READ_AHEAD') &&
        dataSource is NetworkSource &&
        !isLive &&
        !onlyPlayAudio.value &&
        !waitForFrame &&
        (seekTo == null || seekTo == Duration.zero) &&
        double.parse(buffer['cache-secs']!) > 1) {
      // Limit initial demux work competing with decoder initialization. Restore
      // the user's normal buffer after presentation, or after a bounded delay
      // when there is no presentation callback. Never disable underrun recovery.
      extras['cache-secs'] = '1';
      extras['demuxer-hysteresis-secs'] = '0';
      final revision = _sourceRevision;
      _startupReadAheadRevision = revision;
      _startupReadAheadTimer = Timer(const Duration(seconds: 5), () {
        _restoreStartupReadAhead(revision, 'deadline');
      });
      PlaybackDiagnostics.event('startup.readAhead.limited', {
        'sourceRevision': revision,
        'seconds': 1,
        'restoreSeconds': buffer['cache-secs'],
      });
    }
    if (prepared != null && prepared.media != video) {
      PlaybackDiagnostics.event('startup.nativePreload.changedBeforeOpen', {
        'cid': cid,
      });
      prepared = null;
    }
    final limitStartupAudioDecode =
        Platform.isAndroid &&
        const bool.fromEnvironment('STARTUP_AUDIO_DECODE_QUEUE_BOUNDED') &&
        const bool.fromEnvironment('STARTUP_AUDIO_DECODE_QUEUE') &&
        prepared == null &&
        !isLive &&
        !onlyPlayAudio.value &&
        seekTo != null &&
        seekTo > Duration.zero;
    final gate =
        prepared?.frameGate ??
        ((waitForFrame || _requiresSourceFrame || limitStartupAudioDecode)
            ? MpvFrameGate(player, source: video)
            : null);
    _sourceFrameGate?.dispose();
    _sourceFrameGate = (_requiresSourceFrame || limitStartupAudioDecode)
        ? gate
        : null;
    _sourceFrameReady = false;
    if (limitStartupAudioDecode && gate != null) {
      final revision = _sourceRevision;
      final currentPlayer = player;
      _startupAudioDecodeQueue = StartupAudioDecodeQueue(
        readSeconds: () => currentPlayer.getProperty('ad-queue-max-secs'),
        writeSeconds: (value) =>
            currentPlayer.setProperty('ad-queue-max-secs', value),
        ownsPlayer: () =>
            _sourceRevision == revision &&
            identical(_videoPlayerController, currentPlayer),
        frameReady: gate.ready,
        cancelled: request.cancelled,
        onEvent: (event, data) => PlaybackDiagnostics.event(
          'startup.audioDecodeQueue.$event',
          {...playbackTraceState(), ...data},
        ),
      );
      if (!_requiresSourceFrame) {
        unawaited(request.cancelled.then((_) => gate.dispose()));
      }
    }
    if (_requiresSourceFrame && gate != null) {
      unawaited(
        gate.ready.then(
          (_) {
            if (request.isCurrent && identical(_sourceFrameGate, gate)) {
              _sourceFrameReady = true;
              PlaybackDiagnostics.event(
                'output.sourceFrameReady',
                playbackTraceState(),
              );
            }
          },
          onError: (Object error) {
            if (request.isCurrent && identical(_sourceFrameGate, gate)) {
              PlaybackDiagnostics.event('output.sourceFrameFailed', {
                ...playbackTraceState(),
                'errorType': error.runtimeType.toString(),
              });
            }
          },
        ),
      );
      unawaited(request.cancelled.then((_) => gate.dispose()));
    }
    _diagnosticSource = PlaybackDiagnostics.sourceId(video);
    if (PlaybackDiagnostics.enabled) {
      PlaybackDiagnostics.event('source.open.begin', {
        ...playbackTraceState(),
        'operation': prepared == null ? 'open' : 'adopt-paused-preload',
      });
    }
    try {
      StartupProbe.beginSource();
      Future<void> openPaused() async {
        if (prepared != null) {
          // The exact native source is already loaded. Reopening would discard
          // the decoder and its paused frame. Ownership begins at this marker.
          PlaybackDiagnostics.event('startup.nativePreload.claim', {
            ...playbackTraceState(),
            'mediaMatches': prepared.media == video,
          });
          return;
        }
        // mpv treats an explicit start=0 as an initial seek, after creating the
        // decoder. A new network load already starts at its beginning; keep
        // nonzero resume/skip positions exactly as requested.
        final omitZeroStart =
            const bool.fromEnvironment('OMIT_ZERO_MEDIA_START') &&
            dataSource is NetworkSource &&
            !isLive &&
            seekTo == Duration.zero;
        final nativeStart = omitZeroStart ? null : seekTo;
        if (PlaybackDiagnostics.enabled) {
          PlaybackDiagnostics.event('source.startPosition', {
            'requestedMs': seekTo?.inMilliseconds,
            'nativeStartMs': nativeStart?.inMilliseconds,
            'omittedZero': omitZeroStart,
          });
        }
        await player!.open(
          Media(
            video,
            start: nativeStart,
            extras: extras.isEmpty ? null : extras,
          ),
          play: false,
        );
        if (PlaybackDiagnostics.enabled) {
          PlaybackDiagnostics.event(
            'source.open.accepted',
            playbackTraceState(),
          );
        }
      }

      if (SourcePreparation.enabled && onPrepared != null) {
        await SourcePreparation.overlap(
          request: request,
          openPaused: openPaused,
          preparePresentation: onPrepared,
        );
      } else {
        await openPaused();
      }
      if (PlaybackDiagnostics.enabled) {
        PlaybackDiagnostics.event('source.open.return', playbackTraceState());
      }
      request.checkCurrent();
      if (waitForFrame && gate != null) {
        await Future.any<void>([
          gate.ready,
          request.cancelled.then<void>(
            (_) => throw const PlaybackSourceCancelled(),
          ),
        ]);
        request.checkCurrent();
        await _waitForVideoOutput(request);
      }
    } catch (_) {
      gate?.dispose();
      rethrow;
    } finally {
      if (!_requiresSourceFrame) gate?.dispose();
    }
  }

  Future<void> _waitForVideoOutput(PlaybackSourceRequest request) async {
    final controller = _videoController!;
    final ready = Completer<void>();
    void check() {
      final rect = controller.rect.value;
      final state = controller.player.state;
      if (!ready.isCompleted &&
          controller.id.value != null &&
          rect != null &&
          rect.width > 1 &&
          rect.height > 1 &&
          state.width > 0 &&
          state.height > 0 &&
          (!Platform.isAndroid ||
              (rect.width == state.width && rect.height == state.height))) {
        if (kDebugMode) {
          debugPrint(
            '[PLAYBACK] output request=${request.id} texture=${controller.id.value} size=${state.width}x${state.height} rect=$rect',
          );
        }
        ready.complete();
      }
    }

    controller.rect.addListener(check);
    controller.id.addListener(check);
    final subscription = controller.player.stream.size.listen((_) => check());
    try {
      check();
      await Future.any<void>([
        ready.future.timeout(const Duration(seconds: 10)),
        request.cancelled.then<void>(
          (_) => throw const PlaybackSourceCancelled(),
        ),
      ]);
    } finally {
      controller.rect.removeListener(check);
      controller.id.removeListener(check);
      await subscription.cancel();
    }
  }

  /// Wait until the output exposed by media_kit has stopped changing after a
  /// play command.  mpv can report a usable frame before the Android surface
  /// is resized to the final decoded stream; revealing Flutter in that gap
  /// causes the old texture geometry to flash before the final one replaces
  /// it.  Three equal samples across frame boundaries make the handoff atomic
  /// from the UI's point of view while retaining the same texture.
  Future<bool> _waitForStableVideoOutput({
    required int sourceRevision,
    // Autoplay starts before Android has attached the decoded surface. On the
    // emulator that handoff can take a few seconds; a short fallback reveals
    // the cover onto an empty texture and makes startup look slower.
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final controller = _videoController;
    final request = _loadedSourceRequest;
    if (controller == null || request == null || !request.isCurrent) {
      return false;
    }
    if (const bool.fromEnvironment('EVENT_DRIVEN_OUTPUT_GATE') ||
        const bool.fromEnvironment('EVENT_DRIVEN_OUTPUT_DWELL')) {
      return _waitForOutputFrames(controller, request, sourceRevision, timeout);
    }
    final started = Stopwatch()..start();
    String? previous;
    var stableSamples = 0;
    while (started.elapsed < timeout) {
      if (!request.isCurrent ||
          sourceRevision != _sourceRevision ||
          _videoController != controller) {
        return false;
      }
      // PiP owns the transition surface once Android marks the entry as
      // pending.  Waiting for the normal-page geometry here leaves Flutter
      // covered while SystemUI captures the transition, which can produce an
      // app-icon frame for sources whose final output arrives a little later.
      // The already-playing texture is the correct source for PiP's native
      // scaling, so hand it over immediately in this case.
      if (Platform.isAndroid &&
          AndroidPipController.instance.protectsPlayback) {
        if (PlaybackDiagnostics.enabled) {
          PlaybackDiagnostics.event('output.stable.pip-bypass', {
            ...playbackTraceState(),
            'sourceRevision': sourceRevision,
            'elapsedMs': started.elapsedMilliseconds,
          });
        }
        return true;
      }
      final rect = controller.rect.value;
      final state = controller.player.state;
      final id = controller.id.value;
      final valid =
          (!_requiresSourceFrame || _sourceFrameReady) &&
          (!const bool.fromEnvironment('SOURCE_BUFFER_READY_GATE') ||
              !state.buffering) &&
          id != null &&
          rect != null &&
          rect.width > 1 &&
          rect.height > 1 &&
          state.width > 0 &&
          state.height > 0;
      if (valid) {
        final signature =
            '$id|${rect.left.toStringAsFixed(3)},'
            '${rect.top.toStringAsFixed(3)},'
            '${rect.width.toStringAsFixed(3)},'
            '${rect.height.toStringAsFixed(3)}|'
            '${state.width}x${state.height}';
        if (signature == previous) {
          stableSamples++;
        } else {
          previous = signature;
          stableSamples = 1;
        }
        // Give the post-play surface resize at least one display interval to
        // arrive before accepting the first repeated sample.
        if (started.elapsed >= const Duration(milliseconds: 120) &&
            stableSamples >= 3) {
          if (PlaybackDiagnostics.enabled) {
            PlaybackDiagnostics.event('output.stable', {
              ...playbackTraceState(),
              'sourceRevision': sourceRevision,
              'samples': stableSamples,
              'elapsedMs': started.elapsedMilliseconds,
              'signature': signature,
              'requiresSourceBufferReady': const bool.fromEnvironment(
                'SOURCE_BUFFER_READY_GATE',
              ),
              'sourceBuffering': state.buffering,
              'requiresSourceFrame': _requiresSourceFrame,
              'sourceFrameReady': _sourceFrameReady,
            });
          }
          return true;
        }
      } else {
        previous = null;
        stableSamples = 0;
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    if (PlaybackDiagnostics.enabled) {
      PlaybackDiagnostics.event('output.stable.timeout', {
        ...playbackTraceState(),
        'sourceRevision': sourceRevision,
        'elapsedMs': started.elapsedMilliseconds,
        'lastSignature': previous,
        'sourceBuffering': controller.player.state.buffering,
        'requiresSourceFrame': _requiresSourceFrame,
        'sourceFrameReady': _sourceFrameReady,
        'legacyDeadlineFallback': true,
      });
    }
    return request.isCurrent &&
        sourceRevision == _sourceRevision &&
        _videoController == controller;
  }

  Future<bool> _waitForOutputFrames(
    VideoController controller,
    PlaybackSourceRequest request,
    int revision,
    Duration timeout,
  ) async {
    final started = Stopwatch()..start();
    final pip = Platform.isAndroid ? AndroidPipController.instance : null;
    bool current() =>
        request.isCurrent &&
        revision == _sourceRevision &&
        _videoController == controller;
    final gate = StableOutputGate(
      isSourceReady: () =>
          (!_requiresSourceFrame || _sourceFrameReady) &&
          (!const bool.fromEnvironment('SOURCE_BUFFER_READY_GATE') ||
              !controller.player.state.buffering),
      readSignature: () {
        final rect = controller.rect.value;
        final state = controller.player.state;
        final id = controller.id.value;
        if (id == null ||
            rect == null ||
            rect.width <= 1 ||
            rect.height <= 1 ||
            state.width <= 0 ||
            state.height <= 0) {
          return null;
        }
        return '$id|${rect.left.toStringAsFixed(3)},'
            '${rect.top.toStringAsFixed(3)},'
            '${rect.width.toStringAsFixed(3)},'
            '${rect.height.toStringAsFixed(3)}|'
            '${state.width}x${state.height}';
      },
      nextFrame: () => WidgetsBinding.instance.endOfFrame,
      isCurrent: current,
      shouldBypass: () => pip?.protectsPlayback ?? false,
      cancelled: request.cancelled,
      stableDwell: const bool.fromEnvironment('EVENT_DRIVEN_OUTPUT_DWELL')
          ? const Duration(milliseconds: 32)
          : null,
      timeout: timeout,
    );
    controller.rect.addListener(gate.notifyChanged);
    controller.id.addListener(gate.notifyChanged);
    pip?.addListener(gate.notifyChanged);
    final subscription = controller.player.stream.size.listen(
      (_) => gate.notifyChanged(),
    );
    final bufferingSubscription =
        const bool.fromEnvironment('SOURCE_BUFFER_READY_GATE')
        ? controller.player.stream.buffering.listen((_) => gate.notifyChanged())
        : null;
    if (_requiresSourceFrame) {
      unawaited(
        _sourceFrameGate?.ready.then(
          (_) => gate.notifyChanged(),
          onError: (Object _) {},
        ),
      );
    }
    try {
      gate.notifyChanged();
      final result = await gate.ready;
      if (PlaybackDiagnostics.enabled) {
        PlaybackDiagnostics.event(
          switch (result) {
            StableOutputResult.stable => 'output.stable',
            StableOutputResult.bypass => 'output.stable.pip-bypass',
            StableOutputResult.timeout => 'output.stable.timeout',
            StableOutputResult.cancelled => 'output.stable.cancelled',
          },
          {
            ...playbackTraceState(),
            'sourceRevision': revision,
            'eventDriven': true,
            'stabilityMode':
                const bool.fromEnvironment('EVENT_DRIVEN_OUTPUT_DWELL')
                ? 'unchanged-32ms'
                : 'three-frame-observations',
            'samples': gate.samples,
            'elapsedMs': started.elapsedMilliseconds,
            'signature': gate.signature,
            'requiresSourceBufferReady': const bool.fromEnvironment(
              'SOURCE_BUFFER_READY_GATE',
            ),
            'sourceBuffering': controller.player.state.buffering,
            'requiresSourceFrame': _requiresSourceFrame,
            'sourceFrameReady': _sourceFrameReady,
          },
        );
      }
      return result != StableOutputResult.cancelled && current();
    } finally {
      gate.dispose();
      controller.rect.removeListener(gate.notifyChanged);
      controller.id.removeListener(gate.notifyChanged);
      pip?.removeListener(gate.notifyChanged);
      await subscription.cancel();
      await bufferingSubscription?.cancel();
    }
  }

  Future<void> _presentPendingFrameIfNeeded() async {
    final callback = _pendingFrameReady;
    if (callback == null) return;
    final request = _loadedSourceRequest;
    final revision = _pendingFrameReadyRevision;
    _pendingFrameReady = null;
    if (PlaybackDiagnostics.enabled) {
      PlaybackDiagnostics.event('output.stable.wait', {
        ...playbackTraceState(),
        'sourceRevision': revision,
      });
    }
    if (!await _waitForStableVideoOutput(sourceRevision: revision)) return;
    if (revision != _sourceRevision ||
        request != _loadedSourceRequest ||
        request?.isCurrent != true) {
      return;
    }
    await callback();
    _restoreStartupReadAhead(revision, 'presentation-ready');
  }

  /// Public counterpart used when a source is already loaded but its Flutter
  /// presentation is still covered (for example, after returning to a video
  /// route).  It intentionally does not reveal anything by itself; the owner
  /// changes its frame-ready flag only after this future completes.
  Future<bool> waitForStableVideoOutput() =>
      _waitForStableVideoOutput(sourceRevision: _sourceRevision);

  Future<void>? refreshPlayer() {
    if (dataSource is FileSource || processing) {
      return null;
    }
    if (_reloadSource case final reload?) return reload();
    if (!isLive) return null;
    if (_videoPlayerController case final ctr? when (ctr.current.isNotEmpty)) {
      final media = ctr.current.last;
      return _sourceQueue
          .run(_sourceOwner ?? this, (request) async {
            _loadedSourceRequest = request;
            await ctr.open(media, play: false);
            request.checkCurrent();
            await play();
            return true;
          })
          .then<void>((_) {});
    }
    return null;
  }

  // 开始播放
  Future<void> _initializePlayer() async {
    if (_instance == null) return;
    // 设置倍速
    if (_videoPlayerController != null) {
      final speed = isLive ? 1.0 : playbackSpeed;
      if (_videoPlayerController!.state.rate != speed) {
        await setPlaybackSpeed(speed);
      }
    }
    _initVideoFit();
  }

  List<StreamSubscription>? _subscriptions;
  final Set<ValueChanged<Duration>> _positionListeners = {};
  final Set<ValueChanged<PlayerStatus>> _statusListeners = {};

  Timer? _wakeLockTimer;

  void _startWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = Timer(
      const Duration(milliseconds: 500),
      _stopWakeLock,
    );
  }

  void _stopWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = null;
  }

  void _stopWakeLock() {
    WakelockPlus.disable();
    _updatePlaybackState(debugLabel: 'onVideoPaused');
  }

  void _updatePlaybackState({Duration? position, String? debugLabel}) {
    videoPlayerServiceHandler?.onUpdateState(
      playerStatus,
      isBuffering.value,
      isLive,
      position: position ?? _videoPlayerController!.state.position,
      speed: playbackSpeed,
      debugLabel: debugLabel,
    );
    _updateIOSPip(position);
  }

  /// 播放事件监听
  void _startListeners(NativePlayer player) {
    assert(_subscriptions == null);
    final stream = player.stream;
    var timingRevision = -1;
    Stopwatch? timingClock;
    var lastTimingUs = -100000;
    _subscriptions = [
      if (const bool.fromEnvironment('SEEK_RUNTIME_TRACE'))
        stream.log.listen((log) {
          if (log.prefix.startsWith('ao') || log.level == 'error' || log.level == 'fatal') {
            PlaybackDiagnostics.event('seek.audio.log', {
              'prefix': log.prefix, 'level': log.level, 'text': log.text,
            });
          }
        }),
      if (StartupProbe.verbose) stream.log.listen(StartupProbe.onLog),
      if (PlaybackDiagnostics.enabled) ...[
        stream.videoParams.listen(
          (event) => PlaybackDiagnostics.event('media.videoParams', {
            ...playbackTraceState(),
            'params': {
              'w': event.w,
              'h': event.h,
              'dw': event.dw,
              'dh': event.dh,
              'rotate': event.rotate,
              'aspect': event.aspect,
              'pixelformat': event.pixelformat,
              'hwPixelformat': event.hwPixelformat,
            },
          }),
        ),
        stream.size.listen(
          (event) =>
              PlaybackDiagnostics.event('media.size', playbackTraceState()),
        ),
      ],

      /// playing
      stream.playing.listen((bool playing) {
        if (PlaybackDiagnostics.enabled) {
          PlaybackDiagnostics.event('media.playing', {
            'value': playing,
            ...playbackTraceState(),
          });
        }
        if (playing) {
          playerStatus = .playing;
          _stopWakeLockTimer();
          _updatePlaybackState();
          WakelockPlus.enable();

          if (_isAutoEnterPip && !_isCurrVideoPage) _disableAutoEnterPip();
        } else {
          playerStatus = .paused;
          _startWakeLockTimer();
          _disableAutoEnterPip();
          _updateIOSPip();
        }

        for (final element in _statusListeners) {
          element(playing ? .playing : .paused);
        }

        final seconds = videoPlayerController!.state.position.inSeconds;
        if (_readySourceOwner != null && seconds != 0) {
          makeHeartBeat(seconds, type: .status);
        }
      }),

      ///completed
      stream.completed.listen((bool completed) {
        if (completed) {
          playerStatus = .completed;
          _startWakeLockTimer();

          for (final element in _statusListeners) {
            element(.completed);
          }

          if (_readySourceOwner != null) makeHeartBeat(-1, type: .completed);
        }
      }),

      /// position
      stream.position.listen((Duration position) {
        if (PlaybackDiagnostics.enabled &&
            const bool.fromEnvironment('STARTUP_TRANSFER_TRACE') &&
            _sourceRevision > 0) {
          if (timingRevision != _sourceRevision) {
            timingRevision = _sourceRevision;
            timingClock = Stopwatch()..start();
            lastTimingUs = -100000;
          }
          final elapsed = timingClock!.elapsedMicroseconds;
          if (elapsed <= 8000000 && elapsed - lastTimingUs >= 100000) {
            lastTimingUs = elapsed;
            PlaybackDiagnostics.event('startup.timing.position', {
              ...playbackTraceState(),
              'positionEventMs': position.inMilliseconds,
              'currentAo': player.getProperty('current-ao'),
              'audioPts': double.tryParse(player.getProperty('audio-pts')),
              'avsync': double.tryParse(player.getProperty('avsync')),
              'cacheDuration': double.tryParse(
                player.getProperty('demuxer-cache-duration'),
              ),
              'timing':
                  'position stream delivery and property read; not display',
            });
          }
        }
        final posInSeconds = position.inSeconds;

        if (posInSeconds != this.position.value) {
          if (posInSeconds == 0 && playerStatus.isPlaying) {
            _updatePlaybackState(position: position);
          }

          this.position.value = posInSeconds;

          if (_readySourceOwner != null) makeHeartBeat(posInSeconds);
        }

        for (final element in _positionListeners) {
          element(position);
        }
      }),
      stream.duration.listen((Duration duration) {
        updateDuration(duration);
        _updateIOSPip();
      }),
      stream.buffer.listen((Duration buffer) {
        buffered.value = buffer.inSeconds;
      }),
      stream.buffering.listen((bool buffering) {
        PlaybackDiagnostics.event('media.buffering', {
          ...playbackTraceState(),
          'value': buffering,
        });
        isBuffering.value = buffering;
        if (!playerStatus.isCompleted) {
          _stopWakeLockTimer();
          _updatePlaybackState();
        }
      }),
      if (kDebugMode)
        stream.log.listen(((PlayerLog log) {
          if (log.level == 'error' || log.level == 'fatal') {
            Utils.reportError(
              '${log.level}: ${log.prefix}: ${log.text}\n${player.state.playlist}',
              null,
            );
          } else {
            debugPrint(log.toString());
          }
        })),
      stream.error.listen((String event) {
        final failedRevision = _sourceRevision;
        if (dataSource is FileSource &&
            event.startsWith("Failed to open file")) {
          return;
        }
        if (isLive) {
          if (event.startsWith('tcp: ffurl_read returned ') ||
              event.startsWith("Failed to open https://") ||
              event.startsWith("Can not open external file https://")) {
            Future.delayed(const Duration(milliseconds: 3000), () {
              if (failedRevision == _sourceRevision) refreshPlayer();
            });
          }
          return;
        }
        if (event.startsWith("Failed to open https://") ||
            event.startsWith("Can not open external file https://") ||
            ((_parallelAudioSource != null || _isolatedMediaSources != null) &&
                (event.startsWith('Failed to open http://127.0.0.1:') ||
                    event.startsWith(
                      'Can not open external file http://127.0.0.1:',
                    ))) ||
            //tcp: ffurl_read returned 0xdfb9b0bb
            //tcp: ffurl_read returned 0xffffff99
            event.startsWith('tcp: ffurl_read returned ')) {
          EasyThrottle.throttle(
            'controllerStream.error.listen',
            const Duration(milliseconds: 10000),
            () {
              Future.delayed(const Duration(milliseconds: 3000), () {
                if (failedRevision != _sourceRevision) return;
                // if (kDebugMode) {
                //   debugPrint("isBuffering.value: ${isBuffering.value}");
                // }
                // if (kDebugMode) {
                //   debugPrint("_buffered.value: ${_buffered.value}");
                // }
                if (isBuffering.value && buffered.value == 0) {
                  SmartDialog.showToast(
                    '视频链接打开失败，重试中',
                    displayTime: const Duration(milliseconds: 500),
                  );
                  refreshPlayer();
                }
              });
            },
          );
        } else if (event.startsWith('Could not open codec')) {
          SmartDialog.showToast('无法加载解码器, $event，可能会切换至软解');
        } else if (!onlyPlayAudio.value) {
          if (event.startsWith("error running") ||
              event.startsWith("Failed to open .") ||
              event.startsWith("Cannot open") ||
              event.startsWith("Can not open")) {
            return;
          }
          if (!kDebugMode) {
            Utils.reportError('$event\n${player.state.playlist}');
          }
          // SmartDialog.showToast('视频加载错误, $event');
        }
      }),
    ];
  }

  /// 移除事件监听
  void _removeListeners() {
    _startupAudioDecodeQueue?.restore('listeners-removed');
    _startupAudioDecodeQueue = null;
    _sourceFrameGate?.dispose();
    _sourceFrameGate = null;
    _sourceFrameReady = false;
    if (PlaybackDiagnostics.enabled) {
      final controller = _traceVideoController;
      if (controller != null) {
        if (_traceRectChanged != null) {
          controller.rect.removeListener(_traceRectChanged!);
        }
        if (_traceIdChanged != null) {
          controller.id.removeListener(_traceIdChanged!);
        }
      }
      _traceVideoController = null;
      PlaybackDiagnostics.unregister('player#${identityHashCode(this)}');
    }
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
  }

  void _cancelSubForSeek() {
    if (_subForSeek != null) {
      _subForSeek!.cancel();
      _subForSeek = null;
    }
  }

  Future<void> seek(Duration position, {bool isSeek = false}) async {
    final traceClock = PlaybackDiagnostics.enabled ? (Stopwatch()..start()) : null;
    if (PlaybackDiagnostics.enabled) {
      final observedPlayer = _videoPlayerController;
      final revision = _sourceRevision;
      PlaybackDiagnostics.arm('command.seek', playbackTraceState(), durationMs: 15000);
      PlaybackDiagnostics.event('command.seek.request', {
        ...playbackTraceState(),
        'targetMs': position.inMilliseconds,
        'waitForBuffer': isSeek,
      });
      // Read cached player state only. No synchronous mpv property reads,
      // redraw requests or recovery commands while diagnosing a stalled seek.
      var samples = 0;
      var busy = false;
      MpvAsyncPropertyReader? reader;
      if (const bool.fromEnvironment('SEEK_RUNTIME_TRACE')) {
        final native = observedPlayer;
        if (native != null) {
          try { reader = MpvAsyncPropertyReader.native(native); } catch (_) {}
        }
      }
      Timer.periodic(const Duration(milliseconds: 500), (timer) async {
        if (++samples > 20 || revision != _sourceRevision ||
            !identical(observedPlayer, _videoPlayerController) ||
            !PlaybackDiagnostics.active) {
          timer.cancel();
          reader?.dispose();
          return;
        }
        PlaybackDiagnostics.event('command.seek.progress', {
          'targetMs': position.inMilliseconds,
          'elapsedUs': traceClock!.elapsedMicroseconds,
          'positionMs': observedPlayer?.state.position.inMilliseconds,
          'playing': observedPlayer?.state.playing,
          'buffering': observedPlayer?.state.buffering,
          'uiPositionSeconds': this.position.value,
        });
        if (reader == null || busy) return;
        busy = true;
        final readClock = Stopwatch()..start();
        const properties = ['current-ao', 'audio-pts', 'video-pts', 'time-pos', 'avsync', 'seeking', 'paused-for-cache'];
        try {
          final values = await Future.wait(properties.map(reader.read))
              .timeout(const Duration(milliseconds: 400));
          PlaybackDiagnostics.event('command.seek.native', {
            'targetMs': position.inMilliseconds,
            'elapsedUs': traceClock.elapsedMicroseconds,
            'readUs': readClock.elapsedMicroseconds,
            for (var i = 0; i < properties.length; i++) properties[i]: values[i],
          });
        } catch (error) {
          PlaybackDiagnostics.event('command.seek.nativeError', {
            'targetMs': position.inMilliseconds, 'error': error.toString(),
          });
        } finally { busy = false; }
      });
    }
    if (isSeek) {
      /// 拖动进度条调节时，不等待第一帧，防止抖动
      await _videoPlayerController?.stream.buffer.first;
    }
    danmakuController?.clear();
    try {
      if (PlaybackDiagnostics.enabled) {
        PlaybackDiagnostics.event('command.seek.begin', {
          'targetMs': position.inMilliseconds, 'elapsedUs': traceClock!.elapsedMicroseconds,
        });
      }
      await _videoPlayerController?.seek(position);
      if (PlaybackDiagnostics.enabled) {
        PlaybackDiagnostics.event('command.seek.return', {
          'targetMs': position.inMilliseconds, 'elapsedUs': traceClock!.elapsedMicroseconds,
        });
      }
      _updateIOSPip(position);
    } catch (e) {
      if (PlaybackDiagnostics.enabled) {
        PlaybackDiagnostics.event('command.seek.error', {
          'targetMs': position.inMilliseconds, 'error': e.toString(),
        });
      }
      if (kDebugMode) debugPrint('seek failed: $e');
    }
  }

  /// 跳转至指定位置
  Future<void> seekTo(Duration position, {bool isSeek = true}) async {
    if (_playerCount == 0) {
      return;
    }
    if (position < Duration.zero) {
      position = Duration.zero;
    }
    _heartDuration = position.inSeconds;

    if (duration.value != 0) {
      seek(position, isSeek: isSeek);
    } else {
      // if (kDebugMode) debugPrint('seek duration else');
      _subForSeek?.cancel();
      _subForSeek = duration.listen((_) {
        seek(position, isSeek: isSeek);
        _cancelSubForSeek();
      });
    }
  }

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    lastPlaybackSpeed = playbackSpeed;

    if (speed == _videoPlayerController?.state.rate) return;

    await _videoPlayerController?.setRate(speed);
    if (!isLive) _playbackSpeed.value = speed;
    _updatePlaybackState();
    if (danmakuController != null) {
      try {
        danmakuController?.updateOption(
          danmakuController!.option.copyWith(
            duration: DanmakuOptions.danmakuDuration / speed,
            staticDuration: DanmakuOptions.danmakuStaticDuration / speed,
          ),
        );
      } catch (_) {}
    }
  }

  /// 播放视频
  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    if (PlaybackDiagnostics.enabled) {
      PlaybackDiagnostics.event('command.play', playbackTraceState());
    }
    final player = _videoPlayerController;
    final request = _loadedSourceRequest;
    final revision = _sourceRevision;
    final output = _videoController;
    if (_playerCount == 0 || player == null || request?.isCurrent != true) {
      return;
    }
    bool current() =>
        _playerCount > 0 &&
        _videoPlayerController == player &&
        _videoController == output &&
        _loadedSourceRequest == request &&
        _sourceRevision == revision &&
        request!.isCurrent;
    // 播放时自动隐藏控制条
    controls = !hideControls;
    // repeat为true，将从头播放
    if (repeat) {
      await seekTo(Duration.zero, isSeek: false);
    }
    await PlaybackStart.run(
      isCurrent: current,
      isPlaying: () => player.state.playing,
      start: player.play,
      present: _presentPendingFrameIfNeeded,
      activate: () {
        audioSessionHandler?.setActive(true);
        playerStatus = .playing;
      },
    );
    _armAutoEnterPipAfterStableOutput();
  }

  /// 暂停播放
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    if (PlaybackDiagnostics.enabled) {
      PlaybackDiagnostics.event('command.pause', playbackTraceState());
    }
    await _videoPlayerController?.pause();
    playerStatus = .paused;

    // 主动暂停时让出音频焦点
    if (!isInterrupt) {
      audioSessionHandler?.setActive(false);
    }
  }

  bool tripling = false;

  /// 隐藏控制条
  void hideTaskControls() {
    _timer?.cancel();
    _timer = Timer(showControlDuration, () {
      if (!isSeeking.value && !tripling) {
        controls = false;
      }
      _timer = null;
    });
  }

  void onSeekStart(int seekFrom) {
    seekPosition.value = seekFrom;
    isSeeking.value = true;
  }

  void onSeekEnd() {
    if (showSeekPreview) {
      showPreview.value = false;
    }
    hasToasted = false;
    isSeeking.value = false;
    hideTaskControls();
  }

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  bool volumeInterceptEventStream = false;

  final double maxVolume = PlatformUtils.isDesktop ? Pref.maxVolume : 1.0;
  Future<void> setVolume(double volume, {bool showIndicator = true}) async {
    if (this.volume.value != volume) {
      this.volume.value = volume;
      try {
        if (PlatformUtils.isDesktop) {
          await _videoPlayerController!.setVolume(volume * 100);
        } else {
          FlutterVolumeController.updateShowSystemUI(false);
          await FlutterVolumeController.setVolume(volume);
        }
      } catch (err) {
        if (kDebugMode) debugPrint(err.toString());
      }
    }
    if (showIndicator) {
      volumeIndicator.value = true;
    }
    volumeInterceptEventStream = true;
    volumeTimer?.cancel();
    volumeTimer = Timer(const Duration(milliseconds: 200), () {
      volumeIndicator.value = false;
      volumeInterceptEventStream = false;
      if (PlatformUtils.isDesktop) {
        setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
      }
    });
  }

  /// Toggle Change the videofit accordingly
  void toggleVideoFit(VideoFitType value) {
    _prefFit = videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, value.index);
  }

  /// 读取fit
  var _prefFit = VideoFitType.values[Pref.cacheVideoFit];
  void _initVideoFit() {
    if (_prefFit == .fill && _isVertical) {
      videoFit.value = .contain;
    } else {
      videoFit.value = _prefFit;
    }
  }

  /// 设置后台播放
  void setBackgroundPlay(bool val) {
    videoPlayerServiceHandler?.enableBackgroundPlay = val;
    if (!tempPlayerConf) {
      setting.put(SettingBoxKey.enableBackgroundPlay, val);
    }
  }

  set controls(bool visible) {
    showControls.value = visible;
    _timer?.cancel();
    if (visible) {
      hideTaskControls();
    }
  }

  Timer? longPressTimer;
  void cancelLongPressTimer() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }

  /// 设置长按倍速状态 live模式下禁用
  Future<void> setLongPressStatus(bool val) async {
    if (isLive) {
      return;
    }
    if (controlsLock.value) {
      return;
    }
    if (longPressStatus.value == val) {
      return;
    }
    if (val) {
      if (playerStatus.isPlaying) {
        longPressStatus.value = val;
        HapticFeedback.lightImpact();
        await setPlaybackSpeed(
          enableAutoLongPressSpeed ? playbackSpeed * 2 : longPressSpeed,
        );
      }
    } else {
      // if (kDebugMode) debugPrint('$playbackSpeed');
      longPressStatus.value = val;
      await setPlaybackSpeed(lastPlaybackSpeed);
    }
  }

  bool get isCompleted =>
      videoPlayerController!.state.completed ||
      durationInMilliseconds - positionInMilliseconds <= 50;

  // 双击播放、暂停
  Future<void> onDoubleTapCenter() async {
    if (!isLive && isCompleted) {
      await videoPlayerController!.seek(Duration.zero);
      videoPlayerController!.play();
    } else {
      videoPlayerController!.playOrPause();
    }
  }

  final RxBool mountSeekBackwardButton = false.obs;
  final RxBool mountSeekForwardButton = false.obs;

  void onDoubleTapSeekBackward() {
    mountSeekBackwardButton.value = true;
  }

  void onDoubleTapSeekForward() {
    mountSeekForwardButton.value = true;
  }

  void onForward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position + duration);
  }

  void onBackward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position - duration);
  }

  void onForwardBackward(Duration duration) {
    seekTo(
      duration.clamp(Duration.zero, videoPlayerController!.state.duration),
      isSeek: false,
    ).whenComplete(play);
  }

  void doubleTapFuc(DoubleTapType type) {
    if (!enableQuickDouble) {
      onDoubleTapCenter();
      return;
    }
    switch (type) {
      case DoubleTapType.left:
        // 双击左边区域 👈
        onDoubleTapSeekBackward();
        break;
      case DoubleTapType.center:
        onDoubleTapCenter();
        break;
      case DoubleTapType.right:
        // 双击右边区域 👈
        onDoubleTapSeekForward();
        break;
    }
  }

  /// 关闭控制栏
  void onLockControl(bool val) {
    feedBack();
    controlsLock.value = val;
    if (!val && showControls.value) {
      showControls.refresh();
    }
    controls = !val;
  }

  void _setFullScreen(bool val) {
    isFullScreen.value = val;
    updateSubtitleStyle();
  }

  double screenRatio = 0.0;
  bool isManualFS = true;
  late final FullScreenMode mode = Pref.fullScreenMode;
  late final horizontalScreen = Pref.horizontalScreen;
  late final removeSafeArea = Pref.removeSafeArea;

  Future<void>? changeOrientation({
    required bool isVertical,
    DeviceOrientation? orientation,
  }) {
    if (orientation == null && (mode == .none || mode == .gravity)) {
      return null;
    }
    if (orientation == null &&
        (mode == .vertical ||
            (mode == .auto && isVertical) ||
            (mode == .ratio && (isVertical || screenRatio < kScreenRatio)))) {
      return portraitUpMode();
    } else {
      // https://github.com/flutter/flutter/issues/73651
      // https://github.com/flutter/flutter/issues/183708
      if (Platform.isAndroid) {
        if ((orientation ?? _orientation) == .landscapeRight) {
          return landscapeRightMode();
        } else {
          return landscapeLeftMode();
        }
      } else {
        if (orientation == .landscapeLeft) {
          return landscapeLeftMode();
        } else {
          return landscapeRightMode();
        }
      }
    }
  }

  // 全屏
  bool _fsProcessing = false;
  Future<void> triggerFullScreen({
    bool status = true,
    bool inAppFullScreen = false,
    DeviceOrientation? orientation,
    bool isManualFS = true,
  }) async {
    if (isDesktopPip) return;
    if (isFullScreen.value == status) return;

    if (_fsProcessing) return;
    _fsProcessing = true;
    this.isManualFS = isManualFS;
    try {
      if (status) {
        if (PlatformUtils.isMobile) {
          hideSystemBar();
          await changeOrientation(
            isVertical: isVertical,
            orientation: orientation,
          );
        } else {
          await enterDesktopFullScreen(inAppFullScreen: inAppFullScreen);
        }
      } else {
        if (PlatformUtils.isMobile) {
          if (!removeSafeArea) {
            showSystemBar();
          }
          if (orientation == null && mode == .none) {
            return;
          }
          await resetScreenRotation();
        } else {
          await exitDesktopFullScreen();
        }
      }
    } finally {
      _setFullScreen(status);
      _fsProcessing = false;
    }
  }

  void addPositionListener(ValueChanged<Duration> listener) {
    if (_playerCount == 0) return;
    _positionListeners.add(listener);
  }

  void removePositionListener(ValueChanged<Duration> listener) =>
      _positionListeners.remove(listener);

  void addStatusLister(ValueChanged<PlayerStatus> listener) {
    if (_playerCount == 0) return;
    _statusListeners.add(listener);
  }

  void removeStatusLister(ValueChanged<PlayerStatus> listener) =>
      _statusListeners.remove(listener);

  // 记录播放记录
  Future<void>? makeHeartBeat(
    int progress, {
    HeartBeatType type = .playing,
    bool isManual = false,
    dynamic aid,
    dynamic bvid,
    dynamic cid,
    dynamic epid,
    dynamic seasonId,
    dynamic pgcType,
    VideoType? videoType,
  }) {
    if (isLive ||
        !enableHeart ||
        progress == 0 ||
        (playerStatus.isPaused && !isManual)) {
      return null;
    }

    Future<void> send() {
      return VideoHttp.heartBeat(
        aid: aid ?? _aid,
        bvid: bvid ?? _bvid,
        cid: cid ?? this.cid,
        progress: progress,
        epid: epid ?? _epid,
        seasonId: seasonId ?? _seasonId,
        subType: pgcType ?? _pgcType,
        videoType: videoType ?? _videoType,
      );
    }

    switch (type) {
      case .playing:
        if (progress - _heartDuration >= 5) {
          _heartDuration = progress;
          return send();
        }
      case .status:
        if (progress - _heartDuration >= 2) {
          _heartDuration = progress;
          return send();
        }
      case .completed:
        if (playerStatus.isCompleted &&
            (durationInMilliseconds - positionInMilliseconds) <= 1000) {
          progress = -1;
        }
        return send();
    }
    return null;
  }

  void setPlayRepeat(PlayRepeat type) {
    playRepeat = type;
    if (!tempPlayerConf) video.put(VideoBoxKey.playRepeat, type.index);
  }

  void putSubtitleSettings() {
    setting.putAllNE({
      SettingBoxKey.subtitleFontScale: subtitleFontScale,
      SettingBoxKey.subtitleFontScaleFS: subtitleFontScaleFS,
      SettingBoxKey.subtitlePaddingH: subtitlePaddingH,
      SettingBoxKey.subtitlePaddingB: subtitlePaddingB,
      SettingBoxKey.subtitleBgOpacity: subtitleBgOpacity,
      SettingBoxKey.subtitleStrokeWidth: subtitleStrokeWidth,
      SettingBoxKey.subtitleFontWeight: subtitleFontWeight,
    });
  }

  bool _isCloseAll = false;
  bool get isCloseAll => _isCloseAll;

  Future<void>? resetScreenRotation() {
    if (horizontalScreen) {
      return fullMode();
    } else {
      return portraitUpMode();
    }
  }

  void onCloseAll() {
    _isCloseAll = true;
    if (PlatformUtils.isDesktop) exitDesktopFullScreen();
    dispose();
    Get.until((route) => route.isFirst);
  }

  void dispose() {
    // 每次减1，最后销毁
    resetScreenRotation();
    cancelLongPressTimer();
    _cancelSubForSeek();
    if (!_isCloseAll && _playerCount > 1) {
      _playerCount -= 1;
      _heartDuration = 0;
      return;
    }

    _playerCount = 0;
    _startupAudioDecodeQueue?.restore('dispose');
    _startupAudioDecodeQueue = null;
    _startupReadAheadTimer?.cancel();
    _startupReadAheadTimer = null;
    _startupReadAheadRevision = null;
    _sourceQueue.cancelAll();
    _parallelAudioSource?.close();
    _parallelAudioSource = null;
    _isolatedMediaSources?.close();
    _isolatedMediaSources = null;
    _readySourceOwner = null;
    _sourceOwner = null;
    _reloadSource = null;
    if (removeSafeArea) {
      showSystemBar();
    }
    danmakuController = null;
    _stopOrientationListener();
    _disableAutoEnterPip();
    setPlayCallBack(null);
    dmState.clear();
    if (showSeekPreview) {
      _clearPreview();
    }
    if (Platform.isIOS) IOSPipHelper.dispose();
    _timer?.cancel();
    // _position.close();
    // _playerEventSubs?.cancel();
    // _sliderPosition.close();
    // _sliderTempPosition.close();
    // _isSliderMoving.close();
    // _duration.close();
    // _buffered.close();
    // _showControls.close();
    // _controlsLock.close();

    // playerStatus.close();
    // dataStatus.close();

    if (PlatformUtils.isDesktop && isAlwaysOnTop.value) {
      windowManager.setAlwaysOnTop(false);
    }

    _removeListeners();
    _positionListeners.clear();
    _statusListeners.clear();
    _stopWakeLockTimer();
    WakelockPlus.disable();
    if (kDebugMode) {
      debugPrint('dispose player');
    }
    _videoPlayerController?.dispose();
    _videoPlayerController = null;
    _videoController = null;
    _instance = null;
    videoPlayerServiceHandler?.clear();
  }

  static void updatePlayCount() {
    if (_instance?._playerCount == 1) {
      _instance?.dispose();
    } else {
      _instance?._playerCount -= 1;
    }
  }

  void setContinuePlayInBackground() {
    continuePlayInBackground.toggle();
    if (!tempPlayerConf) {
      setting.put(
        SettingBoxKey.continuePlayInBackground,
        continuePlayInBackground.value,
      );
    }
  }

  late final Map<String, ui.Image?> previewCache = {};
  LoadingState<VideoShotData>? videoShot;
  late final RxBool showPreview = false.obs;
  late final showSeekPreview = Pref.showSeekPreview;
  late final previewIndex = RxnInt();

  void updatePreviewIndex(int seconds) {
    if (videoShot == null) {
      videoShot = LoadingState.loading();
      getVideoShot();
      return;
    }
    if (videoShot case Success(:final response)) {
      showPreview.value = true;
      previewIndex.value = max(
        0,
        (response.index.where((item) => item <= seconds).length - 2),
      );
    }
  }

  void _clearPreview() {
    showPreview.value = false;
    previewIndex.value = null;
    videoShot = null;
    for (final i in previewCache.values) {
      i?.dispose();
    }
    previewCache.clear();
  }

  Future<void> getVideoShot() async {
    videoShot = await VideoHttp.videoshot(bvid: bvid, cid: cid!);
  }

  Future<void> takeScreenshot() async {
    SmartDialog.showToast('截图中');
    final image = await videoPlayerController?.screenshot();
    if (image == null) {
      SmartDialog.showToast('截图失败');
      return;
    }

    var saved = false;
    Future<void> save() async {
      if (saved) return;
      saved = true;
      Get.back(result: false);
      final bytes = await image.toByteData(format: .png);
      image.dispose();
      if (bytes != null) {
        final time = DurationUtils.formatDuration(
          positionInMilliseconds / 1000,
        ).replaceAll(':', '-');
        ImageUtils.saveByteImg(
          bytes: bytes.buffer.asUint8List(),
          fileName: 'screenshot_${cid}_$time',
        );
      } else {
        SmartDialog.showToast('保存失败');
      }
    }

    SmartDialog.showToast('点击弹窗或按 Enter 保存截图');
    final dispose = await showDialog<bool>(
      context: Get.context!,
      builder: (context) => Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
            save();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: save,
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: min(MediaQuery.widthOf(context) / 3, 350),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      width: 5,
                      color: ColorScheme.of(context).surface,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: RawImage(image: image),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (dispose ?? true) image.dispose();
  }

  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) {
      _disableAutoEnterPip();
      if (playerStatus.isPlaying) {
        pause();
      }

      setPlayCallBack(null);

      if (Platform.isAndroid && _playerCount <= 1) {
        if (!setSystemBrightness) {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      }

      return;
    }

    if (controlsLock.value) {
      onLockControl(false);
      return;
    }
    if (isDesktopPip) {
      exitDesktopPip();
      return;
    }
    if (isFullScreen.value) {
      triggerFullScreen(status: false);
      return;
    }
    Get.back();
  }
}
