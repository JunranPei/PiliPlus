import 'dart:typed_data';

import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/grpc/grpc_decode.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List envelope(Uint8List payload, {bool gzip = false}) {
  final body = gzip ? const GZipEncoder().encodeBytes(payload) : payload;
  return Uint8List(5 + body.length)
    ..[0] = gzip ? 1 : 0
    ..buffer.asByteData(1, 4).setInt32(0, body.length, Endian.big)
    ..setAll(5, body);
}

void main() {
  final message = DmSegMobileReply(
    elems: List.generate(
      2400,
      (i) => DanmakuElem(
        content: 'synthetic comment $i - abcdefghijklmnopqrstuvwxyz',
        progress: i * 100,
        mode: 1,
        fontsize: 25,
      ),
    ),
  );

  for (final gzip in [false, true]) {
    test('real isolate preserves protobuf fields, gzip=$gzip', () async {
      final bytes = envelope(message.writeToBuffer(), gzip: gzip);
      Map<String, Object?>? metrics;
      final result = await GrpcDecode.decode(
        bytes,
        DmSegMobileReply.fromBuffer,
        isolate: true,
        thresholdBytes: 0,
        onTiming: (m) => metrics = m,
      );
      expect(result, isA<Success<DmSegMobileReply>>());
      expect(result.data.writeToBuffer(), message.writeToBuffer());
      expect(metrics!['worker'], isTrue);
      expect(metrics!['gzip'], gzip);
      expect(metrics!['inflatedBytes'], message.writeToBuffer().length);
      expect(metrics!['parseUs'], greaterThan(0));
    });
  }

  test('mid-size response moves off UI only under the new threshold', () async {
    final bytes = envelope(message.writeToBuffer());
    expect(bytes.length, inExclusiveRange(16 * 1024, 256 * 1024));
    final modes = <Object?>[];
    for (final threshold in [GrpcDecode.defaultThreshold, 16 * 1024]) {
      final result = await GrpcDecode.decode(
        bytes,
        DmSegMobileReply.fromBuffer,
        isolate: true,
        thresholdBytes: threshold,
        onTiming: (m) => modes.add(m['worker']),
      );
      expect(result.data.elems.length, 2400);
    }
    expect(modes, [false, true]);
  });

  test('small response and explicit non-isolate remain on caller', () async {
    final bytes = envelope(DmSegMobileReply(state: 1).writeToBuffer());
    for (final config in [
      (true, 16 * 1024),
      (false, 0),
      (true, bytes.length),
    ]) {
      Map<String, Object?>? metrics;
      final result = await GrpcDecode.decode(
        bytes,
        DmSegMobileReply.fromBuffer,
        isolate: config.$1,
        thresholdBytes: config.$2,
        onTiming: (m) => metrics = m,
      );
      expect(result.data.state, 1);
      expect(metrics!['worker'], isFalse);
    }
  });

  test(
    'malformed envelope and protobuf return the same error on both paths',
    () async {
      for (final bytes in [
        Uint8List.fromList([0, 1]),
        envelope(Uint8List.fromList([0x80])),
      ]) {
        final local = await GrpcDecode.decode(
          bytes,
          DmSegMobileReply.fromBuffer,
        );
        final worker = await GrpcDecode.decode(
          bytes,
          DmSegMobileReply.fromBuffer,
          isolate: true,
          thresholdBytes: 0,
        );
        expect(local, isA<Error>());
        expect(worker, local);
      }
    },
  );
}
