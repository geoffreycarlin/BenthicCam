import 'dart:convert';
import 'dart:typed_data';

/// A GPS fix to embed in a photo.
class GpsFix {
  final double latitude;
  final double longitude;
  final double? altitude; // metres
  final double? horizontalAccuracy; // metres
  final DateTime timestamp;

  const GpsFix({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.altitude,
    this.horizontalAccuracy,
  });

  @override
  String toString() =>
      '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}'
      '${horizontalAccuracy != null ? ' (±${horizontalAccuracy!.toStringAsFixed(0)} m)' : ''}';
}

/// Writes EXIF GPS tags into a JPEG without re-encoding the image.
///
/// Strategy (keeps every existing tag — camera model, exposure, maker notes):
///  * The existing TIFF block inside the APP1 "Exif" segment is left untouched.
///  * A copy of IFD0 (with a GPSInfo pointer) and a fresh GPS IFD are appended
///    to the end of the TIFF block, and the TIFF header is pointed at the new
///    IFD0. Nothing existing moves, so all absolute offsets stay valid.
///  * Any GPS data the camera wrote itself is superseded by the phone's fix.
///  * If the JPEG has no EXIF at all, a minimal EXIF segment is inserted.
class ExifGpsWriter {
  static const _tagGpsIfdPointer = 0x8825;
  static const _typeByte = 1, _typeAscii = 2, _typeLong = 4, _typeRational = 5;

  static Uint8List inject(Uint8List jpeg, GpsFix fix) {
    if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) {
      throw const FormatException('Not a JPEG file');
    }
    var pos = 2;
    var insertAt = 2;
    while (pos + 4 <= jpeg.length) {
      if (jpeg[pos] != 0xFF) {
        throw FormatException('Bad JPEG marker at offset $pos');
      }
      final marker = jpeg[pos + 1];
      if (marker == 0xFF) {
        pos++; // fill byte
        continue;
      }
      if (marker == 0xDA || marker == 0xD9) break; // start of scan / EOI
      if ((marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) {
        pos += 2; // standalone markers
        continue;
      }
      final segLen = (jpeg[pos + 2] << 8) | jpeg[pos + 3];
      final segEnd = pos + 2 + segLen;
      if (segLen < 2 || segEnd > jpeg.length) {
        throw const FormatException('Truncated JPEG segment');
      }
      if (marker == 0xE1 && segLen >= 16 && _isExifHeader(jpeg, pos + 4)) {
        final tiff = Uint8List.sublistView(jpeg, pos + 10, segEnd);
        final newTiff = _patchTiff(tiff, fix);
        return _splice(jpeg, pos, segEnd, _app1(newTiff));
      }
      if (marker == 0xE0 && pos == insertAt) insertAt = segEnd; // after JFIF
      pos = segEnd;
    }
    return _splice(jpeg, insertAt, insertAt, _app1(_newTiff(fix)));
  }

  /// Reads the GPS position stored in a JPEG's EXIF, or null if there is
  /// none. Returns null as well when the coordinates are all zero, which is
  /// what Android leaves behind when it strips ("redacts") location from a
  /// photo handed to an app without media-location access.
  static GpsFix? read(Uint8List jpeg) {
    try {
      if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return null;
      var pos = 2;
      while (pos + 4 <= jpeg.length) {
        if (jpeg[pos] != 0xFF) return null;
        final marker = jpeg[pos + 1];
        if (marker == 0xFF) {
          pos++;
          continue;
        }
        if (marker == 0xDA || marker == 0xD9) return null;
        if ((marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) {
          pos += 2;
          continue;
        }
        final segEnd = pos + 2 + ((jpeg[pos + 2] << 8) | jpeg[pos + 3]);
        if (segEnd > jpeg.length) return null;
        if (marker == 0xE1 &&
            segEnd - pos >= 16 &&
            _isExifHeader(jpeg, pos + 4)) {
          return _readTiff(Uint8List.sublistView(jpeg, pos + 10, segEnd));
        }
        pos = segEnd;
      }
    } catch (_) {}
    return null;
  }

  static GpsFix? _readTiff(Uint8List tiff) {
    final Endian e;
    if (tiff[0] == 0x49 && tiff[1] == 0x49) {
      e = Endian.little;
    } else if (tiff[0] == 0x4D && tiff[1] == 0x4D) {
      e = Endian.big;
    } else {
      return null;
    }
    final bd = ByteData.sublistView(tiff);
    final ifd0 = bd.getUint32(4, e);
    int? gps;
    final n0 = bd.getUint16(ifd0, e);
    for (var i = 0; i < n0; i++) {
      final o = ifd0 + 2 + i * 12;
      if (bd.getUint16(o, e) == _tagGpsIfdPointer) gps = bd.getUint32(o + 8, e);
    }
    if (gps == null) return null;

    final tags = <int, int>{}; // tag -> entry offset
    final n = bd.getUint16(gps, e);
    for (var i = 0; i < n; i++) {
      final o = gps + 2 + i * 12;
      tags[bd.getUint16(o, e)] = o;
    }
    String ref(int tag) {
      final o = tags[tag];
      return o == null ? '' : String.fromCharCode(tiff[o + 8]);
    }

    List<double> rationals(int tag) {
      final o = tags[tag];
      if (o == null) return const [];
      final count = bd.getUint32(o + 4, e);
      final off = bd.getUint32(o + 8, e);
      return [
        for (var i = 0; i < count; i++)
          () {
            final num = bd.getUint32(off + i * 8, e);
            final den = bd.getUint32(off + i * 8 + 4, e);
            return den == 0 ? 0.0 : num / den;
          }(),
      ];
    }

    double? dms(List<double> v) =>
        v.length == 3 ? v[0] + v[1] / 60 + v[2] / 3600 : null;

    var lat = dms(rationals(0x0002));
    var lon = dms(rationals(0x0004));
    if (lat == null || lon == null || (lat == 0 && lon == 0)) return null;
    if (ref(0x0001) == 'S') lat = -lat;
    if (ref(0x0003) == 'W') lon = -lon;

    final altV = rationals(0x0006);
    double? alt = altV.isEmpty ? null : altV.first;
    if (alt != null &&
        tags.containsKey(0x0005) &&
        tiff[tags[0x0005]! + 8] == 1) {
      alt = -alt;
    }
    final accV = rationals(0x001F);

    var ts = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final dateO = tags[0x001D];
    final timeV = rationals(0x0007);
    if (dateO != null && timeV.length == 3) {
      final off = bd.getUint32(dateO + 8, e);
      final d = String.fromCharCodes(tiff.sublist(off, off + 10)).split(':');
      if (d.length == 3) {
        ts = DateTime.utc(
            int.parse(d[0]),
            int.parse(d[1]),
            int.parse(d[2]),
            timeV[0].toInt(),
            timeV[1].toInt(),
            timeV[2].floor(),
            ((timeV[2] - timeV[2].floor()) * 1000).round());
      }
    }
    return GpsFix(
      latitude: lat,
      longitude: lon,
      altitude: alt,
      horizontalAccuracy: accV.isEmpty ? null : accV.first,
      timestamp: ts,
    );
  }

  static bool _isExifHeader(Uint8List b, int o) =>
      b[o] == 0x45 &&
      b[o + 1] == 0x78 &&
      b[o + 2] == 0x69 &&
      b[o + 3] == 0x66 &&
      b[o + 4] == 0 &&
      b[o + 5] == 0;

  static Uint8List _app1(List<int> tiff) {
    final len = 2 + 6 + tiff.length;
    if (len > 0xFFFF) {
      throw const FormatException(
          'EXIF block too large for a single APP1 segment');
    }
    return Uint8List.fromList([
      0xFF, 0xE1, len >> 8, len & 0xFF,
      0x45, 0x78, 0x69, 0x66, 0, 0, // "Exif\0\0"
      ...tiff,
    ]);
  }

  static Uint8List _splice(
      Uint8List src, int start, int end, Uint8List insert) {
    final out = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(src, 0, start))
      ..add(insert)
      ..add(Uint8List.sublistView(src, end));
    return out.toBytes();
  }

  /// Appends a new IFD0 + GPS IFD to an existing TIFF block.
  static List<int> _patchTiff(Uint8List tiff, GpsFix fix) {
    final Endian e;
    if (tiff[0] == 0x49 && tiff[1] == 0x49) {
      e = Endian.little;
    } else if (tiff[0] == 0x4D && tiff[1] == 0x4D) {
      e = Endian.big;
    } else {
      throw const FormatException('Unknown TIFF byte order');
    }
    final bd = ByteData.sublistView(tiff);
    if (bd.getUint16(2, e) != 42) {
      throw const FormatException('Bad TIFF header');
    }
    final ifd0 = bd.getUint32(4, e);
    final count = bd.getUint16(ifd0, e);
    if (ifd0 + 2 + count * 12 + 4 > tiff.length) {
      throw const FormatException('IFD0 out of range');
    }

    // Keep every IFD0 entry except an old GPS pointer.
    final kept = <_RawEntry>[];
    for (var i = 0; i < count; i++) {
      final off = ifd0 + 2 + i * 12;
      final tag = bd.getUint16(off, e);
      if (tag != _tagGpsIfdPointer) {
        kept.add(
            _RawEntry(tag, Uint8List.fromList(tiff.sublist(off, off + 12))));
      }
    }
    final nextIfd = bd.getUint32(ifd0 + 2 + count * 12, e);

    final out = _Out(e)..bytes.addAll(tiff);
    out.alignEven();
    final newIfd0 = out.length;
    final n = kept.length + 1;
    final gpsIfd = newIfd0 + 2 + n * 12 + 4;

    // Point the TIFF header at the new IFD0.
    out.set32(4, newIfd0);

    // New IFD0: old entries + GPS pointer, ascending tag order.
    out.put16(n);
    var gpsWritten = false;
    for (final entry in kept) {
      if (!gpsWritten && entry.tag > _tagGpsIfdPointer) {
        _putGpsPointer(out, gpsIfd);
        gpsWritten = true;
      }
      out.bytes.addAll(entry.raw);
    }
    if (!gpsWritten) _putGpsPointer(out, gpsIfd);
    out.put32(nextIfd);

    assert(out.length == gpsIfd);
    _writeIfd(out, _gpsEntries(fix, e), 0);
    return out.bytes;
  }

  /// A minimal TIFF block containing only IFD0 -> GPS IFD.
  static List<int> _newTiff(GpsFix fix) {
    const e = Endian.big;
    final out = _Out(e)
      ..bytes.addAll([0x4D, 0x4D])
      ..put16(42)
      ..put32(8);
    // IFD0 at 8: one entry, next = 0. GPS IFD starts at 8 + 2 + 12 + 4 = 26.
    out.put16(1);
    _putGpsPointer(out, 26);
    out.put32(0);
    _writeIfd(out, _gpsEntries(fix, e), 0);
    return out.bytes;
  }

  static void _putGpsPointer(_Out out, int offset) {
    out
      ..put16(_tagGpsIfdPointer)
      ..put16(_typeLong)
      ..put32(1)
      ..put32(offset);
  }

  /// Writes an IFD at the current end of [out]; out-of-line values follow it.
  static void _writeIfd(_Out out, List<_Entry> entries, int nextIfd) {
    entries.sort((a, b) => a.tag.compareTo(b.tag));
    final start = out.length;
    var dataOff = start + 2 + entries.length * 12 + 4;
    final data = <int>[];
    out.put16(entries.length);
    for (final en in entries) {
      out
        ..put16(en.tag)
        ..put16(en.type)
        ..put32(en.count);
      if (en.value.length <= 4) {
        out.bytes.addAll(en.value);
        for (var i = en.value.length; i < 4; i++) {
          out.bytes.add(0);
        }
      } else {
        out.put32(dataOff + data.length);
        data.addAll(en.value);
        if (data.length.isOdd) data.add(0);
      }
    }
    out.put32(nextIfd);
    out.bytes.addAll(data);
  }

  static List<_Entry> _gpsEntries(GpsFix fix, Endian e) {
    final ts = fix.timestamp.toUtc();
    final entries = <_Entry>[
      _Entry(0x0000, _typeByte, 4, [2, 3, 0, 0]), // GPSVersionID 2.3.0.0
      _Entry.ascii(0x0001, fix.latitude >= 0 ? 'N' : 'S'),
      _Entry(0x0002, _typeRational, 3, _rationals(_dms(fix.latitude), e)),
      _Entry.ascii(0x0003, fix.longitude >= 0 ? 'E' : 'W'),
      _Entry(0x0004, _typeRational, 3, _rationals(_dms(fix.longitude), e)),
      _Entry(
          0x0007,
          _typeRational,
          3,
          _rationals([
            [ts.hour, 1],
            [ts.minute, 1],
            [ts.second * 1000 + ts.millisecond, 1000],
          ], e)),
      _Entry.ascii(0x0012, 'WGS-84'), // GPSMapDatum
      _Entry.ascii(
          0x001D, // GPSDateStamp
          '${ts.year.toString().padLeft(4, '0')}:'
          '${ts.month.toString().padLeft(2, '0')}:'
          '${ts.day.toString().padLeft(2, '0')}'),
    ];
    final alt = fix.altitude;
    if (alt != null && alt.isFinite) {
      entries.add(_Entry(0x0005, _typeByte, 1, [alt < 0 ? 1 : 0]));
      entries.add(_Entry(
          0x0006,
          _typeRational,
          1,
          _rationals([
            [(alt.abs() * 100).round(), 100],
          ], e)));
    }
    final acc = fix.horizontalAccuracy;
    if (acc != null && acc.isFinite && acc >= 0) {
      entries.add(_Entry(
          0x001F,
          _typeRational,
          1,
          _rationals([
            [(acc * 100).round(), 100],
          ], e))); // GPSHPositioningError
    }
    return entries;
  }

  /// Decimal degrees -> [[deg,1],[min,1],[sec*10000,10000]].
  static List<List<int>> _dms(double value) {
    final v = value.abs();
    var d = v.floor();
    final minutesFull = (v - d) * 60;
    var m = minutesFull.floor();
    var s = ((minutesFull - m) * 60 * 10000).round();
    if (s >= 600000) {
      s -= 600000;
      m += 1;
    }
    if (m >= 60) {
      m -= 60;
      d += 1;
    }
    return [
      [d, 1],
      [m, 1],
      [s, 10000],
    ];
  }

  static List<int> _rationals(List<List<int>> values, Endian e) {
    final bd = ByteData(values.length * 8);
    for (var i = 0; i < values.length; i++) {
      bd.setUint32(i * 8, values[i][0], e);
      bd.setUint32(i * 8 + 4, values[i][1], e);
    }
    return bd.buffer.asUint8List();
  }
}

class _RawEntry {
  final int tag;
  final Uint8List raw;
  _RawEntry(this.tag, this.raw);
}

class _Entry {
  final int tag, type, count;
  final List<int> value;
  _Entry(this.tag, this.type, this.count, this.value);

  factory _Entry.ascii(int tag, String s) {
    final bytes = [...ascii.encode(s), 0];
    return _Entry(tag, ExifGpsWriter._typeAscii, bytes.length, bytes);
  }
}

class _Out {
  final Endian e;
  final List<int> bytes = [];
  _Out(this.e);

  int get length => bytes.length;

  void alignEven() {
    if (bytes.length.isOdd) bytes.add(0);
  }

  void put16(int v) {
    final bd = ByteData(2)..setUint16(0, v, e);
    bytes.addAll(bd.buffer.asUint8List());
  }

  void put32(int v) {
    final bd = ByteData(4)..setUint32(0, v, e);
    bytes.addAll(bd.buffer.asUint8List());
  }

  void set32(int offset, int v) {
    final bd = ByteData(4)..setUint32(0, v, e);
    bytes.setRange(offset, offset + 4, bd.buffer.asUint8List());
  }
}
