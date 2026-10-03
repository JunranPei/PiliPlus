import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

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
    _subscription = widget.controller.player.stream.size.listen((value) {
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
  void dispose() {
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
        if (Platform.isAndroid) {
          // Android uses one native SurfaceView for the whole playback
          // lifetime.  It remains in the Flutter layout while the Activity
          // enters PiP, so no Texture ID or second surface is swapped during
          // the system resize.
          final state = ctr.player.state;
          final nativeRect = rect ??
              ((state.width > 0 && state.height > 0)
                  ? Rect.fromLTWH(
                      0,
                      0,
                      state.width.toDouble(),
                      state.height.toDouble(),
                    )
                  : null);
          if (_visible && nativeRect != null) {
            return SizedBox(
              width: widget.aspectRatio == null
                  ? nativeRect.width / _devicePixelRatio
                  : nativeRect.height / _devicePixelRatio * widget.aspectRatio!,
              height: nativeRect.height / _devicePixelRatio,
              child: NativeVideoView(controller: ctr),
            );
          }
          return const SizedBox();
        }
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
