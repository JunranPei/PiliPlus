import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:PiliPlus/plugin/pl_player/android_pip_controller.dart';

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
  });

  final AndroidPipPhase phase;
  final Rect? sourceRect;
  final Widget child;

  @override
  State<PipViewport> createState() => _PipViewportState();
}

class _PipViewportState extends State<PipViewport> {
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final window = constraints.biggest;
        // Do not switch the Flutter subtree from a size threshold. Android
        // owns the entry animation and may resize the Activity before the
        // native mode callback; changing the page during that interval adds a
        // second transition on top of SystemUI. Other PiP implementations
        // switch to video-only content from the native "started" callback.
        final isPipWindow = widget.phase == AndroidPipPhase.active;

        // The Activity can update its constraints before the root
        // MediaQuery notification arrives. Propagate the actual bounds to
        // the retained page so its existing player receives the PiP size,
        // instead of laying out a full-window child at the top-left.
        final windowMedia = media.copyWith(size: window);
        return ColoredBox(
          color: const Color(0xFF000000),
          child: MediaQuery(
            data: windowMedia,
            child: PipWindowScope(
              isPipWindow: isPipWindow,
              child: IgnorePointer(
                ignoring: widget.phase != AndroidPipPhase.idle,
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }
}
