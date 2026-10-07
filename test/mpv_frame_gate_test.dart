import 'package:PiliPlus/plugin/pl_player/playback/mpv_frame_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const source = 'https://example.invalid/video.mp4';
  const otherSource = 'https://example.invalid/other.mp4';

  MpvFrameGateProtocol gate() => MpvFrameGateProtocol(source: source);

  void drain(MpvFrameGateProtocol protocol) => protocol.onQueueDrained(
    path: source,
    currentVo: 'gpu',
    seeking: false,
  );

  test('old loaded and restart events cannot open a new gate', () {
    final protocol = gate()
      ..onFileLoaded(source)
      ..onPlaybackRestart(source, currentVo: 'gpu');
    expect(protocol.isReady, isFalse);
    expect(protocol.error, isNull);
  });

  test('reopening the same URI requires a new start and loaded event', () {
    final protocol = gate()
      ..onPlaybackRestart(source, currentVo: 'gpu')
      ..onStartFile(42)
      ..onPlaybackRestart(source, currentVo: 'gpu');
    expect(protocol.isReady, isFalse);
    protocol.onFileLoaded(source);
    expect(protocol.isReady, isFalse);
    protocol.onPlaybackRestart(source, currentVo: 'gpu');
    drain(protocol);
    expect(protocol.isReady, isTrue);
  });

  test('the previous entry ending does not fail the new load', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onEndFile(41, reason: 2)
      ..onFileLoaded(source)
      ..onPlaybackRestart(source, currentVo: 'gpu');
    drain(protocol);
    expect(protocol.isReady, isTrue);
    expect(protocol.error, isNull);
  });

  test('a loaded different resource cannot reveal the requested video', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onFileLoaded(otherSource)
      ..onPlaybackRestart(source, currentVo: 'gpu');
    expect(protocol.isReady, isFalse);
  });

  test('the restart must still refer to the loaded resource', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onFileLoaded(source)
      ..onPlaybackRestart(otherSource, currentVo: 'gpu')
      ..onPlaybackRestart(source, currentVo: 'gpu');
    expect(protocol.isReady, isFalse);
  });

  test('a newer start invalidates the previous loaded event', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onFileLoaded(source)
      ..onStartFile(43)
      ..onPlaybackRestart(source, currentVo: 'gpu');
    expect(protocol.isReady, isFalse);
    protocol
      ..onFileLoaded(source)
      ..onPlaybackRestart(source, currentVo: 'gpu');
    drain(protocol);
    expect(protocol.isReady, isTrue);
  });

  test('native failure finishes the gate and cannot later become ready', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onEndFile(42, reason: 4, errorCode: -13)
      ..onFileLoaded(source)
      ..onPlaybackRestart(source, currentVo: 'gpu');
    expect(protocol.isReady, isFalse);
    expect(protocol.isFinished, isTrue);
    expect(protocol.error?.message, contains('mpv -13'));
  });

  test('a stopped load finishes rather than waiting forever', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onEndFile(42, reason: 2);
    expect(protocol.isFinished, isTrue);
    expect(protocol.error, isA<MpvFrameGateException>());
  });

  test('redirect requires a fresh start and matching resource', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onEndFile(42, redirected: true)
      ..onFileLoaded(source)
      ..onPlaybackRestart(source, currentVo: 'gpu');
    expect(protocol.isReady, isFalse);
    expect(protocol.error, isNull);
    protocol
      ..onStartFile(43)
      ..onFileLoaded(source)
      ..onPlaybackRestart(source, currentVo: 'gpu');
    drain(protocol);
    expect(protocol.isReady, isTrue);
  });

  test('a normalized media URI is accepted as the same source', () {
    final protocol =
        MpvFrameGateProtocol(
            source: '/tmp/video.mp4',
            normalizedSource: 'file:///tmp/video.mp4',
          )
          ..onStartFile(42)
          ..onFileLoaded('file:///tmp/video.mp4')
          ..onPlaybackRestart('/tmp/video.mp4', currentVo: 'gpu')
          ..onQueueDrained(
            path: '/tmp/video.mp4',
            currentVo: 'gpu',
            seeking: false,
          );
    expect(protocol.isReady, isTrue);
  });

  test('ready is terminal and ignores later playback events', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onFileLoaded(source)
      ..onPlaybackRestart(source, currentVo: 'gpu');
    drain(protocol);
    protocol
      ..onEndFile(42, reason: 4, errorCode: -13)
      ..onStartFile(43);
    expect(protocol.isReady, isTrue);
    expect(protocol.error, isNull);
  });

  test('null VO restart never proves that a video frame is visible', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onFileLoaded(source)
      ..onPlaybackRestart(source, currentVo: 'null');
    drain(protocol);
    expect(protocol.isReady, isFalse);
    expect(protocol.hasRestartCandidate, isFalse);
    protocol
      ..onOutputInvalidated()
      ..onPlaybackRestart(source, currentVo: 'gpu');
    drain(protocol);
    expect(protocol.isReady, isTrue);
  });

  test('a delayed old restart is invalidated by later VO reconfiguration', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onFileLoaded(source)
      // The null restart was queued, but the live property already says gpu.
      ..onPlaybackRestart(source, currentVo: 'gpu');
    expect(protocol.isReady, isFalse);
    protocol.onOutputInvalidated();
    drain(protocol);
    expect(protocol.isReady, isFalse);
    protocol.onPlaybackRestart(source, currentVo: 'gpu');
    drain(protocol);
    expect(protocol.isReady, isTrue);
  });

  test('configuration without a subsequent restart does not reveal video', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onFileLoaded(source)
      ..onOutputInvalidated();
    drain(protocol);
    expect(protocol.isReady, isFalse);
  });

  test('an in-progress seek requires a new restart', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onFileLoaded(source)
      ..onPlaybackRestart(source, currentVo: 'gpu')
      ..onQueueDrained(path: source, currentVo: 'gpu', seeking: true);
    drain(protocol);
    expect(protocol.isReady, isFalse);
    protocol.onPlaybackRestart(source, currentVo: 'gpu');
    drain(protocol);
    expect(protocol.isReady, isTrue);
  });

  test('unavailable output cannot pass the frame gate', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onFileLoaded(source)
      ..onPlaybackRestart(source, currentVo: '');
    drain(protocol);
    expect(protocol.isReady, isFalse);
  });

  test('native desktop libmpv output is accepted', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onFileLoaded(source)
      ..onPlaybackRestart(source, currentVo: 'libmpv')
      ..onQueueDrained(path: source, currentVo: 'libmpv', seeking: false);
    expect(protocol.isReady, isTrue);
  });

  test('a changed output invalidates the pending restart candidate', () {
    final protocol = gate()
      ..onStartFile(42)
      ..onFileLoaded(source)
      ..onPlaybackRestart(source, currentVo: 'gpu')
      ..onQueueDrained(path: source, currentVo: 'null', seeking: false);
    drain(protocol);
    expect(protocol.isReady, isFalse);
  });
}
