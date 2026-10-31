import 'dart:async' show Completer, unawaited;
import 'dart:io' show Platform;
import 'dart:math';

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/keep_alive_wrapper.dart';
import 'package:PiliPlus/common/widgets/route_aware_mixin.dart';
import 'package:PiliPlus/common/widgets/scaffold/mini_scaffold.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/scroll_behavior.dart'
    show NoOverscrollIndicator;
import 'package:PiliPlus/common/widgets/scroll_physics.dart'
    show tabBarView, platformAlwaysClampingPhysics, platformClampingPhysics;
import 'package:PiliPlus/common/widgets/simple_app_bar.dart';
import 'package:PiliPlus/common/widgets/sliver/video_header.dart';
import 'package:PiliPlus/common/widgets/svg/play_icon.dart';
import 'package:PiliPlus/models/common/episode_panel_type.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/models_new/video/video_detail/ugc_season.dart';
import 'package:PiliPlus/models_new/video/video_tag/data.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/danmaku/view.dart';
import 'package:PiliPlus/pages/episode_panel/view.dart';
import 'package:PiliPlus/pages/video/ai_conclusion/view.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/view.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/view.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/widgets/intro_detail.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/widgets/season.dart'
    as pgc;
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/view.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/page.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/season.dart'
    as ugc;
import 'package:PiliPlus/pages/video/member/controller.dart';
import 'package:PiliPlus/pages/video/member/view.dart';
import 'package:PiliPlus/pages/video/related/view.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/pages/video/reply/view.dart';
import 'package:PiliPlus/pages/video/view_point/view.dart';
import 'package:PiliPlus/pages/video/widgets/header_control.dart';
import 'package:PiliPlus/pages/video/widgets/intro_layout.dart';
import 'package:PiliPlus/pages/video/widgets/player_focus.dart';
import 'package:PiliPlus/plugin/pl_player/android_pip_controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/video_presentation.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/plugin/pl_player/view/view.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart'
    show shutdownTimerService;
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/max_screen_size.dart';
import 'package:PiliPlus/utils/mobile_observer.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:flutter/foundation.dart' show kDebugMode, clampDouble;
import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';
import 'package:PiliPlus/plugin/pl_player/playback/startup_text_inventory.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

class VideoDetailPageV extends StatefulWidget {
  const VideoDetailPageV({super.key});

  @override
  State<VideoDetailPageV> createState() => _VideoDetailPageVState();
}

class _VideoDetailPageVState extends State<VideoDetailPageV>
    with RouteAware, RouteAwareMixin, WidgetsBindingObserver {
  final heroTag = Get.arguments['heroTag'];
  final Set<VoidCallback> _cancelRouteWaits = {};
  Animation<double>? _coverAnimation;
  final Completer<bool> _initialPlaybackLayout = Completer<bool>();

  late final VideoDetailController videoDetailController;
  late final VideoReplyController _videoReplyController;
  PlPlayerController? plPlayerController;

  // intro ctr
  late final CommonIntroController introController;
  late final UgcIntroController ugcIntroController;
  late final PgcIntroController pgcIntroController;
  late final LocalIntroController localIntroController;

  // dart format off
  CommonIntroController _initIntroCtr() {
    if (videoDetailController.isFileSource) {
      return localIntroController = Get.put(LocalIntroController(), tag: heroTag);
    } else if (videoDetailController.isUgc) {
      return ugcIntroController = Get.put(UgcIntroController(), tag: heroTag);
    } else {
      return pgcIntroController = Get.put(PgcIntroController(), tag: heroTag);
    }
  }
  // dart format on

  bool get autoExitFullscreen =>
      videoDetailController.plPlayerController.autoExitFullscreen;

  bool get autoPlayEnable =>
      videoDetailController.plPlayerController.autoPlayEnable;

  bool get enableVerticalExpand =>
      videoDetailController.plPlayerController.enableVerticalExpand;

  bool get pipNoDanmaku =>
      videoDetailController.plPlayerController.pipNoDanmaku;

  bool isShowing = true;

  bool get isFullScreen =>
      videoDetailController.plPlayerController.isFullScreen.value;

  bool get _shouldShowSeasonPanel {
    if (videoDetailController.isFileSource ||
        isPortrait ||
        !videoDetailController.plPlayerController.horizontalSeasonPanel) {
      return false;
    }
    if (videoDetailController.isUgc) {
      return ugcIntroController.videoDetail.value.hasSeasonOrParts;
    }
    if (videoDetailController.videoType == .pgc) {
      return pgcIntroController.pgcItem.hasEpisodes;
    }
    return false;
  }

  final videoReplyPanelKey = GlobalKey();
  final videoRelatedKey = GlobalKey();
  final videoIntroKey = GlobalKey();

  @override
  void initState() {
    super.initState();

    videoDetailController = Get.put(VideoDetailController(), tag: heroTag);
    plPlayerController = videoDetailController.plPlayerController;
    AndroidPipController.instance.addListener(_onPipStateChanged);

    introController = _initIntroCtr();

    _setPlayCallBack();

    if (videoDetailController.removeSafeArea) {
      hideSystemBar();
    }

    if (videoDetailController.showReply) {
      _videoReplyController = Get.put(
        VideoReplyController(
          aid: videoDetailController.aid,
          videoType: videoDetailController.videoType,
          heroTag: heroTag,
        ),
        tag: heroTag,
      );
    }

    videoDetailController.waitForPlaybackRoute = _waitForPlaybackRoute;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && StartupTextInventory.enabled) {
        StartupTextInventory.capture(context, 'video.firstLayout');
      }
      if (!_initialPlaybackLayout.isCompleted) {
        _initialPlaybackLayout.complete(mounted);
      }
    });
    videoSourceInit();

    addObserverMobile(this);
  }

  void _onPipStateChanged() {
    // If PiP starts while the ordinary-page output handshake is still
    // settling, do not let the native transition capture the cover/placeholder
    // layer.  Android scales the already-playing texture itself during this
    // window; the normal page will still finish its geometry handshake after
    // the transition.
    if (AndroidPipController.instance.isEntering &&
        videoDetailController.videoState.value &&
        videoDetailController
                .plPlayerController
                .videoPlayerController
                ?.state
                .playing ==
            true) {
      videoDetailController.frameReady.value = true;
    }
    if (mounted) setState(() {});
  }

  // 获取视频资源，初始化播放器
  void videoSourceInit() {
    videoDetailController.queryVideoUrl(autoFullScreenFlag: true);
    if (videoDetailController.autoPlay) {
      plPlayerController = videoDetailController.plPlayerController;
      plPlayerController!
        ..addStatusLister(playerListener)
        ..addPositionListener(positionListener);
    }
  }

  void positionListener(Duration position) {
    if (!_ownsReadyPlayback) return;
    videoDetailController.playedTime = position;
  }

  bool get _ownsReadyPlayback =>
      isShowing &&
      videoDetailController.frameReady.value &&
      videoDetailController.plPlayerController.hasSourceFor(
        videoDetailController,
        videoDetailController.cid.value,
      );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isResume = state == .resumed;
    final ctr = videoDetailController.plPlayerController..visible = isResume;
    if (isResume) {
      if (!ctr.showDanmaku) {
        introController.startTimer();
        ctr.showDanmaku = true;
      }
    } else if (state == .paused) {
      introController.cancelTimer();
      ctr.showDanmaku = false;
    }
  }

  void _setPlayCallBack() {
    PlPlayerController.setPlayCallBack(
      playCallBack,
      playOwner: (tag: heroTag, type: introController.runtimeType),
    );
  }

  Future<void>? playCallBack() {
    if (!isShowing) {
      plPlayerController
        ?..addStatusLister(playerListener)
        ..addPositionListener(positionListener);
    }
    return videoDetailController.requestPlayback();
  }

  // 播放器状态监听
  Future<void> playerListener(PlayerStatus status) async {
    if (!_ownsReadyPlayback) return;
    final isPlaying = status.isPlaying;
    try {
      if (videoDetailController.scrollCtr.hasClients) {
        if (isPlaying) {
          if (!videoDetailController.isExpanding &&
              videoDetailController.scrollCtr.offset != 0 &&
              !videoDetailController.animationController.isAnimating) {
            videoDetailController.isExpanding = true;
            videoDetailController.animationController.forward(
              from:
                  1 -
                  videoDetailController.scrollCtr.offset /
                      videoDetailController.videoHeight,
            );
          } else {
            videoDetailController.refreshPage();
          }
        } else {
          videoDetailController.refreshPage();
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('handle player status: $e');
    }

    if (status.isCompleted) {
      try {
        if (videoDetailController
                .steinEdgeInfo
                ?.edges
                ?.questions
                ?.firstOrNull
                ?.choices
                ?.isNotEmpty ==
            true) {
          videoDetailController.showSteinEdgeInfo.value = true;
          return;
        }
      } catch (_) {}

      bool exitFlag = true;

      /// 顺序播放 列表循环
      if (shutdownTimerService.isWaiting) {
        shutdownTimerService.handleWaiting();
      } else {
        switch (plPlayerController!.playRepeat) {
          case PlayRepeat.singleCycle:
            exitFlag = false;
            plPlayerController!.play(repeat: true);
          case PlayRepeat.listOrder:
          case PlayRepeat.listCycle:
          case PlayRepeat.autoPlayRelated:
            exitFlag = !introController.nextPlay();
          case PlayRepeat.pause:
        }
      }

      if (exitFlag) {
        if (autoExitFullscreen) {
          plPlayerController!.triggerFullScreen(status: false);
          if (plPlayerController!.controlsLock.value) {
            plPlayerController!.onLockControl(false);
          }
        } else {
          if (plPlayerController!.controlsLock.value &&
              (!Platform.isAndroid ||
                  !AndroidPipController.instance.protectsPlayback)) {
            plPlayerController!.onLockControl(false);
          }
        }
      }
    }
  }

  // 继续播放或重新播放
  void continuePlay() {
    plPlayerController!.play();
  }

  /// Every play entry uses this page's source and preparation state.
  Future<void> handlePlay() {
    plPlayerController = videoDetailController.plPlayerController;
    plPlayerController!
      ..addStatusLister(playerListener)
      ..addPositionListener(positionListener);
    return videoDetailController.requestPlayback(autoFullScreenFlag: true);
  }

  Future<bool> _waitForPlaybackRoute() async {
    if (!_initialPlaybackLayout.isCompleted &&
        !await _initialPlaybackLayout.future) {
      return false;
    }
    if (!mounted || !isShowing) return false;
    final route = ModalRoute.of(context);
    if (route == null) return true;
    if (!route.isCurrent) return false;
    final entry = route.animation;
    final covering = route.secondaryAnimation;
    bool settled() =>
        (entry == null || entry.status == AnimationStatus.completed) &&
        (covering == null || covering.status == AnimationStatus.dismissed);
    if (settled()) return true;
    final result = Completer<bool>();
    void finish(bool value) {
      if (!result.isCompleted) result.complete(value);
    }

    void cancel() => finish(false);
    void changed(AnimationStatus _) {
      if (!mounted || !isShowing || !route.isCurrent) {
        finish(false);
      } else if (settled()) {
        finish(true);
      }
    }

    _cancelRouteWaits.add(cancel);
    entry?.addStatusListener(changed);
    covering?.addStatusListener(changed);
    try {
      changed(AnimationStatus.forward);
      return await result.future;
    } finally {
      _cancelRouteWaits.remove(cancel);
      entry?.removeStatusListener(changed);
      covering?.removeStatusListener(changed);
    }
  }

  void _cancelPlaybackRouteWaits() {
    for (final cancel in _cancelRouteWaits.toList()) {
      cancel();
    }
  }

  void _onCovered(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          isShowing ||
          _coverAnimation?.status != AnimationStatus.completed) {
        return;
      }
      videoDetailController.videoState.value = false;
      videoDetailController.frameReady.value = false;
    });
  }

  @override
  void dispose() {
    if (!_initialPlaybackLayout.isCompleted) {
      _initialPlaybackLayout.complete(false);
    }
    AndroidPipController.instance.removeListener(_onPipStateChanged);
    plPlayerController
      ?..removeStatusLister(playerListener)
      ..removePositionListener(positionListener);

    Get.delete<HorizontalMemberPageController>(
      tag: videoDetailController.heroTag,
    );

    if (!videoDetailController.isFileSource) {
      if (videoDetailController.isUgc) {
        ugcIntroController
          ..cancelTimer()
          ..videoDetail.close();
      } else {
        pgcIntroController.cancelTimer();
      }
    }

    if (!videoDetailController.removeSafeArea) {
      showSystemBar();
    }

    _cancelPlaybackRouteWaits();
    _coverAnimation?.removeStatusListener(_onCovered);
    videoDetailController
      ..leavePlaybackRoute()
      ..waitForPlaybackRoute = null;

    if (!videoDetailController.plPlayerController.isCloseAll) {
      videoPlayerServiceHandler?.onVideoDetailDispose(heroTag);
      if (plPlayerController != null) {
        videoDetailController.makeHeartBeat();
        final shouldPause = plPlayerController!.playerCount <= 1;
        if (shouldPause) {
          plPlayerController!.pause();
        }
        plPlayerController!.dispose();
      } else {
        PlPlayerController.updatePlayCount();
      }
    }
    removeObserverMobile(this);

    super.dispose();
  }

  @override
  // 离开当前页面时
  void didPushNext() {
    super.didPushNext();
    isShowing = false;

    removeObserverMobile(this);

    if (Platform.isAndroid && !videoDetailController.setSystemBrightness) {
      ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
    }

    introController.cancelTimer();

    // 只在确实处于画中画模式时跳过暂停，不再依赖 isEnteringPip
    // 因为 didPushNext 是应用内页面切换触发的，不可能是"正在进入PiP"
    if (AndroidPipController.instance.isActive) {
      return; // 已在画中画，保留播放器状态，不进行注销与暂停
    }

    videoDetailController.leavePlaybackRoute();
    _cancelPlaybackRouteWaits();
    videoDetailController.cancelBlockListener();
    final ownsSource =
        plPlayerController?.hasSourceFor(
          videoDetailController,
          videoDetailController.cid.value,
        ) ==
        true;
    if (ownsSource) {
      videoDetailController
        ..playedTime = plPlayerController?.videoPlayerController?.state.position
        ..playerStatus = plPlayerController?.playerStatus
        ..brightness = plPlayerController?.brightness.value;
    }
    if (plPlayerController != null) {
      plPlayerController!
        ..removeStatusLister(playerListener)
        ..removePositionListener(positionListener);
      if (ownsSource) {
        videoDetailController.makeHeartBeat();
        unawaited(plPlayerController!.pause());
      }
    }
  }

  @override
  // 返回当前页面时
  void didPopNext() {
    super.didPopNext();

    if (videoDetailController.plPlayerController.isCloseAll) {
      return;
    }

    isShowing = true;

    addObserverMobile(this);

    plPlayerController?.isLive = false;
    if (videoDetailController.plPlayerController.playerStatus.isPlaying &&
        videoDetailController.playerStatus != PlayerStatus.playing) {
      videoDetailController.plPlayerController.pause();
    }

    _setPlayCallBack();

    introController.startTimer();

    if (mounted &&
        Platform.isAndroid &&
        !videoDetailController.setSystemBrightness) {
      if (videoDetailController.brightness != null) {
        plPlayerController?.brightness.value =
            videoDetailController.brightness!;
        if (videoDetailController.brightness != -1.0) {
          ScreenBrightnessPlatform.instance.setApplicationScreenBrightness(
            videoDetailController.brightness!,
          );
        } else {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      } else {
        ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
      }
    }

    final sameSource = videoDetailController.plPlayerController.hasSourceFor(
      videoDetailController,
      videoDetailController.cid.value,
    );
    videoDetailController.returnToPlaybackRoute(
      restoreCurrentSource: sameSource,
    );
    plPlayerController
      ?..addStatusLister(playerListener)
      ..addPositionListener(positionListener);
    if (sameSource &&
        videoDetailController.playerStatus == PlayerStatus.playing) {
      unawaited(videoDetailController.requestPlayback());
    } else if (!sameSource &&
        videoDetailController.plPlayerController.preInitPlayer &&
        !videoDetailController.isQuerying &&
        (videoDetailController.isFileSource ||
            videoDetailController.videoUrl != null)) {
      unawaited(videoDetailController.playerInit(autoplay: false));
    }
  }

  @override
  void didPop() {
    super.didPop();
    isShowing = false;
    videoDetailController.leavePlaybackRoute(permanently: true);
    _cancelPlaybackRouteWaits();
    plPlayerController
      ?..removeStatusLister(playerListener)
      ..removePositionListener(positionListener);
    if (plPlayerController?.hasSourceFor(
          videoDetailController,
          videoDetailController.cid.value,
        ) ==
        true) {
      unawaited(plPlayerController!.pause());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final covering = ModalRoute.of(context)?.secondaryAnimation;
    if (_coverAnimation != covering) {
      _coverAnimation?.removeStatusListener(_onCovered);
      _coverAnimation = covering;
      covering?.addStatusListener(_onCovered);
    }
    if (videoDetailController.removeSafeArea) {
      padding = .zero;
    } else {
      padding = MediaQuery.viewPaddingOf(context);
    }

    final size = MediaQuery.sizeOf(context);
    maxWidth = size.width;
    maxHeight = size.height;
    isWindowMode = MaxScreenSize.isWindowMode(
      width: maxWidth * videoDetailController.uiScale,
      height: maxHeight * videoDetailController.uiScale,
    );
    videoDetailController.plPlayerController.screenRatio = maxHeight / maxWidth;

    final shortestSide = size.shortestSide;
    final minVideoHeight = shortestSide / Style.aspectRatio16x9;
    final maxVideoHeight = max(size.longestSide * 0.65, shortestSide);
    // Keep the pre-PiP orientation while Android is resizing the activity.
    // Switching portrait/landscape branches here reparents PLVideoPlayer and
    // detaches media_kit's Surface during the PiP animation.
    if (!AndroidPipController.instance.protectsPlayback) {
      videoDetailController.isPortrait = isPortrait = maxHeight >= maxWidth;
    }
    videoDetailController
      ..minVideoHeight = minVideoHeight
      ..maxVideoHeight = maxVideoHeight
      ..videoHeight = videoDetailController.isVertical.value
          ? maxVideoHeight
          : minVideoHeight;

    theme = videoDetailController.plPlayerController.darkVideoPage
        ? ThemeUtils.darkTheme
        : Theme.of(context);
  }

  bool removeAppBar(bool isFullScreen) =>
      PlatformUtils.isDesktop ||
      videoDetailController.removeSafeArea ||
      (isWindowMode && isFullScreen && !isPortrait);

  Widget get childWhenDisabled {
    return Obx(
      () {
        // Native PiP crops the original video region. Keep its page geometry
        // unchanged instead of expanding the player to a full-screen layout.
        final isFullScreen = this.isFullScreen;
        return SimpleScaffold(
          appBar: removeAppBar(isFullScreen)
              ? null
              : Obx(
                  () {
                    final scrollRatio = videoDetailController.scrollRatio.value;
                    final brightness = colorScheme.brightness;
                    final Brightness statusBarBrightness;
                    final Brightness statusBarIconBrightness;
                    final backgroundColor = isPortrait && scrollRatio > 0
                        ? Color.lerp(
                            Colors.black,
                            colorScheme.surface,
                            scrollRatio,
                          )!
                        : Colors.black;
                    if (isPortrait && scrollRatio >= 0.5) {
                      statusBarBrightness = brightness;
                      statusBarIconBrightness = brightness.reverse;
                    } else {
                      statusBarBrightness = .dark;
                      statusBarIconBrightness = .light;
                    }
                    return SimpleAppBar(
                      height: padding.top,
                      backgroundColor: backgroundColor,
                      brightness: brightness,
                      statusBarBrightness: statusBarBrightness,
                      statusBarIconBrightness: statusBarIconBrightness,
                    );
                  },
                ),
          body: ExtendedNestedScrollView(
            onlyOneScrollInBody: true,
            physics: platformClampingPhysics,
            key: videoDetailController.scrollKey,
            controller: videoDetailController.scrollCtr,
            scrollBehavior: const NoOverscrollIndicator(),
            pinnedHeaderSliverHeightBuilder: () {
              double pinnedHeight = this.isFullScreen || !isPortrait
                  ? maxHeight - (isWindowMode && !isPortrait ? 0 : padding.top)
                  : videoDetailController.isExpanding ||
                        videoDetailController.isCollapsing
                  ? videoDetailController.animHeight
                  : videoDetailController.isCollapsing ||
                        (plPlayerController?.playerStatus.isPlaying ?? false)
                  ? videoDetailController.minVideoHeight
                  : kToolbarHeight;
              if (videoDetailController.isExpanding &&
                  videoDetailController.animationController.value == 1) {
                videoDetailController.isExpanding = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  videoDetailController.scrollRatio.value = 0;
                  videoDetailController.refreshPage();
                });
              } else if (videoDetailController.isCollapsing &&
                  videoDetailController.animationController.value == 1) {
                videoDetailController.isCollapsing = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  videoDetailController.refreshPage();
                });
              }
              return pinnedHeight;
            },
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              final height = isFullScreen || !isPortrait
                  ? maxHeight - (isWindowMode && !isPortrait ? 0 : padding.top)
                  : videoDetailController.isExpanding ||
                        videoDetailController.isCollapsing
                  ? videoDetailController.animHeight
                  : videoDetailController.videoHeight;
              return [
                VideoHeader(
                  minExtent: kToolbarHeight,
                  maxExtent: height,
                  minVideoHeight: videoDetailController.minVideoHeight,
                  onScrollRatioChanged: videoDetailController.scrollRatio.call,
                  child: Stack(
                    clipBehavior: .none,
                    children: [
                      SizedBox(
                        width: maxWidth,
                        height: height,
                        child: videoPlayer(width: maxWidth, height: height),
                      ),
                      _buildHeaderOverlay(),
                    ],
                  ),
                ),
              ];
            },
            body: MiniScaffold(
              key: videoDetailController.childKey,
              body: Column(
                children: [
                  buildTabBar(onTap: videoDetailController.animToTop),
                  Expanded(
                    child: tabBarView(
                      hitTestBehavior: .translucent,
                      controller: videoDetailController.tabCtr,
                      children: [
                        videoIntro(isHorizontal: false, needCtr: false),
                        if (videoDetailController.showReply)
                          videoReplyPanel(isNested: true),
                        if (_shouldShowSeasonPanel) seasonPanel,
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildOverlayToolBar(double scrollRatio) {
    final IconData icon;
    final String playStat;
    if (videoDetailController.playedTime == null) {
      icon = Icons.play_arrow_rounded;
      playStat = '立即';
    } else if (plPlayerController!.isCompleted) {
      icon = CustomIcons.replay_rounded;
      playStat = '重新';
    } else {
      icon = Icons.play_arrow_rounded;
      playStat = '继续';
    }
    final playBtn = Row(
      spacing: 2,
      mainAxisSize: .min,
      children: [
        Icon(icon, color: colorScheme.primary),
        Text(
          '$playStat播放',
          style: TextStyle(color: colorScheme.primary),
        ),
      ],
    );
    return Opacity(
      opacity: videoDetailController.scrollRatio.value,
      child: Container(
        color: colorScheme.surface,
        alignment: .topCenter,
        child: SizedBox(
          height: kToolbarHeight,
          child: Stack(
            clipBehavior: .none,
            children: [
              Align(
                alignment: .centerLeft,
                child: Row(
                  mainAxisSize: .min,
                  children: [
                    SizedBox(
                      width: 42,
                      height: 34,
                      child: IconButton(
                        tooltip: '返回',
                        icon: Icon(
                          FontAwesomeIcons.arrowLeft,
                          size: 15,
                          color: colorScheme.onSurface,
                        ),
                        onPressed: Get.back,
                      ),
                    ),
                    SizedBox(
                      width: 42,
                      height: 34,
                      child: IconButton(
                        tooltip: '返回主页',
                        icon: Icon(
                          FontAwesomeIcons.house,
                          size: 15,
                          color: colorScheme.onSurface,
                        ),
                        onPressed:
                            videoDetailController.plPlayerController.onCloseAll,
                      ),
                    ),
                  ],
                ),
              ),
              Center(child: playBtn),
              Align(
                alignment: .centerRight,
                child: videoDetailController.playedTime == null
                    ? _moreBtn(colorScheme.onSurface)
                    : SizedBox(
                        width: 42,
                        height: 34,
                        child: IconButton(
                          tooltip: "更多设置",
                          style: const ButtonStyle(
                            padding: WidgetStatePropertyAll(EdgeInsets.zero),
                          ),
                          onPressed: () =>
                              (videoDetailController.headerCtrKey.currentState
                                      as HeaderControlState?)
                                  ?.showSettingSheet(),
                          icon: Icon(
                            Icons.more_vert_outlined,
                            size: 19,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderOverlay() {
    return Obx(
      () {
        final scrollRatio = videoDetailController.scrollRatio.value;
        if (scrollRatio == 0) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          bottom: -1,
          child: GestureDetector(
            onTap: () {
              if (!videoDetailController.isFileSource) {
                if (videoDetailController.isQuerying) {
                  if (kDebugMode) {
                    debugPrint('handlePlay: querying');
                  }
                  return;
                }
                if (videoDetailController.videoUrl == null ||
                    videoDetailController.audioUrl == null) {
                  if (kDebugMode) {
                    debugPrint('handlePlay: videoUrl/audioUrl not initialized');
                  }
                  videoDetailController.queryVideoUrl();
                  return;
                }
              }
              if (plPlayerController == null ||
                  videoDetailController.playedTime == null) {
                handlePlay();
              } else {
                plPlayerController!.onDoubleTapCenter();
              }
            },
            behavior: .opaque,
            child: _buildOverlayToolBar(scrollRatio),
          ),
        );
      },
    );
  }

  Widget get childWhenDisabledLandscape => Obx(
    () {
      final isFullScreen = this.isFullScreen;
      return SimpleScaffold(
        appBar: removeAppBar(isFullScreen)
            ? null
            : SimpleAppBar(
                height: padding.top,
                brightness: colorScheme.brightness,
              ),
        body: Padding(
          padding: isFullScreen
              ? EdgeInsets.zero
              : padding.copyWith(top: 0, bottom: 0),
          child: childWhenDisabledLandscapeInner(isFullScreen),
        ),
      );
    },
  );

  Widget childSplit(double ratio) {
    final double videoHeight = maxHeight - padding.vertical;
    final double width = videoHeight * ratio;
    final videoWidth = isFullScreen ? maxWidth : width;
    final introWidth = maxWidth - width - padding.horizontal;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: videoWidth,
          height: videoHeight,
          child: videoPlayer(
            width: videoWidth,
            height: videoHeight,
          ),
        ),
        Offstage(
          offstage: isFullScreen,
          child: SizedBox(
            width: introWidth,
            height: maxHeight - padding.top,
            child: MiniScaffold(
              key: videoDetailController.childKey,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  buildTabBar(),
                  Expanded(
                    child: tabBarView(
                      controller: videoDetailController.tabCtr,
                      children: [
                        videoIntro(
                          width: introWidth,
                          height: maxHeight,
                        ),
                        if (videoDetailController.showReply) videoReplyPanel(),
                        if (_shouldShowSeasonPanel) seasonPanel,
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget childWhenDisabledLandscapeInner(bool isFullScreen) {
    if (enableVerticalExpand) {
      return Obx(() {
        if (videoDetailController.isVertical.value && !isPortrait) {
          final double videoHeight = maxHeight - padding.vertical;
          final double width = videoHeight / Style.aspectRatio16x9;
          final videoWidth = isFullScreen ? maxWidth : width;
          final introWidth = (maxWidth - padding.horizontal - width) / 2;
          final introHeight = maxHeight - padding.top;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Offstage(
                offstage: isFullScreen,
                child: SizedBox(
                  width: introWidth,
                  height: introHeight,
                  child: videoIntro(
                    width: introWidth,
                    height: introHeight,
                  ),
                ),
              ),
              SizedBox(
                width: videoWidth,
                height: videoHeight,
                child: videoPlayer(
                  width: videoWidth,
                  height: videoHeight,
                ),
              ),
              Offstage(
                offstage: isFullScreen,
                child: SizedBox(
                  width: introWidth,
                  height: introHeight,
                  child: MiniScaffold(
                    key: videoDetailController.childKey,
                    body: Column(
                      children: [
                        buildTabBar(showIntro: false),
                        Expanded(
                          child: tabBarView(
                            controller: videoDetailController.tabCtr,
                            children: [
                              if (videoDetailController.showReply)
                                videoReplyPanel(),
                              if (_shouldShowSeasonPanel) seasonPanel,
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        return _childWhenDisabledLandscapeInner(isFullScreen);
      });
    }
    return _childWhenDisabledLandscapeInner(isFullScreen);
  }

  Widget _childWhenDisabledLandscapeInner(bool isFullScreen) {
    double width =
        clampDouble(maxHeight / maxWidth * 1.08, 0.5, 0.7) * maxWidth;
    if (maxWidth >= 560) {
      width = maxWidth - clampDouble(maxWidth - width, 280, 425);
    }
    final videoWidth = isFullScreen ? maxWidth : width;
    final double height = width / Style.aspectRatio16x9;
    final videoHeight = isFullScreen
        ? maxHeight - (isWindowMode && !isPortrait ? 0 : padding.top)
        : height;
    if (height > maxHeight) {
      return childSplit(Style.aspectRatio16x9);
    }
    final introHeight = maxHeight - height - padding.top;
    final showIntro =
        videoDetailController.isUgc && videoDetailController.showRelatedVideo;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: videoWidth,
              height: videoHeight,
              child: videoPlayer(
                width: videoWidth,
                height: videoHeight,
              ),
            ),
            if (!videoDetailController.isFileSource)
              Offstage(
                offstage: isFullScreen,
                child: SizedBox(
                  width: width,
                  height: introHeight,
                  child: videoIntro(
                    width: width,
                    height: introHeight,
                    needRelated: false,
                    needCtr: false,
                  ),
                ),
              ),
          ],
        ),
        Offstage(
          offstage: isFullScreen,
          child: SizedBox(
            width: maxWidth - width - padding.horizontal,
            height: maxHeight - padding.top,
            child: MiniScaffold(
              key: videoDetailController.childKey,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  buildTabBar(
                    introText: '相关视频',
                    showIntro: videoDetailController.isFileSource
                        ? true
                        : showIntro,
                  ),
                  Expanded(
                    child: tabBarView(
                      controller: videoDetailController.tabCtr,
                      children: [
                        if (videoDetailController.isFileSource)
                          localIntroPanel()
                        else if (showIntro)
                          KeepAliveWrapper(
                            child: CustomScrollView(
                              key: const PageStorageKey(CommonIntroController),
                              controller:
                                  videoDetailController.effectiveIntroScrollCtr,
                              slivers: [
                                RelatedVideoPanel(
                                  key: videoRelatedKey,
                                  heroTag: heroTag,
                                ),
                              ],
                            ),
                          ),
                        if (videoDetailController.showReply) videoReplyPanel(),
                        if (_shouldShowSeasonPanel) seasonPanel,
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget get childWhenDisabledAlmostSquare => Obx(() {
    final isFullScreen = this.isFullScreen;
    return SimpleScaffold(
      appBar: removeAppBar(isFullScreen)
          ? null
          : SimpleAppBar(
              height: padding.top,
              brightness: colorScheme.brightness,
            ),
      body: Padding(
        padding: isFullScreen
            ? EdgeInsets.zero
            : padding.copyWith(top: 0, bottom: 0),
        child: childWhenDisabledAlmostSquareInner(isFullScreen),
      ),
    );
  });

  Widget childWhenDisabledAlmostSquareInner(bool isFullScreen) {
    if (enableVerticalExpand) {
      return Obx(
        () {
          if (videoDetailController.isVertical.value && !isPortrait) {
            return childSplit(9 / 16);
          }

          return _childWhenDisabledAlmostSquareInner(isFullScreen);
        },
      );
    }

    return _childWhenDisabledAlmostSquareInner(isFullScreen);
  }

  Widget _childWhenDisabledAlmostSquareInner(bool isFullScreen) {
    final shouldShowSeasonPanel = _shouldShowSeasonPanel;
    final double height = maxHeight / 2.5;
    final videoHeight = isFullScreen
        ? maxHeight - (isWindowMode && !isPortrait ? 0 : padding.top)
        : height;
    final bottomHeight = maxHeight - height - padding.top;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: maxWidth,
          height: videoHeight,
          child: videoPlayer(
            width: maxWidth,
            height: videoHeight,
          ),
        ),
        Offstage(
          offstage: isFullScreen,
          child: SizedBox(
            width: maxWidth - padding.horizontal,
            height: bottomHeight,
            child: MiniScaffold(
              key: videoDetailController.childKey,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  buildTabBar(needIndicator: false),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: videoIntro(
                            width: () {
                              double flex = 1;
                              if (videoDetailController.showReply) flex++;
                              if (shouldShowSeasonPanel) flex++;
                              return maxWidth / flex;
                            }(),
                            height: bottomHeight,
                          ),
                        ),
                        if (videoDetailController.showReply)
                          Expanded(child: videoReplyPanel()),
                        if (shouldShowSeasonPanel) Expanded(child: seasonPanel),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget manualPlayerWidget(double height) => Obx(() {
    if (!videoDetailController.autoPlay) {
      return Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: kToolbarHeight,
            child: Row(
              children: [
                SizedBox(
                  width: 42,
                  height: 34,
                  child: IconButton(
                    tooltip: '返回',
                    icon: const Icon(
                      FontAwesomeIcons.arrowLeft,
                      size: 15,
                      color: Colors.white,
                      shadows: [
                        Shadow(
                          blurRadius: 1.5,
                          color: Colors.black,
                        ),
                      ],
                    ),
                    onPressed: Get.back,
                  ),
                ),
                SizedBox(
                  width: 42,
                  height: 34,
                  child: IconButton(
                    tooltip: '返回主页',
                    icon: const Icon(
                      FontAwesomeIcons.house,
                      size: 15,
                      color: Colors.white,
                      shadows: [
                        Shadow(
                          blurRadius: 1.5,
                          color: Colors.black,
                        ),
                      ],
                    ),
                    onPressed:
                        videoDetailController.plPlayerController.onCloseAll,
                  ),
                ),
                const Spacer(),
                _moreBtn(
                  Colors.white,
                  shadows: const [
                    Shadow(
                      blurRadius: 1.5,
                      color: Colors.black,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            right: 12,
            top: height - 70,
            child: const PlayIcon(),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  });

  Widget _moreBtn(Color color, {List<Shadow>? shadows}) => PopupMenuButton(
    icon: Icon(
      size: 22,
      Icons.more_vert,
      color: color,
      shadows: shadows,
    ),
    itemBuilder: (BuildContext context) => <PopupMenuEntry>[
      PopupMenuItem(
        onTap: introController.viewLater,
        child: const Text('稍后再看'),
      ),
      if (videoDetailController.epId == null)
        PopupMenuItem(
          onTap: () => videoDetailController.showNoteList(context),
          child: const Text('查看笔记'),
        ),
      if (!videoDetailController.isFileSource)
        PopupMenuItem(
          onTap: () => videoDetailController.onDownload(this.context),
          child: const Text('缓存视频'),
        ),
      if (videoDetailController.cover.value.isNotEmpty)
        PopupMenuItem(
          onTap: () =>
              ImageUtils.downloadImg([videoDetailController.cover.value]),
          child: const Text('保存封面'),
        ),
      if (!videoDetailController.isFileSource && videoDetailController.isUgc)
        PopupMenuItem(
          onTap: videoDetailController.toAudioPage,
          child: const Text('听音频'),
        ),
      PopupMenuItem(
        onTap: () {
          if (!Accounts.main.isLogin) {
            SmartDialog.showToast('账号未登录');
          } else {
            PageUtils.reportVideo(videoDetailController.aid);
          }
        },
        child: const Text('举报'),
      ),
    ],
  );

  Widget plPlayer({
    required double width,
    required double height,
    bool isPipMode = false,
  }) => popScope(
    key: videoDetailController.videoPlayerKey,
    canPop:
        !isFullScreen &&
        !videoDetailController.plPlayerController.isDesktopPip &&
        (videoDetailController.horizontalScreen || isPortrait),
    onPopInvokedWithResult:
        videoDetailController.plPlayerController.onPopInvokedWithResult,
    child: Obx(
      () {
        final canAttach =
            videoDetailController.videoState.value &&
            plPlayerController?.videoController != null;
        final player = canAttach
            ? PLVideoPlayer(
                maxWidth: width,
                maxHeight: height,
                plPlayerController: plPlayerController!,
                videoDetailController: videoDetailController,
                introController: introController,
                headerControl: HeaderControl(
                  key: videoDetailController.headerCtrKey,
                  isPortrait: isPortrait,
                  controller: videoDetailController.plPlayerController,
                  videoDetailCtr: videoDetailController,
                  heroTag: heroTag,
                ),
                danmuWidget: isPipMode && pipNoDanmaku
                    ? null
                    : Obx(
                        () => PlDanmaku(
                          key: ValueKey(videoDetailController.cid.value),
                          isPipMode: isPipMode,
                          cid: videoDetailController.cid.value,
                          playerController: plPlayerController!,
                          isFullScreen: plPlayerController!.isFullScreen.value,
                          isFileSource: videoDetailController.isFileSource,
                          size: Size(width, height),
                        ),
                      ),
                showEpisodes: showEpisodes,
                showViewPoints: showViewPoints,
              )
            : null;
        return VideoPresentation(
          traceData: PlaybackDiagnostics.enabled
              ? videoDetailController.playbackTraceState
              : null,
          width: width,
          height: height,
          player: player,
          showPoster:
              !videoDetailController.autoPlay ||
              !videoDetailController.frameReady.value,
          loading: videoDetailController.preparingPlayback.value,
          onPlay: handlePlay,
          poster: NetworkImgLayer(
            type: .emote,
            quality: 60,
            src: videoDetailController.cover.value,
            fit: BoxFit.contain,
            width: width,
            height: height,
            cacheWidth: true,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
          ),
        );
      },
    ),
  );

  late ThemeData theme;
  ColorScheme get colorScheme => theme.colorScheme;
  late bool isPortrait;
  late double maxWidth;
  late double maxHeight;
  bool isWindowMode = false;
  late EdgeInsets padding;
  int _layoutMode = 0;

  @override
  Widget build(BuildContext context) {
    Widget child;
    // Keep the existing player subtree mounted while Android resizes the
    // Activity into PiP. Moving PLVideoPlayer to a separate PiP-only branch
    // detaches media_kit's Surface and leaves SystemUI showing the app-icon
    // placeholder until the replacement Surface produces its first frame.
    if (!AndroidPipController.instance.protectsPlayback) {
      _layoutMode = !videoDetailController.horizontalScreen
          ? 0
          : maxWidth / maxHeight >= kScreenRatio
          ? 1
          : maxWidth / Style.aspectRatio16x9 < 0.4 * maxHeight
          ? 0
          : 2;
    }
    child = switch (_layoutMode) {
      1 => childWhenDisabledLandscape,
      2 => childWhenDisabledAlmostSquare,
      _ => childWhenDisabled,
    };
    if (videoDetailController.plPlayerController.keyboardControl) {
      child = PlayerFocus(
        plPlayerController: videoDetailController.plPlayerController,
        introController: introController,
        onSendDanmaku: videoDetailController.showShootDanmakuSheet,
        isReady: () =>
            _ownsReadyPlayback &&
            !videoDetailController.preparingPlayback.value,
        canPlay: () {
          if (_ownsReadyPlayback &&
              !videoDetailController.preparingPlayback.value &&
              videoDetailController.autoPlay) {
            return true;
          }
          handlePlay();
          return false;
        },
        onSkipSegment: videoDetailController.onSkipSegment,
        child: child,
      );
    }
    return videoDetailController.plPlayerController.darkVideoPage
        ? Theme(data: theme, child: child)
        : child;
  }

  Widget buildTabBar({
    bool needIndicator = true,
    String? introText,
    bool showIntro = true,
    VoidCallback? onTap,
  }) {
    final tabs = [
      if (showIntro)
        videoDetailController.isFileSource ? '离线视频' : introText ?? '简介',
      if (videoDetailController.showReply) '评论',
      if (_shouldShowSeasonPanel) '播放列表',
    ];
    if (videoDetailController.tabCtr.length != tabs.length) {
      videoDetailController.tabCtr.dispose();
      videoDetailController.tabCtr = TabController(
        vsync: videoDetailController,
        length: tabs.length,
        initialIndex: tabs.isEmpty
            ? 0
            : videoDetailController.tabCtr.index.clamp(0, tabs.length - 1),
      );
    }

    Widget tabBar() {
      final flag = !needIndicator || tabs.length == 1;
      return TabBar(
        padding: .zero,
        dividerHeight: 0,
        labelPadding: .zero,
        dividerColor: Colors.transparent,
        controller: videoDetailController.tabCtr,
        indicator: flag ? const BoxDecoration() : null,
        labelColor: flag ? colorScheme.onSurface : null,
        labelStyle:
            TabBarTheme.of(context).labelStyle?.copyWith(fontSize: 13) ??
            const TextStyle(fontSize: 13),
        onTap: (value) {
          void animToTop() {
            if (onTap != null) {
              onTap();
              return;
            }
            String text = tabs[value];
            if (videoDetailController.isFileSource ||
                text == '简介' ||
                text == '相关视频') {
              videoDetailController.introScrollCtr?.animToTop();
            } else if (text.startsWith('评论')) {
              _videoReplyController.animateToTop();
            }
          }

          if (flag) {
            animToTop();
          } else if (!videoDetailController.tabCtr.indexIsChanging) {
            animToTop();
          }
        },
        tabs: tabs.map((text) {
          if (text == '评论') {
            return Obx(() {
              final count = _videoReplyController.count.value;
              return Tab(
                child: Text(
                  '评论${count == -1 ? '' : ' ${NumUtils.numFormat(count)}'}',
                  softWrap: false,
                  overflow: .visible,
                ),
              );
            });
          } else {
            return Tab(
              child: Text(text, softWrap: false, overflow: .visible),
            );
          }
        }).toList(),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.1),
          ),
        ),
      ),
      child: SizedBox(
        height: 45,
        child: Row(
          children: [
            if (tabs.isEmpty)
              const Spacer()
            else
              Expanded(
                child: Align(
                  alignment: .centerLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 96.0 * tabs.length),
                    child: tabBar(),
                  ),
                ),
              ),
            SizedBox(
              height: 32,
              child: TextButton(
                style: const ButtonStyle(
                  padding: WidgetStatePropertyAll(.zero),
                ),
                onPressed: videoDetailController.showShootDanmakuSheet,
                child: Text(
                  '发弹幕',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            SizedBox.square(
              dimension: 38,
              child: Obx(
                () {
                  final ctr = videoDetailController.plPlayerController;
                  final enableShowDanmaku = ctr.enableShowDanmaku.value;
                  return IconButton(
                    onPressed: () {
                      final newVal = !enableShowDanmaku;
                      ctr.enableShowDanmaku.value = newVal;
                      if (!ctr.tempPlayerConf) {
                        GStorage.setting.put(
                          SettingBoxKey.enableShowDanmaku,
                          newVal,
                        );
                      }
                    },
                    icon: Icon(
                      size: 22,
                      enableShowDanmaku
                          ? CustomIcons.dm_on
                          : CustomIcons.dm_off,
                      color: enableShowDanmaku
                          ? colorScheme.secondary
                          : colorScheme.outline,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 14),
          ],
        ),
      ),
    );
  }

  Widget videoPlayer({required double width, required double height}) {
    final isFullScreen = this.isFullScreen;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Positioned.fill(
          child: ColoredBox(
            color: Colors.black,
            isAntiAlias: false,
          ),
        ),

        plPlayer(width: width, height: height),

        manualPlayerWidget(height),

        if (videoDetailController.plPlayerController.enableBlock ||
            videoDetailController.continuePlayingPart)
          Positioned(
            left: 16,
            bottom: isFullScreen ? max(75, maxHeight * 0.25) : 75,
            width: MediaQuery.textScalerOf(context).scale(120),
            child: AnimatedList(
              padding: EdgeInsets.zero,
              key: videoDetailController.listKey,
              reverse: true,
              shrinkWrap: true,
              initialItemCount: videoDetailController.listData.length,
              itemBuilder: (context, index, animation) {
                return videoDetailController.buildItem(
                  videoDetailController.listData[index],
                  animation,
                );
              },
            ),
          ),

        // for debug
        // Positioned(
        //   right: 16,
        //   bottom: 75,
        //   child: FilledButton.tonal(
        //     onPressed: () {
        //       videoDetailController.onAddItem(
        //         SegmentModel(
        //           UUID: '',
        //           segmentType:
        //               SegmentType.values[Utils.random.nextInt(
        //                 SegmentType.values.length,
        //               )],
        //           segment: Pair(first: 0, second: 0),
        //           skipType: SkipType.alwaysSkip,
        //         ),
        //       );
        //     },
        //     child: const Text('skip'),
        //   ),
        // ),
        // Positioned(
        //   right: 16,
        //   bottom: 120,
        //   child: FilledButton.tonal(
        //     onPressed: () {
        //       videoDetailController.onAddItem(2);
        //     },
        //     child: const Text('index'),
        //   ),
        // ),
        Obx(
          () {
            if (videoDetailController.showSteinEdgeInfo.value) {
              try {
                return Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      bottom: plPlayerController?.showControls.value == true
                          ? 75
                          : 16,
                    ),
                    child: Wrap(
                      spacing: 25,
                      runSpacing: 10,
                      children: videoDetailController
                          .steinEdgeInfo!
                          .edges!
                          .questions!
                          .first
                          .choices!
                          .map((item) {
                            return FilledButton.tonal(
                              style: FilledButton.styleFrom(
                                shape: const RoundedRectangleBorder(
                                  borderRadius: .all(.circular(6)),
                                ),
                                backgroundColor: theme
                                    .colorScheme
                                    .secondaryContainer
                                    .withValues(alpha: 0.8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 15,
                                  vertical: 10,
                                ),
                                visualDensity: VisualDensity.compact,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () {
                                ugcIntroController.onChangeEpisode(
                                  item,
                                  isStein: true,
                                );
                                videoDetailController.getSteinEdgeInfo(item.id);
                              },
                              child: Text(item.option!),
                            );
                          })
                          .toList(),
                    ),
                  ),
                );
              } catch (e) {
                if (kDebugMode) debugPrint('build stein edges: $e');
                return const SizedBox.shrink();
              }
            }
            return const SizedBox.shrink();
          },
        ),
      ],
    );
  }

  Widget localIntroPanel({
    bool needCtr = true,
  }) {
    return CustomScrollView(
      controller: needCtr
          ? videoDetailController.effectiveIntroScrollCtr
          : null,
      physics: !needCtr ? platformAlwaysClampingPhysics : null,
      key: const PageStorageKey(CommonIntroController),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.only(top: 7, bottom: padding.bottom + 100),
          sliver: LocalIntroPanel(
            key: videoRelatedKey,
            heroTag: heroTag,
          ),
        ),
      ],
    );
  }

  Widget videoIntro({
    double? width,
    double? height,
    bool? isHorizontal,
    bool needRelated = true,
    bool needCtr = true,
  }) {
    if (videoDetailController.isFileSource) {
      return localIntroPanel(needCtr: needCtr);
    }

    Widget child = CustomScrollView(
      key: const PageStorageKey(CommonIntroController),
      controller: needCtr
          ? videoDetailController.effectiveIntroScrollCtr
          : null,
      physics: !needCtr ? platformAlwaysClampingPhysics : null,
      slivers: [
        if (videoDetailController.isUgc) ...[
          UgcIntroPanel(
            key: videoIntroKey,
            heroTag: heroTag,
            showAiBottomSheet: showAiBottomSheet,
            showEpisodes: showEpisodes,
            onShowMemberPage: onShowMemberPage,
            isPortrait: isPortrait,
            isHorizontal: isHorizontal ?? width! / height! >= kScreenRatio,
          ),
          if (needRelated && videoDetailController.showRelatedVideo) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(
                  top: Style.safeSpace,
                ),
                child: Divider(
                  height: 1,
                  indent: 12,
                  endIndent: 12,
                  color: colorScheme.outline.withValues(alpha: .08),
                ),
              ),
            ),
            RelatedVideoPanel(key: videoRelatedKey, heroTag: heroTag),
          ],
        ] else
          PgcIntroPage(
            key: videoIntroKey,
            heroTag: heroTag,
            showEpisodes: showEpisodes,
            showIntroDetail: showIntroDetail,
            maxWidth: width ?? maxWidth,
            isPortrait: isPortrait,
          ),
        SliverToBoxAdapter(
          child: SizedBox(
            height:
                (videoDetailController.isPlayAll && !isPortrait
                    ? 80
                    : Style.safeSpace) +
                padding.bottom,
          ),
        ),
      ],
    );

    if (videoDetailController.isPlayAll) {
      child = IntroLayout(
        body: child,
        playlist: Padding(
          padding: .only(left: 12, right: 12, bottom: 12 + padding.bottom),
          child: Material(
            type: .transparency,
            child: InkWell(
              onTap: () => videoDetailController.showMediaListPanel(context),
              borderRadius: const .all(.circular(14)),
              child: Container(
                height: 54,
                padding: const .symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer.withValues(alpha: 0.95),
                  borderRadius: const .all(.circular(14)),
                ),
                child: Row(
                  spacing: 10,
                  children: [
                    const Icon(Icons.playlist_play, size: 24),
                    Expanded(
                      child: Text(
                        videoDetailController.watchLaterTitle,
                        style: TextStyle(
                          color: colorScheme.onSecondaryContainer,
                          fontWeight: .bold,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                    const Icon(Icons.keyboard_arrow_up_rounded, size: 26),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return KeepAliveWrapper(child: child);
  }

  Widget get seasonPanel {
    if (videoDetailController.isUgc) return ugcSeasonPanel;
    if (videoDetailController.videoType == .pgc) return pgcSeasonPanel;
    throw UnimplementedError();
  }

  Widget get pgcSeasonPanel {
    Widget child = Obx(
      () => EpisodePanel(
        heroTag: heroTag,
        enableSlide: false,
        ugcIntroController: null,
        type: .pgc,
        cover: null,
        list: [pgcIntroController.pgcItem.episodes!],
        bvid: videoDetailController.bvid,
        aid: videoDetailController.aid,
        cid: videoDetailController.cid.value,
        onChangeEpisode: pgcIntroController.onChangeEpisode,
        showTitle: false,
        isSupportReverse: false,
      ),
    );
    if (pgcIntroController.pgcItem.hasSeasons) {
      child = Column(
        children: [
          Padding(
            padding: const .only(left: 12, top: 8, right: 12),
            child: Builder(
              builder: (context) {
                return pgc.SeasonPanel(
                  seasons: pgcIntroController.pgcItem.seasons!,
                  pgcController: pgcIntroController,
                  onSeasonChanged: () {
                    if (context.mounted) (context as Element).markNeedsBuild();
                  },
                );
              },
            ),
          ),
          Expanded(child: child),
        ],
      );
    }
    return KeepAliveWrapper(child: child);
  }

  Widget get ugcSeasonPanel {
    final videoDetail = ugcIntroController.videoDetail.rawValue;
    return KeepAliveWrapper(
      child: Column(
        children: [
          if (videoDetail.hasParts)
            if (videoDetail.ugcSeason != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: PagesPanel(
                  heroTag: heroTag,
                  ugcIntroController: ugcIntroController,
                  bvid: ugcIntroController.bvid,
                  showEpisodes: showEpisodes,
                ),
              )
            else
              Expanded(
                child: Obx(
                  () => EpisodePanel(
                    heroTag: heroTag,
                    enableSlide: false,
                    ugcIntroController: ugcIntroController,
                    type: .part,
                    list: [videoDetail.pages!],
                    cover: videoDetailController.cover.value,
                    bvid: videoDetailController.bvid,
                    aid: videoDetailController.aid,
                    cid: videoDetailController.cid.value,
                    isReversed: videoDetail.isPageReversed,
                    onChangeEpisode: ugcIntroController.onChangeEpisode,
                    showTitle: false,
                    isSupportReverse: true,
                    onReverse: () => onReversePlay(isSeason: false),
                  ),
                ),
              ),
          if (videoDetail.ugcSeason != null) ...[
            if (videoDetail.hasParts) ...[
              const SizedBox(height: 8),
              Divider(
                height: 1,
                color: colorScheme.outline.withValues(alpha: 0.1),
              ),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Obx(
                () => ugc.SeasonPanel(
                  key: ValueKey(introController.videoDetail.value),
                  heroTag: heroTag,
                  canTap: false,
                  showEpisodes: showEpisodes,
                  ugcIntroController: ugcIntroController,
                ),
              ),
            ),
            Expanded(
              child: Obx(
                () => EpisodePanel(
                  heroTag: heroTag,
                  enableSlide: false,
                  ugcIntroController: ugcIntroController,
                  type: .season,
                  initialTabIndex: videoDetailController.seasonIndex.value,
                  cover: videoDetailController.cover.value,
                  seasonId: videoDetail.ugcSeason!.id,
                  list: videoDetail.ugcSeason!.sections!,
                  bvid: videoDetailController.bvid,
                  aid: videoDetailController.aid,
                  cid: videoDetailController.seasonCid ?? 0,
                  isReversed: ugcIntroController
                      .videoDetail
                      .value
                      .ugcSeason!
                      .sections![videoDetailController.seasonIndex.value]
                      .isReversed,
                  onChangeEpisode: ugcIntroController.onChangeEpisode,
                  showTitle: false,
                  isSupportReverse: true,
                  onReverse: () => onReversePlay(isSeason: true),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget videoReplyPanel({bool isNested = false}) => VideoReplyPanel(
    key: videoReplyPanelKey,
    isNested: isNested,
    heroTag: heroTag,
  );

  // ai总结
  void showAiBottomSheet() {
    videoDetailController.childKey.currentState?.showBottomSheet(
      constraints: const BoxConstraints(),
      (context) =>
          AiConclusionPanel(item: ugcIntroController.aiConclusionResult!),
    );
  }

  void showIntroDetail(
    PgcInfoModel videoDetail,
    List<VideoTagItem>? videoTags,
  ) {
    videoDetailController.childKey.currentState?.showBottomSheet(
      constraints: const BoxConstraints(),
      (context) => PgcIntroPanel(
        item: videoDetail,
        videoTags: videoTags,
      ),
    );
  }

  void showEpisodes([
    int? index,
    UgcSeason? season,
    List<ugc.BaseEpisodeItem>? episodes,
    String? bvid,
    int? aid,
    int? cid,
  ]) {
    assert((cid == null) == (bvid == null));
    final isFullScreen = this.isFullScreen;
    if (cid == null) {
      videoDetailController.showMediaListPanel(context);
      return;
    }
    Widget listSheetContent({bool enableSlide = true}) => EpisodePanel(
      heroTag: heroTag,
      ugcIntroController: videoDetailController.isUgc
          ? ugcIntroController
          : null,
      type: season != null
          ? EpisodeType.season
          : episodes is List<Part>
          ? EpisodeType.part
          : EpisodeType.pgc,
      cover: videoDetailController.cover.value,
      enableSlide: enableSlide,
      initialTabIndex: index ?? 0,
      bvid: bvid!,
      aid: aid,
      cid: cid,
      seasonId: season?.id,
      list: season != null ? season.sections! : [episodes],
      isReversed: !videoDetailController.isUgc
          ? null
          : season != null
          ? ugcIntroController
                .videoDetail
                .value
                .ugcSeason!
                .sections![videoDetailController.seasonIndex.value]
                .isReversed
          : ugcIntroController.videoDetail.value.isPageReversed,
      isSupportReverse: videoDetailController.isUgc,
      onChangeEpisode: videoDetailController.isUgc
          ? ugcIntroController.onChangeEpisode
          : pgcIntroController.onChangeEpisode,
      onClose: Get.back,
      onReverse: () {
        Get.back();
        onReversePlay(isSeason: season != null);
      },
    );
    if (isFullScreen || videoDetailController.showVideoSheet) {
      final child = listSheetContent(enableSlide: false);
      PageUtils.showVideoBottomSheet(
        context,
        child: videoDetailController.plPlayerController.darkVideoPage
            ? Theme(data: theme, child: child)
            : child,
      );
    } else {
      videoDetailController.childKey.currentState?.showBottomSheet(
        constraints: const BoxConstraints(),
        (context) => listSheetContent(),
      );
    }
  }

  void onReversePlay({required bool isSeason}) {
    if (isSeason && videoDetailController.isPlayAll) {
      SmartDialog.showToast('当前为播放全部，合集不支持倒序');
      return;
    }

    final videoDetail = ugcIntroController.videoDetail.value;
    if (isSeason) {
      // reverse season
      final item = videoDetail
          .ugcSeason!
          .sections![videoDetailController.seasonIndex.value];
      item
        ..isReversed = !item.isReversed
        ..episodes = item.episodes!.reversed.toList();

      if (!videoDetailController.plPlayerController.reverseFromFirst) {
        // keep current episode
        videoDetailController
          ..seasonIndex.refresh()
          ..cid.refresh();
      } else {
        // switch to first episode
        final episode = ugcIntroController
            .videoDetail
            .value
            .ugcSeason!
            .sections![videoDetailController.seasonIndex.value]
            .episodes!
            .first;
        if (episode.cid != videoDetailController.cid.value) {
          ugcIntroController.onChangeEpisode(episode);
          videoDetailController.seasonCid = episode.cid;
        } else {
          videoDetailController
            ..seasonIndex.refresh()
            ..cid.refresh();
        }
      }
    } else {
      // reverse part
      videoDetail
        ..isPageReversed = !videoDetail.isPageReversed
        ..pages = videoDetail.pages!.reversed.toList();
      if (!videoDetailController.plPlayerController.reverseFromFirst) {
        // keep current episode
        videoDetailController.cid.refresh();
      } else {
        // switch to first episode
        final episode = videoDetail.pages!.first;
        if (episode.cid != videoDetailController.cid.value) {
          ugcIntroController.onChangeEpisode(episode);
        } else {
          videoDetailController.cid.refresh();
        }
      }
    }
  }

  void showViewPoints() {
    if (isFullScreen || videoDetailController.showVideoSheet) {
      final child = ViewPointsPage(
        enableSlide: false,
        videoDetailController: videoDetailController,
        plPlayerController: plPlayerController,
      );
      PageUtils.showVideoBottomSheet(
        context,
        child: videoDetailController.plPlayerController.darkVideoPage
            ? Theme(data: theme, child: child)
            : child,
      );
    } else {
      videoDetailController.childKey.currentState?.showBottomSheet(
        constraints: const BoxConstraints(),
        (context) => ViewPointsPage(
          videoDetailController: videoDetailController,
          plPlayerController: plPlayerController,
        ),
      );
    }
  }

  void onShowMemberPage(int? mid) {
    videoDetailController.childKey.currentState?.showBottomSheet(
      constraints: const BoxConstraints(),
      dragHeight: 100,
      (context) {
        return HorizontalMemberPage(
          mid: mid,
          videoDetailController: videoDetailController,
          ugcIntroController: ugcIntroController,
        );
      },
    );
  }
}
