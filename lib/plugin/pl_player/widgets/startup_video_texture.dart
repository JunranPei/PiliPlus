import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Paints the existing texture behind the source's poster while dimensions arrive.
/// Decoded geometry takes over without replacing the Texture element or Surface.
class StartupVideoTexture extends StatefulWidget {
  const StartupVideoTexture({
    super.key,
    required this.controller,
    required this.warm,
    required this.fallbackSize,
    this.fill = Colors.black,
    this.aspectRatio,
    this.traceData,
  });

  final VideoController controller;
  final bool warm;
  final Size fallbackSize;
  final Color fill;
  final double? aspectRatio;
  final Map<String, Object?> Function()? traceData;

  @override
  State<StartupVideoTexture> createState() => _StartupVideoTextureState();
}

class _StartupVideoTextureState extends State<StartupVideoTexture> {
  late bool _nativeVisible;
  late StreamSubscription<(int, int)> _sizeSubscription;
  String? _lastDiagnostic;

  void _listen() {
    final state = widget.controller.player.state;
    _nativeVisible = state.width > 0 && state.height > 0;
    _sizeSubscription = widget.controller.player.stream.size.listen((size) {
      final visible = size.$1 > 0 && size.$2 > 0;
      if (mounted && visible != _nativeVisible) {
        setState(() => _nativeVisible = visible);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant StartupVideoTexture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(_sizeSubscription.cancel());
      _lastDiagnostic = null;
      _listen();
    }
  }

  @override
  void dispose() {
    unawaited(_sizeSubscription.cancel());
    super.dispose();
  }

  void _observe(Map<String, Object?> data) {
    if (!PlaybackDiagnostics.active) return;
    final signature = data.toString();
    if (_lastDiagnostic == signature) return;
    _lastDiagnostic = signature;
    PlaybackDiagnostics.event('startup.texture.layout', {
      ...?widget.traceData?.call(),
      ...data,
      'boundary': 'Widget texture layout; not frame consumption or display',
    });
  }

  @override
  Widget build(BuildContext context) => StartupTextureSurface(
    textureId: widget.controller.id,
    textureRect: widget.controller.rect,
    nativeVisible: _nativeVisible,
    warm: widget.warm,
    fallbackSize: widget.fallbackSize,
    fill: widget.fill,
    aspectRatio: widget.aspectRatio,
    observe: PlaybackDiagnostics.enabled ? _observe : null,
  );
}

/// Presentation only: never writes controller dimensions or touches a buffer.
class StartupTextureSurface extends StatelessWidget {
  const StartupTextureSurface({
    super.key,
    required this.textureId,
    required this.textureRect,
    required this.nativeVisible,
    required this.warm,
    required this.fallbackSize,
    this.fill = Colors.black,
    this.aspectRatio,
    this.observe,
  });

  final ValueNotifier<int?> textureId;
  final ValueNotifier<Rect?> textureRect;
  final bool nativeVisible;
  final bool warm;
  final Size fallbackSize;
  final Color fill;
  final double? aspectRatio;
  final void Function(Map<String, Object?>)? observe;

  static bool _valid(Size size) =>
      size.width.isFinite &&
      size.height.isFinite &&
      size.width > 1 &&
      size.height > 1;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.devicePixelRatioOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([textureId, textureRect]),
      builder: (context, _) {
        final id = textureId.value;
        final rect = textureRect.value;
        final decoded = nativeVisible && rect != null && _valid(rect.size);
        final fallback = warm && _valid(fallbackSize);
        final size = decoded ? rect.size : fallbackSize;
        final attached = id != null && (decoded || fallback);
        observe?.call({
          'textureId': id,
          'warm': warm,
          'nativeVisible': nativeVisible,
          'fallbackGeometry': attached && !decoded,
          'attached': attached,
          if (attached) 'layoutWidth': size.width,
          if (attached) 'layoutHeight': size.height,
        });
        if (!attached) return const SizedBox.shrink();
        return SizedBox(
          width:
              (aspectRatio == null ? size.width : size.height * aspectRatio!) /
              scale,
          height: size.height / scale,
          child: Texture(
            key: const ValueKey('startup-video-texture'),
            textureId: id,
            filterQuality: FilterQuality.low,
          ),
        );
      },
    );
  }
}
