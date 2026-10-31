import 'dart:typed_data';

Uint8List resumeIndexFixture({int version = 0}) {
  final bytes = Uint8List.fromList(List.generate(900000, (i) => i % 251));
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 16);
  data.setUint32(4, 0x66747970); // ftyp
  final size = (version == 1 ? 40 : 32) + 4 * 12;
  data.setUint32(16, size);
  data.setUint32(20, 0x73696478); // sidx
  data.setUint32(24, version << 24);
  data.setUint32(28, 1);
  data.setUint32(32, 1000);
  var cursor = 36;
  if (version == 1) {
    data.setUint64(cursor, 0);
    data.setUint64(cursor + 8, 400000 - 16 - size);
    cursor += 16;
  } else {
    data.setUint32(cursor, 0);
    data.setUint32(cursor + 4, 400000 - 16 - size);
    cursor += 8;
  }
  data.setUint16(cursor, 0);
  data.setUint16(cursor + 2, 4);
  cursor += 4;
  for (var i = 0; i < 4; i++, cursor += 12) {
    data.setUint32(cursor, 100000);
    data.setUint32(cursor + 4, 5000);
    data.setUint32(cursor + 8, 0x90000000);
  }
  return bytes;
}
