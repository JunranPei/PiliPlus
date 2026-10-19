import 'dart:async' show Completer, StreamSubscription, Timer, unawaited;
import 'dart:convert' show ascii, utf8;
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
import 'package:PiliPlus/plugin/pl_player/playback/mpv_frame_gate.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_source_queue.dart';
import 'package:PiliPlus/plugin/pl_player/playback/source_preparation.dart';
import 'package:PiliPlus/plugin/pl_player/playback/startup_probe.dart';
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

class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
  Player? _videoPlayerController;
  VideoController? _videoController;
  final _sourceQueue = PlaybackSourceQueue();
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
    if (!configured || autoEnter) return configured;
    return AndroidPipController.instance.enter();
  }

  void _disableAutoEnterPip() {
    if (_isAutoEnterPip) {
      if (Platform.isIOS) {
        IOSPipHelper.disableAutoEnter();
      } else {
        unawaited(AndroidPipController.instance.disableAutoEnter());
      }
    }
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
        _diagnosticRequest = request.id;
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

  static String _engineSettings() => [
    Pref.videoSync,
    Pref.audioOutput,
    Pref.playerVolume,
    Pref.enableHA,
    Pref.hardwareDecoding,
    Pref.autosync,
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
      if (Platform.isWindows) 'gpu-api': 'd3d11',
      'vd-lavc-fast': 'yes',
      'vd-lavc-dr': 'yes',
      'vd-lavc-threads': '0',
    };
    final autosync = Pref.autosync;
    if (autosync != '0') {
      opt['autosync'] = autosync;
    }

    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: StartupProbe.deep
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

  Future<Player> _initPlayer() async {
    assert(_videoPlayerController == null);
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

    if (player == null) {
      player = await _initPlayer();
      if (_playerCount == 0) {
        _removeListeners();
        player.dispose();
        player = null;
        _videoController = null;
        return;
      }
      _videoPlayerController = player;
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
    String video = source.video;
    if (source.audio case final audio? when (audio.isNotEmpty)) {
      if (onlyPlayAudio.value) {
        video = audio;
      } else {
        // dely_open need provide length
        video =
            ('edl://'
            '!no_chapters;'
            // '!delay_open,media_type=video;'
            '%${isFileSource ? utf8.encode(video).length : video.length}%$video;'
            '!new_stream;!no_chapters;'
            // '!delay_open,media_type=audio;'
            '%${isFileSource ? utf8.encode(audio).length : audio.length}%$audio');
      }
      audioFilterExtras(volume, map: extras);
    }

    assert(!isLive || seekTo == null);
    final gate = waitForFrame ? MpvFrameGate(player, source: video) : null;
    _diagnosticSource = PlaybackDiagnostics.sourceId(video);
    if (PlaybackDiagnostics.enabled) {
      PlaybackDiagnostics.event('source.open.begin', playbackTraceState());
    }
    try {
      StartupProbe.beginSource();
      Future<void> openPaused() async {
        await player!.open(
          Media(video, start: seekTo, extras: extras.isEmpty ? null : extras),
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
      if (gate != null) {
        await Future.any<void>([
          gate.ready,
          request.cancelled.then<void>(
            (_) => throw const PlaybackSourceCancelled(),
          ),
        ]);
        request.checkCurrent();
        await _waitForVideoOutput(request);
      }
    } finally {
      gate?.dispose();
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
  Future<void> _waitForStableVideoOutput({
    required int sourceRevision,
    // Autoplay starts before Android has attached the decoded surface. On the
    // emulator that handoff can take a few seconds; a short fallback reveals
    // the cover onto an empty texture and makes startup look slower.
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final controller = _videoController;
    if (controller == null) return;
    final started = Stopwatch()..start();
    String? previous;
    var stableSamples = 0;
    while (started.elapsed < timeout) {
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
        return;
      }
      if (sourceRevision != _sourceRevision || _videoController != controller) {
        return;
      }
      final rect = controller.rect.value;
      final state = controller.player.state;
      final id = controller.id.value;
      final valid =
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
            });
          }
          return;
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
      });
    }
  }

  Future<void> _presentPendingFrameIfNeeded() async {
    final callback = _pendingFrameReady;
    if (callback == null) return;
    final revision = _pendingFrameReadyRevision;
    _pendingFrameReady = null;
    if (PlaybackDiagnostics.enabled) {
      PlaybackDiagnostics.event('output.stable.wait', {
        ...playbackTraceState(),
        'sourceRevision': revision,
      });
    }
    await _waitForStableVideoOutput(sourceRevision: revision);
    if (revision != _sourceRevision) return;
    await callback();
  }

  /// Public counterpart used when a source is already loaded but its Flutter
  /// presentation is still covered (for example, after returning to a video
  /// route).  It intentionally does not reveal anything by itself; the owner
  /// changes its frame-ready flag only after this future completes.
  Future<void> waitForStableVideoOutput() =>
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
    _subscriptions = [
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

          if (_isAutoEnterPip) {
            if (_isCurrVideoPage) {
              enterPip(autoEnter: true);
            } else {
              _disableAutoEnterPip();
            }
          }
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
    if (isSeek) {
      /// 拖动进度条调节时，不等待第一帧，防止抖动
      await _videoPlayerController?.stream.buffer.first;
    }
    danmakuController?.clear();
    try {
      await _videoPlayerController?.seek(position);
      _updateIOSPip(position);
    } catch (e) {
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
    if (_playerCount == 0) return;
    // 播放时自动隐藏控制条
    controls = !hideControls;
    // repeat为true，将从头播放
    if (repeat) {
      await seekTo(Duration.zero, isSeek: false);
    }

    await _videoPlayerController?.play();

    // Do not reveal the Flutter presentation until the post-play surface
    // handoff has converged.  This is a no-op for ordinary play commands
    // without a pending source callback.
    await _presentPendingFrameIfNeeded();

    audioSessionHandler?.setActive(true);

    playerStatus = .playing;
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
    _sourceQueue.cancelAll();
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
      if (playerStatus.isPlaying) {
        pause();
      }

      setPlayCallBack(null);

      if (Platform.isAndroid && _playerCount <= 1) {
        _disableAutoEnterPip();
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
