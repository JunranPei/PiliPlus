import 'dart:typed_data';

import 'package:PiliPlus/plugin/pl_player/playback/mp4_resume_range.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/resume_index_fixture.dart';

void main() {
  for (final version in [0, 1]) {
    test(
      'sidx v$version maps exact boundaries and nonzero subsecond resume',
      () {
        final bytes = resumeIndexFixture(version: version);
        final prefix = Uint8List.sublistView(bytes, 0, 120);
        expect(
          mp4ResumeRange(
            prefix,
            const Duration(seconds: 10),
            totalBytes: bytes.length,
          ),
          (offset: 500000, length: 100000, startUs: 5000000),
        );
        expect(
          mp4ResumeRange(
            prefix,
            const Duration(milliseconds: 10123),
            totalBytes: bytes.length,
          ),
          (offset: 600000, length: 100000, startUs: 10000000),
        );
        expect(
          mp4ResumeRange(
            prefix,
            const Duration(seconds: 21),
            totalBytes: bytes.length,
          ),
          isNull,
        );
        expect(
          mp4ResumeRange(prefix, Duration.zero, totalBytes: bytes.length),
          isNull,
        );
      },
    );
  }
  for (final version in [0, 1]) {
    test('presentation-time sidx v$version includes its exact boundary', () {
      final bytes = resumeIndexFixture(version: version);
      final prefix = Uint8List.sublistView(bytes, 0, 120);
      for (final milliseconds in [9999, 10000, 10001]) {
        expect(
          mp4ResumeRange(
            prefix,
            Duration(milliseconds: milliseconds),
            totalBytes: bytes.length,
            preferPreviousAtBoundary: false,
          ),
          milliseconds < 10000
              ? (offset: 500000, length: 100000, startUs: 5000000)
              : (offset: 600000, length: 100000, startUs: 10000000),
        );
      }
    });
  }
  test(
    'incomplete prefixes, invalid sizes, totals and nested indexes miss',
    () {
      final bytes = resumeIndexFixture();
      for (var length = 0; length < 96; length++) {
        expect(
          mp4ResumeRange(
            Uint8List.sublistView(bytes, 0, length),
            const Duration(seconds: 10),
            totalBytes: bytes.length,
          ),
          isNull,
        );
      }
      expect(
        mp4ResumeRange(bytes, const Duration(seconds: 10), totalBytes: 550000),
        isNull,
      );
      final data = ByteData.sublistView(bytes)
        ..setUint32(48, 0x80000001); // Nested first reference.
      expect(
        mp4ResumeRange(
          bytes,
          const Duration(seconds: 10),
          totalBytes: bytes.length,
        ),
        isNull,
      );
      data
        ..setUint32(48, 100000)
        ..setUint32(32, 0); // Invalid timescale.
      expect(
        mp4ResumeRange(
          bytes,
          const Duration(seconds: 10),
          totalBytes: bytes.length,
        ),
        isNull,
      );
    },
  );
  test('malformed 64-bit index values cannot wrap into valid offsets', () {
    final bytes = resumeIndexFixture(version: 1);
    final data = ByteData.sublistView(bytes)..setUint64(44, 0x7FFFFFFFFFFFFFFF);
    expect(
      mp4ResumeRange(
        bytes,
        const Duration(seconds: 10),
        totalBytes: bytes.length,
      ),
      isNull,
    );
    data
      ..setUint64(44, 400000 - 104)
      ..setUint64(36, 0x7FFFFFFFFFFFFFFF);
    expect(
      mp4ResumeRange(
        bytes,
        const Duration(seconds: 10),
        totalBytes: bytes.length,
      ),
      isNull,
    );
  });
}
