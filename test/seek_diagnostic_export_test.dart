import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/playback/seek_diagnostic_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('piliplus/playback_diagnostics');
  test('export waits for native flush and includes only current process files', () async {
    final root = await Directory.systemTemp.createTemp('pili-seek-export-');
    final native = File('${root.path}/native-$pid-1.jsonl');
    await native.writeAsString('before-flush\n');
    await File('${root.path}/flutter-$pid-1.jsonl').writeAsString('dart-events\n');
    await File('${root.path}/native-0-1.jsonl').writeAsString('old process');
    await File('${root.path}/unrelated.json').writeAsString('do not export');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'stop');
      await native.writeAsString('after-flush\n');
      return {'directory': root.path, 'model': 'SM-S938B', 'sdk': 36};
    });
    try {
      final file = await SeekDiagnosticExport.createBundle(destination: root);
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      final names = archive.files.map((f) => f.name).toSet();
      expect(names, containsAll(['native-$pid-1.jsonl', 'flutter-$pid-1.jsonl',
        'device-and-capture.json', 'android-audio.log']));
      expect(names, isNot(contains('native-0-1.jsonl')));
      expect(names, isNot(contains('unrelated.json')));
      expect(utf8.decode(archive.findFile('native-$pid-1.jsonl')!.content), 'after-flush\n');
      final metadata = jsonDecode(utf8.decode(archive.findFile('device-and-capture.json')!.content));
      expect(metadata['model'], 'SM-S938B');
      expect(await File('${root.path}/unrelated.json').readAsString(), 'do not export');
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    }
  });
}
