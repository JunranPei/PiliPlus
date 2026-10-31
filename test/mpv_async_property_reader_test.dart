import 'package:PiliPlus/plugin/pl_player/playback/mpv_async_property_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('late replies cannot satisfy a newer source validation read', () async {
    final reader = MpvAsyncPropertyReader(request: (_, _) => 0, release: () {});
    final first = reader.read('path');
    reader.reply(1, value: 'old');
    expect(await first, 'old');
    final second = reader.read('path');
    var finished = false;
    second.then((_) => finished = true);
    reader.reply(1, value: 'stale');
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    reader.reply(2, value: 'current');
    expect(await second, 'current');
    reader.dispose();
  });

  test(
    'cancellation completes pending read and rejects all later reads',
    () async {
      var releases = 0;
      var requests = 0;
      final reader = MpvAsyncPropertyReader(
        request: (_, _) {
          requests++;
          return 0;
        },
        release: () => releases++,
      );
      final pending = reader.read('path');
      final cancelled = expectLater(pending, throwsStateError);
      reader.dispose();
      reader
        ..reply(1, value: 'late')
        ..dispose();
      await cancelled;
      await expectLater(reader.read('seeking'), throwsStateError);
      expect(releases, 1);
      expect(requests, 1);
    },
  );

  test(
    'out of order replies retain each property in a parallel snapshot',
    () async {
      final reader = MpvAsyncPropertyReader(
        request: (_, _) => 0,
        release: () {},
      );
      final first = reader.read('current-vo');
      final second = reader.read('path');
      final third = reader.read('seeking');
      reader.reply(3, value: 'no');
      reader.reply(2, value: 'current');
      reader.reply(1, value: 'gpu');
      expect(await first, 'gpu');
      expect(await second, 'current');
      expect(await third, 'no');
      reader.dispose();
    },
  );

  test(
    'unavailable output preserves the existing empty property behavior',
    () async {
      final reader = MpvAsyncPropertyReader(
        request: (_, _) => 0,
        release: () {},
      );
      final pending = reader.read('current-vo');
      reader.reply(1, error: -10);
      expect(await pending, isEmpty);
      reader.dispose();
    },
  );

  test('failed submission does not strand a pending request', () async {
    final reader = MpvAsyncPropertyReader(
      request: (_, _) => -1,
      release: () {},
    );
    await expectLater(reader.read('path'), throwsStateError);
    await expectLater(reader.read('seeking'), throwsStateError);
    reader.dispose();
  });

  test('cancellation resolves every read in an unfinished snapshot', () async {
    final reader = MpvAsyncPropertyReader(request: (_, _) => 0, release: () {});
    final batch = Future.wait([
      reader.read('path'),
      reader.read('current-vo'),
      reader.read('seeking'),
    ]);
    final cancelled = expectLater(batch, throwsStateError);
    reader.reply(2, value: 'gpu');
    reader.dispose();
    reader.reply(1, value: 'stale');
    await cancelled;
  });
}
