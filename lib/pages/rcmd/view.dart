import 'dart:async';

import 'package:PiliPlus/common/skeleton/video_card_v.dart';
import 'package:PiliPlus/common/sliver_single_child_delegate.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/video_card/video_card_v.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';
import 'package:PiliPlus/plugin/pl_player/playback/startup_text_warmup.dart';
import 'package:PiliPlus/plugin/pl_player/playback/startup_text_inventory.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:PiliPlus/pages/rcmd/controller.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class RcmdPage extends StatefulWidget {
  const RcmdPage({super.key});

  @override
  State<RcmdPage> createState() => _RcmdPageState();
}

class _RcmdPageState extends State<RcmdPage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  static const _observeVisibleCards =
      VideoHttp.visibleUrlPrefetch || PlaybackDiagnostics.enabled;
  final controller = Get.put(RcmdController());
  final _prefetchViewport = GlobalKey();
  final _prefetchCards =
      <String, ({GlobalKey key, BaseRcmdVideoItemModel item})>{};
  Timer? _prefetchTimer;
  int _prefetchRevision = 0;
  final _prefetchClock = Stopwatch()..start();
  Duration? _lastPrefetch;

  @override
  void initState() {
    super.initState();
    if (_observeVisibleCards) WidgetsBinding.instance.addObserver(this);
    if (StartupTextWarmup.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          StartupTextWarmup.prepare(
            context,
            stillCurrent: () =>
                mounted &&
                WidgetsBinding.instance.lifecycleState ==
                    AppLifecycleState.resumed &&
                ModalRoute.of(context)?.isCurrent == true &&
                TickerMode.valuesOf(context).enabled,
          ),
        );
      });
    }
  }

  void _cancelPrefetch({
    bool clearResponse = true,
    bool retainCompleted = false,
  }) {
    _prefetchRevision++;
    _prefetchTimer?.cancel();
    if (clearResponse) {
      VideoHttp.cancelVideoUrlPrefetch(retainCompleted: retainCompleted);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_observeVisibleCards) return;
    if (!TickerMode.valuesOf(context).enabled ||
        ModalRoute.of(context)?.isCurrent != true) {
      if (StartupTextInventory.enabled) {
        StartupTextInventory.capture(context, 'home.covered');
      }
      // A card tap pushes a route before its controller claims the URL. Stop
      // scheduling here while retaining that bounded in-flight handoff.
      _cancelPrefetch(clearResponse: false);
    } else {
      _schedulePrefetch();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _schedulePrefetch();
    } else {
      _cancelPrefetch();
    }
  }

  @override
  void dispose() {
    if (_observeVisibleCards) {
      _cancelPrefetch();
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }

  bool get _canPrefetch =>
      mounted &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      ModalRoute.of(context)?.isCurrent == true &&
      TickerMode.valuesOf(context).enabled &&
      controller.scrollController.hasClients &&
      !controller.scrollController.position.isScrollingNotifier.value;

  void _schedulePrefetch() {
    if (!_observeVisibleCards) return;
    _prefetchTimer?.cancel();
    final revision = ++_prefetchRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _prefetchRevision) return;
      _prefetchTimer = Timer(const Duration(milliseconds: 600), () async {
        if (!_canPrefetch || revision != _prefetchRevision) return;
        if (PlaybackDiagnostics.enabled && !PlaybackDiagnostics.active) {
          PlaybackDiagnostics.prepareSparseCapture();
        }
        if (_lastPrefetch case final last?
            when _prefetchClock.elapsed - last < const Duration(seconds: 3)) {
          return;
        }
        try {
          final connections = await Connectivity().checkConnectivity();
          if (!connections.contains(ConnectivityResult.wifi) ||
              !_canPrefetch ||
              revision != _prefetchRevision) {
            return;
          }
          final viewport = _prefetchViewport.currentContext?.findRenderObject();
          if (viewport is! RenderBox ||
              !viewport.hasSize ||
              !viewport.attached) {
            return;
          }
          final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
          BaseRcmdVideoItemModel? chosen;
          Rect? chosenBounds;
          var distance = double.infinity;
          _prefetchCards.removeWhere(
            (_, slot) => slot.key.currentContext == null,
          );
          for (final slot in _prefetchCards.values) {
            final box = slot.key.currentContext?.findRenderObject();
            if (box is! RenderBox || !box.hasSize || !box.attached) continue;
            final card = box.localToGlobal(Offset.zero) & box.size;
            final visible = card.intersect(bounds);
            if (card.isEmpty ||
                visible.isEmpty ||
                visible.width * visible.height / (card.width * card.height) <
                    .65) {
              continue;
            }
            final current = (card.center - bounds.center).distanceSquared;
            if (current < distance) {
              chosen = slot.item;
              chosenBounds = card;
              distance = current;
            }
          }
          if (chosen == null || chosen.bvid == null || chosen.cid == null) {
            return;
          }
          if (!mounted) return;
          final requested = VideoHttp.prefetchVideoUrl(
            bvid: chosen.bvid!,
            cid: chosen.cid!,
          );
          _lastPrefetch = _prefetchClock.elapsed;
          PlaybackDiagnostics.event('startup.visibleCard', {
            'bvid': chosen.bvid,
            'cid': chosen.cid,
            'title': chosen.title,
            'bounds': [
              chosenBounds!.left,
              chosenBounds.top,
              chosenBounds.right,
              chosenBounds.bottom,
            ],
            'wifi': true,
            'prefetchRequested': requested,
            'devicePixelRatio': MediaQuery.devicePixelRatioOf(context),
          });
        } catch (_) {
          // Speculation never changes card navigation or shows a network error.
          if (revision == _prefetchRevision) VideoHttp.cancelVideoUrlPrefetch();
        }
      });
    });
  }

  Widget _prefetchCard(Widget child, int index, BaseRcmdVideoItemModel item) {
    if (!_observeVisibleCards ||
        item.goto != 'av' ||
        item.bvid == null ||
        item.cid == null) {
      return child;
    }
    final id = '$index:${item.bvid}:${item.cid}';
    final key = _prefetchCards[id]?.key ?? GlobalKey();
    _prefetchCards[id] = (key: key, item: item);
    return KeyedSubtree(key: key, child: child);
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colorScheme = ColorScheme.of(context);
    _schedulePrefetch();
    final content = Container(
      key: _observeVisibleCards ? _prefetchViewport : null,
      clipBehavior: .hardEdge,
      margin: const .symmetric(horizontal: Style.safeSpace),
      decoration: const BoxDecoration(borderRadius: Style.mdRadius),
      child: refreshIndicator(
        onRefresh: controller.onRefresh,
        child: CustomScrollView(
          controller: controller.scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const .only(top: Style.cardSpace, bottom: 100),
              sliver: Obx(
                () => _buildBody(colorScheme, controller.loadingState.value),
              ),
            ),
          ],
        ),
      ),
    );
    if (!_observeVisibleCards) return content;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0) {
          if (notification is ScrollStartNotification) {
            _cancelPrefetch(retainCompleted: true);
          }
          if (notification is ScrollEndNotification) _schedulePrefetch();
        }
        return false;
      },
      child: content,
    );
  }

  late final gridDelegate = SliverGridDelegateWithExtentAndRatio(
    mainAxisSpacing: Style.cardSpace,
    crossAxisSpacing: Style.cardSpace,
    maxCrossAxisExtent: Pref.recommendCardWidth,
    childAspectRatio: Style.aspectRatio,
    mainAxisExtent: MediaQuery.textScalerOf(context).scale(90),
  );

  Widget _buildBody(
    ColorScheme colorScheme,
    LoadingState<List<dynamic>?> loadingState,
  ) {
    _schedulePrefetch();
    return switch (loadingState) {
      Loading() => _buildSkeleton,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) {
                  if (index == response.length - 1) {
                    controller.onLoadMore();
                  }
                  if (controller.lastRefreshAt != null) {
                    if (controller.lastRefreshAt == index) {
                      return GestureDetector(
                        onTap: () => controller
                          ..animateToTop()
                          ..onRefresh(),
                        child: Card(
                          child: Container(
                            alignment: Alignment.center,
                            padding: const .symmetric(horizontal: 10),
                            child: Text(
                              '上次看到这里\n点击刷新',
                              textAlign: .center,
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      );
                    }
                    final actualIndex = index > controller.lastRefreshAt!
                        ? index - 1
                        : index;
                    return _prefetchCard(
                      VideoCardV(
                        videoItem: response[actualIndex],
                        onRemove: () {
                          if (controller.lastRefreshAt != null &&
                              actualIndex < controller.lastRefreshAt!) {
                            controller.lastRefreshAt =
                                controller.lastRefreshAt! - 1;
                          }
                          controller.loadingState
                            ..value.data!.removeAt(actualIndex)
                            ..refresh();
                        },
                      ),
                      index,
                      response[actualIndex],
                    );
                  } else {
                    return _prefetchCard(
                      VideoCardV(
                        videoItem: response[index],
                        onRemove: () => controller.loadingState
                          ..value.data!.removeAt(index)
                          ..refresh(),
                      ),
                      index,
                      response[index],
                    );
                  }
                },
                itemCount: controller.lastRefreshAt != null
                    ? response.length + 1
                    : response.length,
              )
            : HttpError(onReload: controller.onReload),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: controller.onReload,
      ),
    };
  }

  Widget get _buildSkeleton => SliverGrid(
    gridDelegate: gridDelegate,
    delegate: const SliverSingleChildDelegate(
      count: 10,
      child: VideoCardVSkeleton(),
    ),
  );
}
