import 'package:PiliPlus/plugin/pl_player/widgets/video_presentation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MountProbe extends StatefulWidget {
  const _MountProbe({super.key, required this.child});

  final Widget child;

  @override
  State<_MountProbe> createState() => _MountProbeState();
}

class _MountProbeState extends State<_MountProbe> {
  @override
  Widget build(BuildContext context) => widget.child;
}

void main() {
  const viewport = Size(320, 180);

  Future<void> pumpPresentation(
    WidgetTester tester, {
    required Widget? player,
    required Widget poster,
    required bool showPoster,
    bool loading = false,
    VoidCallback? onPlay,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: VideoPresentation(
            width: viewport.width,
            height: viewport.height,
            player: player,
            poster: poster,
            showPoster: showPoster,
            loading: loading,
            onPlay: onPlay,
          ),
        ),
      ),
    ),
  );

  testWidgets('cover and loading changes preserve player and cover state', (
    tester,
  ) async {
    final playerKey = GlobalKey<_MountProbeState>();
    final posterKey = GlobalKey<_MountProbeState>();
    _MountProbeState? playerState;
    _MountProbeState? posterState;

    // Initial cover, preparing, video, returning cover, preparing, video.
    for (final phase in [
      (showPoster: true, loading: false),
      (showPoster: true, loading: true),
      (showPoster: false, loading: false),
      (showPoster: true, loading: false),
      (showPoster: true, loading: true),
      (showPoster: false, loading: false),
    ]) {
      await pumpPresentation(
        tester,
        player: _MountProbe(
          key: playerKey,
          child: const ColoredBox(color: Colors.green),
        ),
        poster: _MountProbe(
          key: posterKey,
          child: const ColoredBox(color: Colors.blue),
        ),
        showPoster: phase.showPoster,
        loading: phase.loading,
      );
      playerState ??= playerKey.currentState;
      posterState ??= posterKey.currentState;
      expect(playerKey.currentState, same(playerState));
      expect(posterKey.currentState, same(posterState));
      expect(find.byKey(playerKey), findsOneWidget);
      expect(find.byKey(posterKey), findsOneWidget);
      expect(tester.getSize(find.byKey(playerKey)), viewport);
      expect(tester.getSize(find.byKey(posterKey)), viewport);
      expect(
        find.ancestor(
          of: find.byKey(playerKey),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: find.byKey(playerKey),
          matching: find.byWidgetPredicate(
            (widget) => widget is Offstage && widget.offstage,
          ),
        ),
        findsNothing,
      );
      expect(
        find.byType(CircularProgressIndicator),
        phase.loading ? findsOneWidget : findsNothing,
      );
    }
  });

  testWidgets(
    'a player arriving during preparation keeps its state afterward',
    (
      tester,
    ) async {
      const playerKey = ValueKey('late-player');
      const poster = ColoredBox(color: Colors.blue);
      await pumpPresentation(
        tester,
        player: null,
        poster: poster,
        showPoster: true,
      );
      await pumpPresentation(
        tester,
        player: const _MountProbe(
          key: playerKey,
          child: ColoredBox(color: Colors.green),
        ),
        poster: poster,
        showPoster: true,
        loading: true,
      );
      final state = tester.state(find.byKey(playerKey));
      await pumpPresentation(
        tester,
        player: const _MountProbe(
          key: playerKey,
          child: ColoredBox(color: Colors.green),
        ),
        poster: poster,
        showPoster: false,
      );
      expect(tester.state(find.byKey(playerKey)), same(state));
    },
  );

  testWidgets(
    'a visible loading cover preserves play intent and player state',
    (
      tester,
    ) async {
      var playRequests = 0;
      var playerTaps = 0;
      final playerKey = GlobalKey<_MountProbeState>();
      Widget player() => _MountProbe(
        key: playerKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => playerTaps++,
          child: const ColoredBox(color: Colors.green),
        ),
      );
      const poster = ColoredBox(color: Colors.blue);

      await pumpPresentation(
        tester,
        player: player(),
        poster: poster,
        showPoster: true,
        onPlay: () => playRequests++,
      );
      await tester.tap(find.byType(VideoPresentation));
      expect(playRequests, 1);
      expect(playerTaps, 0);
      final playerState = playerKey.currentState;

      await pumpPresentation(
        tester,
        player: player(),
        poster: poster,
        showPoster: true,
        loading: true,
        onPlay: () => playRequests++,
      );
      await tester.tapAt(
        tester.getCenter(find.byType(CircularProgressIndicator)),
      );
      expect(playRequests, 2);
      expect(playerTaps, 0);
      expect(playerKey.currentState, same(playerState));
      expect(tester.getSize(find.byKey(playerKey)), viewport);
      expect(
        tester.getSize(find.byType(CircularProgressIndicator)),
        const Size.square(24),
      );

      await pumpPresentation(
        tester,
        player: player(),
        poster: poster,
        showPoster: false,
        onPlay: () => playRequests++,
      );
      await tester.tap(find.byType(VideoPresentation));
      expect(playRequests, 2);
      expect(playerTaps, 1);
      expect(playerKey.currentState, same(playerState));
      expect(tester.getSize(find.byKey(playerKey)), viewport);
    },
  );

  testWidgets('cover includes one opaque black backdrop around its content', (
    tester,
  ) async {
    const posterKey = ValueKey('letterboxed-poster');
    await pumpPresentation(
      tester,
      player: const ColoredBox(color: Colors.green),
      poster: const Center(
        key: posterKey,
        child: SizedBox.square(dimension: 80),
      ),
      showPoster: true,
    );
    final backgrounds = find.ancestor(
      of: find.byKey(posterKey),
      matching: find.byWidgetPredicate(
        (widget) => widget is ColoredBox && widget.color == Colors.black,
      ),
    );
    expect(backgrounds, findsOneWidget);
    expect(tester.getSize(backgrounds), viewport);
    expect(tester.getSize(find.byKey(posterKey)), viewport);
  });
}
