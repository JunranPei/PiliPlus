import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/plugin/pl_player/playback/prepared_resource.dart';
import 'package:PiliPlus/plugin/pl_player/playback/prepared_media_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cancel before creation disposes late result exactly once', () async {
    final created = Completer<Object>();
    final disposed = <Object>[];
    var releases = 0;
    final resource = PreparedResource(
      load: () => created.future,
      dispose: (value) async {
        disposed.add(value);
      },
      onReleased: () => releases++,
    );
    final cancelled = resource.cancel();
    expect(await resource.take(), isNull);
    expect(disposed, isEmpty);
    final value = Object();
    created.complete(value);
    await cancelled;
    await resource.cancel();
    expect(disposed, [value]);
    expect(releases, 1);
  });

  test(
    'take while pending transfers ownership despite later cache cancellation',
    () async {
      final created = Completer<Object>();
      var disposed = false;
      var releases = 0;
      final resource = PreparedResource(
        load: () => created.future,
        dispose: (_) async {
          disposed = true;
        },
        onReleased: () => releases++,
      );
      final taken = resource.take();
      await resource.cancel();
      expect(await resource.take(), isNull);
      final value = Object();
      created.complete(value);
      expect(await taken, same(value));
      expect(disposed, isFalse);
      expect(releases, 1);
    },
  );

  test(
    'cancel completed resource awaits native disposal before release',
    () async {
      final disposal = Completer<void>();
      final entered = Completer<void>();
      var released = false;
      final resource = PreparedResource(
        load: () => Future.value(Object()),
        dispose: (_) {
          entered.complete();
          return disposal.future;
        },
        onReleased: () => released = true,
      );
      final cancelled = resource.cancel();
      await entered.future;
      expect(released, isFalse);
      disposal.complete();
      await cancelled;
      expect(released, isTrue);
    },
  );

  for (final cancel in [false, true]) {
    test('preparation failure releases ownership, cancel=$cancel', () async {
      var releases = 0;
      final resource = PreparedResource<Object>(
        load: () => Future.error(StateError('failed creation')),
        dispose: (_) => throw StateError('no created result'),
        onReleased: () => releases++,
      );
      if (cancel) {
        await resource.cancel();
      } else {
        expect(await resource.take(), isNull);
      }
      await resource.cancel();
      expect(await resource.take(), isNull);
      expect(releases, 1);
    });
  }

  test(
    'DASH builder preserves complete streams and byte lengths for local paths',
    () {
      const video = 'http://127.0.0.1:12345/audio';
      const audio = 'http://127.0.0.1:12346/audio';
      expect(
        dashMediaUri(video, audio, uncut: true),
        'edl://!no_chapters;!no_clip;%${video.length}%$video;'
        '!new_stream;!no_chapters;!no_clip;%${audio.length}%$audio',
      );
      const local = 'D:/视频;1.mp4';
      expect(
        dashMediaUri(local, local, uncut: false, fileSource: true),
        'edl://!no_chapters;%${utf8.encode(local).length}%$local;'
        '!new_stream;!no_chapters;%${utf8.encode(local).length}%$local',
      );
    },
  );
}
