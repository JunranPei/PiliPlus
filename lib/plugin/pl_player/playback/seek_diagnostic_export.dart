import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/plugin/pl_player/playback/playback_diagnostics.dart';

abstract final class SeekDiagnosticExport {
  static const enabled = bool.fromEnvironment('SEEK_RUNTIME_TRACE');

  static Future<File> createBundle({Directory? destination}) async {
    final status = await PlaybackDiagnostics.finishForExport();
    status['diagnosticProfile'] = 'samsung-seek-listener-1';
    status['version'] = '${BuildConfig.versionName}+${BuildConfig.versionCode}';
    status['exportedPid'] = pid;
    final directory = status['directory'];
    if (directory is! String) throw StateError('尚未采集到播放记录，请先播放视频并跳转进度');
    final archive = Archive();
    var files = 0;
    await for (final entry in Directory(directory).list()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      // Export only this process. Never include accumulated old QA sessions.
      if (!name.startsWith('native-$pid-') && !name.startsWith('flutter-$pid-')) continue;
      final bytes = await entry.readAsBytes();
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
      files++;
    }
    if (files == 0) throw StateError('当前进程没有播放记录');
    String systemLog;
    try {
      final result = await Process.run('/system/bin/logcat', [
        '-d', '-v', 'threadtime', '--pid=$pid', '-t', '2500', '-s',
        'AAudio', 'AAudioStream', 'AudioTrack', 'MediaCodec', 'CCodec',
        'PiliPlusPiP', 'PiliPlusPiPTrace', 'flutter',
      ]).timeout(const Duration(seconds: 5));
      systemLog = '${result.stdout}\n${result.stderr}';
      status['logcatExitCode'] = result.exitCode;
    } catch (error) { systemLog = 'logcat unavailable: $error'; }
    for (final item in {
      'device-and-capture.json': const JsonEncoder.withIndent('  ').convert(status),
      'android-audio.log': systemLog,
    }.entries) {
      final bytes = utf8.encode(item.value);
      archive.addFile(ArchiveFile(item.key, bytes.length, bytes));
    }
    final temp = destination ??
        (Platform.isAndroid ? await getExternalStorageDirectory() : null) ??
        await getTemporaryDirectory();
    return File('${temp.path}/PiliPlus-seek-$pid-${DateTime.now().millisecondsSinceEpoch}.zip')
      ..writeAsBytesSync(ZipEncoder().encode(archive), flush: true);
  }

  static Future<void> share() async {
    final file = await createBundle();
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], title: '播放诊断记录'));
  }
}
