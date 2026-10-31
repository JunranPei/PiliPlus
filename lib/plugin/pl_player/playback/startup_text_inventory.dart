import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A bounded layout/font inventory for the first-transition text atlas probe.
/// Reads render metadata only, never pixels or picture/image contents.
abstract final class StartupTextInventory {
  static const enabled = bool.fromEnvironment('TRACE_STARTUP_TEXT_INVENTORY');

  static void capture(BuildContext context, String stage) {
    if (!enabled || !PlaybackDiagnostics.enabled) return;
    final paragraphs = <Map<String, Object?>>[];
    var truncated = false;
    void visit(RenderObject render) {
      if (paragraphs.length >= 128) {
        truncated = true;
        return;
      }
      if (render is RenderOffstage && render.offstage) return;
      if (render is RenderOpacity && render.opacity == 0) return;
      if (render is RenderParagraph && render.hasSize) {
        final runs = <Map<String, Object?>>[];
        void span(InlineSpan current, TextStyle inherited) {
          final style = inherited.merge(current.style);
          if (current is TextSpan) {
            final text = current.text;
            if (text != null && text.isNotEmpty) {
              runs.add({
                'text': text,
                'codePoints': text.runes.toList(),
                'fontFamily': style.fontFamily,
                'fontFallback': style.fontFamilyFallback,
                'fontSize': style.fontSize,
                'scaledFontSize': style.fontSize == null
                    ? null
                    : render.textScaler.scale(style.fontSize!),
                'fontWeight': style.fontWeight?.value,
                'fontStyle': style.fontStyle?.name,
                'shadows': style.shadows
                    ?.map(
                      (shadow) => {
                        'blurRadius': shadow.blurRadius,
                        'offset': [shadow.offset.dx, shadow.offset.dy],
                      },
                    )
                    .toList(),
              });
            }
            for (final child in current.children ?? const <InlineSpan>[]) {
              span(child, style);
            }
          }
        }

        span(render.text, const TextStyle());
        paragraphs.add({
          'size': [render.size.width, render.size.height],
          'transform': render.getTransformTo(null).storage.toList(),
          'runs': runs,
        });
      }
      render.visitChildren(visit);
    }

    try {
      final root = context.findRenderObject();
      if (root == null || !root.attached) return;
      visit(root);
      PlaybackDiagnostics.event('startup.textInventory', {
        'stage': stage,
        'paragraphs': paragraphs,
        'truncated': truncated,
        'devicePixelRatio': MediaQuery.devicePixelRatioOf(context),
      });
    } catch (error) {
      PlaybackDiagnostics.event('startup.textInventory.error', {
        'stage': stage,
        'errorType': error.runtimeType.toString(),
      });
    }
  }
}
