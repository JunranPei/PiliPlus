import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:PiliPlus/plugin/pl_player/playback/isolated_media_sources.dart';
import 'package:PiliPlus/plugin/pl_player/playback/persisted_resume_index_hints.dart';
import 'package:PiliPlus/plugin/pl_player/playback/resume_index_hint.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'fixtures/resume_index_fixture.dart';

// This scope contains only transferable arguments. The child has a new static
// in-memory index cache and opens the actual closed Hive file itself.
Future<Map<String, Object?>> _freshResume(String directory, int port) =>
    Isolate.run(() => _readFromDisk(directory, port));

Future<Map<String, Object?>> _readFromDisk(String directory, int port) async {
  Hive.init(directory);
  final box = await Hive.openBox<dynamic>('hints');
  IsolatedMediaSources.preparePersistedIndexHints(box);
  final events = <Map<String, Object?>>[];
  final source = IsolatedMediaSources(
    headers: {'User-Agent': 'current-process'},
    onEvent: (name, data) => events.add({'name': name, ...data}),
  );
  final client = HttpClient();
  Future<List<int>> read(String url, String range) async {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('range', range);
    final response = await request.close();
    if (response.statusCode != 206) throw StateError('Unexpected status');
    return response.fold<List<int>>([], (a, b) => a..addAll(b));
  }

  try {
    final urls = await source.start(
      'http://127.0.0.1:$port/video?token=current',
      'http://127.0.0.1:$port/audio?token=current',
      resumePosition: const Duration(seconds: 10),
    );
    final init = await read(urls.video, 'bytes=0-65535');
    final video = await read(urls.video, 'bytes=600000-600031');
    final audio = await read(urls.audio, 'bytes=600000-600031');
    return {'events': events, 'init': init, 'video': video, 'audio': audio};
  } finally {
    source.close();
    client.close(force: true);
    await box.close();
  }
}

void main() {
  late Directory directory;
  late Box<dynamic> box;
  late Uint8List bytes;
  ResumeIndexHint hint([Uint8List? prefix, int? total]) => ResumeIndexHint(
    prefix: prefix ?? Uint8List.sublistView(bytes, 0, 65536),
    totalBytes: total ?? bytes.length,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pili-index-test-');
    Hive.init(directory.path);
    box = await Hive.openBox<dynamic>('hints');
    bytes = resumeIndexFixture();
  });
  tearDown(() async {
    if (box.isOpen) await box.close();
    await directory.delete(recursive: true);
  });

  test(
    'disk reopen retains only index metadata and independent byte copies',
    () async {
      final store = PersistedResumeIndexHints(box);
      expect(await store.put('video:/signed/path', hint()), 96);
      final first = store.get('video:/signed/path')!;
      expect(first.prefix, bytes.sublist(0, 96));
      first.prefix[0] = 255;
      expect(store.get('video:/signed/path')!.prefix[0], bytes[0]);
      expect(box.keys.single.toString(), isNot(contains('/signed/path')));
      await box.close();
      box = await Hive.openBox<dynamic>('hints');
      final restored = PersistedResumeIndexHints(box)
          .get('video:/signed/path')!;
      expect(restored.prefix, bytes.sublist(0, 96));
      expect(restored.totalBytes, bytes.length);
      final record = box.get(box.keys.single) as Map;
      expect(record.keys.toSet(), {'version', 'atMs', 'totalBytes', 'prefix'});
    },
  );

  test('version-one sidx survives reopen', () async {
    bytes = resumeIndexFixture(version: 1);
    expect(await PersistedResumeIndexHints(box).put('video:v1', hint()), 104);
    await box.close();
    box = await Hive.openBox<dynamic>('hints');
    expect(
      PersistedResumeIndexHints(box).get('video:v1')!.prefix,
      bytes.sublist(0, 104),
    );
  });

  test('expired and future-dated hints are misses', () async {
    var now = 10000;
    final store = PersistedResumeIndexHints(
      box,
      ttl: const Duration(seconds: 2),
      nowMs: () => now,
    );
    await store.put('video:clock', hint());
    now = 11999;
    expect(store.get('video:clock'), isNotNull);
    now = 12000;
    expect(store.get('video:clock'), isNull);
    now = 9999;
    expect(store.get('video:clock'), isNull);
  });

  test(
    'concurrent writes obey capacity and preserve unrelated cache entries',
    () async {
      var now = 1;
      final store = PersistedResumeIndexHints(
        box,
        capacity: 2,
        nowMs: () => now++,
      );
      await box.put('unrelated', {'preserved': true});
      expect(
        await Future.wait([
          store.put('video:old', hint()),
          store.put('audio:new', hint()),
          store.put('video:new', hint()),
        ]),
        [96, 96, 96],
      );
      expect(store.get('video:old'), isNull);
      expect(store.get('audio:new'), isNotNull);
      expect(store.get('video:new'), isNotNull);
      expect(box.length, 3);
      expect(box.get('unrelated'), {'preserved': true});
      await store.put('audio:new', hint());
      expect(box.length, 3);
    },
  );

  test(
    'invalid, oversized, truncated and media-leading data are not persisted',
    () async {
      final store = PersistedResumeIndexHints(box);
      final mdat = Uint8List.fromList(bytes.sublist(0, 96));
      ByteData.sublistView(mdat).setUint32(4, 0x6d646174);
      for (final invalid in [
        Uint8List(0),
        Uint8List(64),
        Uint8List.sublistView(bytes, 0, 95),
        Uint8List.sublistView(bytes, 0, 65537),
        mdat,
      ]) {
        expect(await store.put('video:invalid', hint(invalid)), isNull);
      }
      expect(await store.put('video:length', hint(null, 80)), isNull);
      expect(await store.put('', hint()), isNull);
      expect(box.isEmpty, isTrue);
    },
  );

  test(
    'damaged record and closed optional box degrade to cache misses',
    () async {
      final store = PersistedResumeIndexHints(box);
      await store.put('video:damage', hint());
      final key = box.keys.single;
      await box.put(key, {'version': 2});
      expect(store.get('video:damage'), isNull);
      await box.put(key, {
        'version': 1,
        'atMs': 1,
        'totalBytes': 'wrong',
        'prefix': [],
      });
      expect(store.get('video:damage'), isNull);
      await box.close();
      expect(store.get('video:damage'), isNull);
      expect(await store.put('video:closed', hint()), isNull);
    },
  );

  test(
    'fresh isolate requests current target URLs before fresh initialization headers',
    () async {
      final store = PersistedResumeIndexHints(box);
      await store.put('video:/video', hint());
      await store.put('audio:/audio', hint());
      await box.close();
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final releaseHeaders = Completer<void>();
      final earlyTargets = Completer<void>();
      final targets = <String>{};
      final requests = <({String? token, String? agent})>[];
      origin.listen((request) {
        unawaited(
          () async {
            requests.add((
              token: request.uri.queryParameters['token'],
              agent: request.headers.value('User-Agent'),
            ));
            final range = request.headers.value('range')!;
            if (range == 'bytes=0-') {
              await releaseHeaders.future;
            } else if (range == 'bytes=600000-') {
              targets.add(request.uri.path);
              if (targets.length == 2 && !earlyTargets.isCompleted)
                earlyTargets.complete();
            }
            final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
            final start = int.parse(match[1]!);
            final end = match[2]!.isEmpty
                ? bytes.length - 1
                : int.parse(match[2]!);
            request.response
              ..statusCode = 206
              ..contentLength = end - start + 1;
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/${bytes.length}',
            );
            request.response.add(bytes.sublist(start, end + 1));
            await request.response.close();
          }().catchError((Object _) {}),
        );
      });
      final result = _freshResume(directory.path, origin.port);
      // Install the error handler immediately so cleanup after a failed barrier
      // never leaves an unobserved child-isolate exception.
      result.ignore();
      try {
        await earlyTargets.future.timeout(const Duration(seconds: 5));
        expect(releaseHeaders.isCompleted, isFalse);
        releaseHeaders.complete();
        final observed = await result.timeout(const Duration(seconds: 5));
        expect(requests, isNotEmpty);
        expect(requests.map((r) => r.token), everyElement('current'));
        expect(requests.map((r) => r.agent), everyElement('current-process'));
        expect(observed['init'], bytes.sublist(0, 65536));
        expect(observed['video'], bytes.sublist(600000, 600032));
        expect(observed['audio'], bytes.sublist(600000, 600032));
        final events = observed['events']! as List<Map<String, Object?>>;
        final lookup = events.singleWhere(
          (e) => e['name'] == 'isolated.indexHint.lookup',
        );
        expect(lookup['videoOrigin'], 'disk');
        expect(lookup['audioOrigin'], 'disk');
      } finally {
        if (!releaseHeaders.isCompleted) releaseHeaders.complete();
        await result
            .timeout(const Duration(seconds: 5))
            .catchError((Object _) => <String, Object?>{});
        await origin.close(force: true);
      }
    },
    skip:
        !const bool.fromEnvironment('PERSIST_RESUME_INDEX') ||
        !const bool.fromEnvironment('REUSE_RESUME_INDEX') ||
        !const bool.fromEnvironment('PREFETCH_RESUME_AUDIO_MASTER') ||
        !const bool.fromEnvironment('PREFETCH_RESUME_PRESENTATION_TIME'),
  );
}
