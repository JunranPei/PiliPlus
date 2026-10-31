import 'dart:typed_data';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show compute;

typedef GrpcDecodeResult<T> = ({
  LoadingState<T> state,
  int parseUs,
  int? inflatedBytes,
});

/// One gRPC message, decoded identically on either isolate.
abstract final class GrpcDecode {
  static const defaultThreshold = 256 * 1024;

  static Uint8List decompress(Uint8List data) {
    final length = ByteData.sublistView(data, 1, 5).getInt32(0, Endian.big);
    final payload = Uint8List.sublistView(data, 5, length + 5);
    return data[0] == 1 ? const GZipDecoder().decodeBytes(payload) : payload;
  }

  static GrpcDecodeResult<T> _parse<T>(
    (Uint8List, T Function(Uint8List), bool) args,
  ) {
    final timer = args.$3 ? (Stopwatch()..start()) : null;
    int? inflatedBytes;
    LoadingState<T> state;
    try {
      final data = decompress(args.$1);
      inflatedBytes = data.length;
      state = Success(args.$2(data));
    } catch (error) {
      state = Error(error.toString());
    }
    return (
      state: state,
      parseUs: timer?.elapsedMicroseconds ?? 0,
      inflatedBytes: inflatedBytes,
    );
  }

  static Future<LoadingState<T>> decode<T>(
    Uint8List data,
    T Function(Uint8List) parser, {
    bool isolate = false,
    int thresholdBytes = defaultThreshold,
    void Function(Map<String, Object?>)? onTiming,
  }) async {
    final worker = isolate && data.length > thresholdBytes;
    final timer = onTiming != null ? (Stopwatch()..start()) : null;
    final args = (data, parser, onTiming != null);
    final result = worker
        ? await compute(_parse<T>, args, debugLabel: 'grpc.decode')
        : _parse<T>(args);
    onTiming?.call({
      'worker': worker,
      'wireBytes': data.length,
      'gzip': data.isNotEmpty && data[0] == 1,
      'inflatedBytes': result.inflatedBytes,
      'parseUs': result.parseUs,
      'dispatchAndParseUs': timer?.elapsedMicroseconds,
      'success': result.state.isSuccess,
      'thresholdBytes': thresholdBytes,
    });
    return result.state;
  }
}
