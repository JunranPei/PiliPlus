import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:PiliPlus/plugin/pl_player/android_pip_controller.dart';
import 'package:PiliPlus/plugin/pl_player/pip_diagnostics.dart';

/// Marks the layout that is already inside Android's final PiP window.
/// Pages use this scope to keep only the existing video surface mounted.
class PipWindowScope extends InheritedWidget {
  const PipWindowScope({
    super.key,
    required this.isPipWindow,
    required super.child,
  });

  final bool isPipWindow;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PipWindowScope>()
          ?.isPipWindow ??
      false;

  @override
  bool updateShouldNotify(PipWindowScope oldWidget) =>
      oldWidget.isPipWindow != isPipWindow;
}

/// Keeps the same page and media_kit Texture mounted while Android changes
/// the Activity bounds. Flutter does not perform a second crop or transform;
/// once the real PiP-sized constraints arrive, the page switches to its
/// video-only layout through [PipWindowScope].
class AndroidPipViewport extends StatelessWidget {
  const AndroidPipViewport({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return child;
    final pip = AndroidPipController.instance;
    return ListenableBuilder(
      listenable: pip,
      builder: (context, child) => PipViewport(
        phase: pip.phase,
        sourceRect: pip.sourceRect,
        nativeRootLocked: pip.renderHostLocked,
        child: child!,
      ),
      child: child,
    );
  }
}

/// [sourceRect] remains part of the API because native Android uses it for
/// sourceRectHint. It is intentionally not converted into a Flutter matrix.
class PipViewport extends StatefulWidget {
  const PipViewport({
    super.key,
    required this.phase,
    required this.sourceRect,
    required this.child,
    this.nativeRootLocked = false,
  });

  final AndroidPipPhase phase;
  final Rect? sourceRect;
  final Widget child;
  final bool nativeRootLocked;

  @override
  State<PipViewport> createState() => _PipViewportState();
}

class _PipViewportState extends State<PipViewport> {
  Size? _normalWindow;
  bool _holdPipLayout = false;
  MediaQueryData? _normalMedia;

  // Compare orientation-independent dimensions: Android can restore portrait
  // bounds after PiP was entered from landscape fullscreen.
  bool _hasReducedBounds(Size window, Size normal) =>
      window.shortestSide < normal.shortestSide * 0.9 &&
      window.longestSide < normal.longestSide * 0.9;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final window = constraints.biggest;
        if (widget.nativeRootLocked && _normalMedia != null) {
          PipDiagnostics.event('viewport.nativeRootLocked', {
            'window': window.toString(),
            'media': _normalMedia!.size.toString(),
            'phase': widget.phase.name,
          });
          return ColoredBox(
            color: const Color(0xFF000000),
            child: MediaQuery(
              data: _normalMedia!,
              child: PipWindowScope(
                isPipWindow: false,
                child: IgnorePointer(ignoring: true, child: widget.child),
              ),
            ),
          );
        }
        if (widget.phase == AndroidPipPhase.idle) _normalMedia = media;
        final normal = _normalWindow;
        final hasPipBounds =
            normal != null && _hasReducedBounds(window, normal);
        final hasNormalBounds =
            normal == null ||
            (window.shortestSide >= normal.shortestSide * 0.9 &&
                window.longestSide >= normal.longestSide * 0.9);
        if (widget.phase == AndroidPipPhase.idle && !_holdPipLayout) {
          // A pre-ACTIVE resize is part of Android's transition. Preserve the
          // full-window reference instead of mistaking that small frame for
          // the new normal size.
          if (!hasPipBounds) _normalWindow = window;
        } else if (widget.phase == AndroidPipPhase.idle && hasNormalBounds) {
          _holdPipLayout = false;
          _normalWindow = window;
        }

        // Arm exit protection only after a small-window layout was actually
        // shown. A cancelled entry must not leave the normal page locked.
        if (widget.phase != AndroidPipPhase.idle && hasPipBounds) {
          _holdPipLayout = true;
        }

        // The native ACTIVE callback can precede the actual Activity resize.
        // Do not switch the page to its PiP-only layout while the constraints
        // are still full-screen; that intermediate rebuild can expose a black
        // frame before SystemUI has committed the small window.
        final isPipWindow =
            (widget.phase == AndroidPipPhase.active && hasPipBounds) ||
            (widget.phase == AndroidPipPhase.idle && _holdPipLayout);

        // The Activity can update its constraints before the root
        // MediaQuery notification arrives. Propagate the actual bounds to
        // the retained page so its existing player receives the PiP size,
        // instead of laying out a full-window child at the top-left.
        final windowMedia = media.copyWith(size: window);
        PipDiagnostics.event('viewport.layout', {
          'state': identityHashCode(this),
          'phase': widget.phase.name,
          'constraints': constraints.toString(),
          'window': window.toString(),
          'normal': _normalWindow?.toString(),
          'hold': _holdPipLayout,
          'reduced': hasPipBounds,
          'restored': hasNormalBounds,
          'scope': isPipWindow,
          'incomingMedia': media.size.toString(),
          'incomingPadding': media.padding.toString(),
          'incomingViewPadding': media.viewPadding.toString(),
          'incomingViewInsets': media.viewInsets.toString(),
        });
        return ColoredBox(
          color: const Color(0xFF000000),
          child: MediaQuery(
            data: windowMedia,
            child: PipWindowScope(
              isPipWindow: isPipWindow,
              child: IgnorePointer(
                ignoring:
                    widget.phase != AndroidPipPhase.idle || _holdPipLayout,
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }
}
