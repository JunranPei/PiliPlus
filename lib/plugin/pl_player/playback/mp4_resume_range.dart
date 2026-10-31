import 'dart:typed_data';

typedef Mp4ResumeRange = ({int offset, int length, int startUs});

/// Read a complete top-level sidx from an already bounded initialization prefix.
/// Unsupported/nested indexes and incomplete or invalid boxes are cache misses.
/// The legacy native seek includes the preceding segment at exact boundaries.
/// A presentation-time native seek can predict the current segment instead.
/// The native byte request must still match this prediction.
Mp4ResumeRange? mp4ResumeRange(
  Uint8List prefix,
  Duration position, {
  required int totalBytes,
  bool preferPreviousAtBoundary = true,
}) {
  if (position <= Duration.zero || totalBytes <= 0) return null;
  final data = ByteData.sublistView(prefix);
  var box = 0;
  while (box + 8 <= data.lengthInBytes) {
    var size = data.getUint32(box);
    final type = data.getUint32(box + 4);
    var header = 8;
    if (size == 1) {
      if (box + 16 > data.lengthInBytes) return null;
      size = data.getUint64(box + 8);
      header = 16;
    }
    if (size < header || size > data.lengthInBytes - box) return null;
    if (type != 0x73696478) {
      // sidx
      box += size;
      continue;
    }
    final end = box + size;
    var cursor = box + header;
    if (end - cursor < 24) return null;
    final version = data.getUint8(cursor);
    if (version > 1) return null;
    final timescale = data.getUint32(cursor + 8);
    if (timescale == 0) return null;
    cursor += 12;
    if (end - cursor < (version == 1 ? 20 : 12)) return null;
    var time = version == 1 ? data.getUint64(cursor) : data.getUint32(cursor);
    final firstOffset = version == 1
        ? data.getUint64(cursor + 8)
        : data.getUint32(cursor + 4);
    cursor += version == 1 ? 16 : 8;
    final count = data.getUint16(cursor + 2);
    cursor += 4;
    if (count == 0 || count > 4096 || end - cursor != count * 12) return null;
    if (firstOffset < 0 || firstOffset > totalBytes - end) return null;
    var offset = end + firstOffset;
    Mp4ResumeRange? previous;
    Mp4ResumeRange? result;
    // Keep arithmetic inside the signed integer range even for malformed input.
    const maxTimeUnits = 0x1FFFFFFFFFF;
    final targetUs = position.inMicroseconds;
    if (targetUs > 0x7FFFFFFFFFFFFFFF ~/ timescale) return null;
    final target = targetUs * timescale;
    for (var index = 0; index < count; index++, cursor += 12) {
      final reference = data.getUint32(cursor);
      final duration = data.getUint32(cursor + 4);
      final sap = data.getUint32(cursor + 8);
      final length = reference & 0x7FFFFFFF;
      if (reference >> 31 != 0 ||
          length == 0 ||
          duration == 0 ||
          length > totalBytes - offset ||
          time < 0 ||
          time > maxTimeUnits - duration) {
        return null;
      }
      final startsWithSap = sap >> 31 != 0;
      final segment = startsWithSap
          ? (
              offset: offset,
              length: length,
              startUs: time * 1000000 ~/ timescale,
            )
          : null;
      if (target >= time * 1000000 && target < (time + duration) * 1000000) {
        result =
            preferPreviousAtBoundary &&
                target == time * 1000000 &&
                previous != null
            ? previous
            : segment;
      }
      previous = segment;
      time += duration;
      offset += length;
    }
    return result;
  }
  return null;
}
