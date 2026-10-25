import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gopro_gps_cam/exif/exif_gps_writer.dart';

/// Minimal JPEG: SOI, APP0 (JFIF), SOS stub, EOI. Enough for segment parsing.
Uint8List _bareJpeg() => Uint8List.fromList([
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      0x00,
      0x10,
      0x4A,
      0x46,
      0x49,
      0x46,
      0x00,
      0x01,
      0x01,
      0x00,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x00,
      0xFF,
      0xDA,
      0x00,
      0x02,
      0x11,
      0x22,
      0xFF,
      0xD9,
    ]);

void main() {
  final fix = GpsFix(
    latitude: -33.856784,
    longitude: 151.215297,
    altitude: 12.5,
    horizontalAccuracy: 4.2,
    timestamp: DateTime.utc(2026, 10, 5, 3, 4, 5),
  );

  test('inserts EXIF into a JPEG that has none', () {
    final out = ExifGpsWriter.inject(_bareJpeg(), fix);
    expect(out.sublist(0, 2), [0xFF, 0xD8]);
    // APP1 Exif goes right after the JFIF APP0 segment (which ends at 20).
    expect(out.sublist(20, 22), [0xFF, 0xE1]);
    expect(String.fromCharCodes(out.sublist(24, 28)), 'Exif');
    // Image data preserved at the end.
    expect(out.sublist(out.length - 8),
        [0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9]);
  });

  test('is idempotent-safe (tagging twice still yields one APP1)', () {
    final once = ExifGpsWriter.inject(_bareJpeg(), fix);
    final twice = ExifGpsWriter.inject(once, fix);
    var app1 = 0;
    for (var i = 0; i < twice.length - 1; i++) {
      if (twice[i] == 0xFF && twice[i + 1] == 0xE1) app1++;
    }
    expect(app1, 1);
  });

  test('reads back exactly what was written', () {
    final out = ExifGpsWriter.inject(_bareJpeg(), fix);
    final back = ExifGpsWriter.read(out)!;
    expect(back.latitude, closeTo(fix.latitude, 1e-6));
    expect(back.longitude, closeTo(fix.longitude, 1e-6));
    expect(back.altitude, closeTo(12.5, 1e-9));
    expect(back.horizontalAccuracy, closeTo(4.2, 1e-9));
    expect(back.timestamp, fix.timestamp);
  });

  test('sample photo keeps camera EXIF and gains GPS', () {
    final src = File('test/fixtures/sample_gopro.jpg').readAsBytesSync();
    expect(ExifGpsWriter.read(src), isNull);
    final back = ExifGpsWriter.read(ExifGpsWriter.inject(src, fix))!;
    expect(back.latitude, closeTo(fix.latitude, 1e-6));
  });

  test('zeroed (Android-redacted) GPS reads as no GPS', () {
    final zero =
        GpsFix(latitude: 0, longitude: 0, timestamp: DateTime.utc(2026));
    expect(ExifGpsWriter.read(ExifGpsWriter.inject(_bareJpeg(), zero)), isNull);
  });

  test('rejects non-JPEG input', () {
    expect(() => ExifGpsWriter.inject(Uint8List.fromList([1, 2, 3, 4]), fix),
        throwsFormatException);
  });
}
