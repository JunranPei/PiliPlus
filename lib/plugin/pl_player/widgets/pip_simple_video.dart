import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:PiliPlus/plugin/pl_player/pip_diagnostics.dart';

/// A media_kit texture widget that keeps the last non-zero video rectangle
/// during an Android surface resize. media_kit 1.2.x briefly publishes
/// Rect.zero before the native SurfaceTexture has its new buffer size; using
/// that value would remove the Texture from the tree and expose a black frame.
class PipSimpleVideo extends StatefulWidget {
  const PipSimpleVideo({
    super.key,
    this.fill = Colors.black,
    required this.controller,
    this.aspectRatio,
    this.filterQuality = FilterQuality.low,
  });

  final Color fill;
  final VideoController controller;
  final double? aspectRatio;
  final FilterQuality filterQuality;

  @override
  State<PipSimpleVideo> createState() => _PipSimpleVideoState();
}

class _PipSimpleVideoState extends State<PipSimpleVideo> {
  late double _devicePixelRatio;
  late bool _visible = _hasVideoSize(widget.controller.player.state);
  Rect? _lastNonZeroRect;
  late final StreamSubscription<(int, int)> _subscription;

  static bool _hasVideoSize(dynamic state) =>
      state.width > 0 && state.height > 0;

  @override
  void initState() {
    super.initState();
    PipDiagnostics.event('texture.mount', {
      'state': identityHashCode(this),
      'controller': identityHashCode(widget.controller),
    });
    _subscription = widget.controller.player.stream.size.listen((value) {
      PipDiagnostics.event('texture.sizeEvent', {
        'state': identityHashCode(this),
        'size': value.toString(),
      });
      final visible = value.$1 > 0 && value.$2 > 0;
      // A zero size is part of media_kit 1.2.x Android surface replacement.
      // Keep the existing Texture mounted until a new non-zero size arrives.
      if (visible && !_visible) {
        _visible = true;
        // ignore: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member
        widget.controller.rect.notifyListeners();
      }
    });
  }

  @override
  void didUpdateWidget(PipSimpleVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    PipDiagnostics.event('texture.widgetUpdate', {
      'state': identityHashCode(this),
      'oldController': identityHashCode(oldWidget.controller),
      'controller': identityHashCode(widget.controller),
      'oldAspect': oldWidget.aspectRatio, 'aspect': widget.aspectRatio,
    });
  }

  @override
  void dispose() {
    PipDiagnostics.event('texture.dispose', {'state': identityHashCode(this)});
    _subscription.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  }

  @override
  Widget build(BuildContext context) {
    final ctr = widget.controller;
    return ListenableBuilder(
      listenable: Listenable.merge([ctr.id, ctr.rect]),
      builder: (context, _) {
        final id = ctr.id.value;
        final rawRect = ctr.rect.value;
        if (rawRect != null && rawRect.width > 0 && rawRect.height > 0) {
          _lastNonZeroRect = rawRect;
        }
        final rawRectIsZero =
            rawRect == null || rawRect.width <= 0 || rawRect.height <= 0;
        final rect = rawRectIsZero ? _lastNonZeroRect : rawRect;
        PipDiagnostics.event('texture.build', {
          'state': identityHashCode(this),
          'texture': id,
          'rawRect': rawRect?.toString(),
          'effectiveRect': rect?.toString(),
          'visible': _visible,
          'dpr': _devicePixelRatio,
          'aspectRatio': widget.aspectRatio,
        });
        if (id != null && rect != null && _visible) {
          return SizedBox(
            width: widget.aspectRatio == null
                ? rect.width / _devicePixelRatio
                : rect.height / _devicePixelRatio * widget.aspectRatio!,
            height: rect.height / _devicePixelRatio,
            child: Stack(
              children: [
                Texture(
                  textureId: id,
                  filterQuality: widget.filterQuality,
                ),
                if (rect.width <= 1.0 && rect.height <= 1.0)
                  Positioned.fill(child: ColoredBox(color: widget.fill)),
              ],
            ),
          );
        }
        return const SizedBox();
      },
    );
  }
}
