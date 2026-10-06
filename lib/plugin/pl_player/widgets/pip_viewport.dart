import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:PiliPlus/plugin/pl_player/android_pip_controller.dart';
import 'package:PiliPlus/plugin/pl_player/pip_diagnostics.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/pip_frame_marker.dart';

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

/// Retains detail-panel state and its last normal constraints while PiP paints
/// only the video. Offstage alone would still lay out wide rows at PiP width.
class PipRetainedDetails extends StatefulWidget {
  const PipRetainedDetails({super.key, required this.child});
  final Widget child;

  @override
  State<PipRetainedDetails> createState() => _PipRetainedDetailsState();
}

class _PipRetainedDetailsState extends State<PipRetainedDetails> {
  Size? _normalSize;
  MediaQueryData? _normalMedia;

  @override
  Widget build(BuildContext context) {
    final pip = PipWindowScope.of(context);
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!pip && !constraints.biggest.isEmpty) {
          _normalSize = Size(
            constraints.hasBoundedWidth
                ? constraints.maxWidth
                : media.size.width,
            constraints.hasBoundedHeight
                ? constraints.maxHeight
                : media.size.height,
          );
          _normalMedia = media;
        }
        final normal = _normalSize ?? media.size;
        return Offstage(
          offstage: pip,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: pip ? normal.width : null,
            maxWidth: pip ? normal.width : null,
            minHeight: pip ? normal.height : null,
            maxHeight: pip ? normal.height : null,
            child: MediaQuery(
              data: pip ? (_normalMedia ?? media) : media,
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
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
        frameRequest: pip.frameRequest,
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
    this.frameRequest,
  });

  final AndroidPipPhase phase;
  final Rect? sourceRect;
  final Widget child;
  final bool nativeRootLocked;
  final PipFrameRequest? frameRequest;

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
        final request = widget.frameRequest;
        final window = constraints.biggest;
        if (_normalMedia != null &&
            ((widget.nativeRootLocked && request?.pip != true) ||
                window.isEmpty)) {
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
        if (widget.phase == AndroidPipPhase.idle &&
            !widget.nativeRootLocked &&
            request?.pip != true) {
          _normalMedia = media;
        }
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
            request?.pip ??
            ((widget.phase == AndroidPipPhase.active && hasPipBounds) ||
                (widget.phase == AndroidPipPhase.idle && _holdPipLayout));

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
