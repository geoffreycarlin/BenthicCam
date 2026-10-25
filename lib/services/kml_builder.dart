import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// One recorded position on the track.
class TrackPoint {
  final double lat, lon;
  final double? alt;
  final double? accuracy;
  final DateTime time; // UTC

  const TrackPoint(this.lat, this.lon, this.time, {this.alt, this.accuracy});

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lon': lon,
        if (alt != null) 'alt': alt,
        if (accuracy != null) 'acc': accuracy,
        't': time.toUtc().toIso8601String(),
      };

  factory TrackPoint.fromJson(Map<String, dynamic> j) => TrackPoint(
        (j['lat'] as num).toDouble(),
        (j['lon'] as num).toDouble(),
        DateTime.parse(j['t'] as String).toUtc(),
        alt: (j['alt'] as num?)?.toDouble(),
        accuracy: (j['acc'] as num?)?.toDouble(),
      );
}

/// A photo taken while recording, placed on the map with its thumbnail.
class TrackPhoto {
  final String fileName; // e.g. GOPR0012_2026-10-24T09-31-05.jpg
  final String folder; // photo folder it was saved in
  final TrackPoint at;
  final String? thumbName; // file name inside the KMZ "images/" folder

  const TrackPhoto(this.fileName, this.folder, this.at, {this.thumbName});

  Map<String, dynamic> toJson() => {
        'file': fileName,
        'folder': folder,
        'at': at.toJson(),
        if (thumbName != null) 'thumb': thumbName,
      };

  factory TrackPhoto.fromJson(Map<String, dynamic> j) => TrackPhoto(
        j['file'] as String,
        j['folder'] as String? ?? '',
        TrackPoint.fromJson((j['at'] as Map).cast<String, dynamic>()),
        thumbName: j['thumb'] as String?,
      );
}

/// Great-circle distance in metres.
double distanceMetres(TrackPoint a, TrackPoint b) {
  const r = 6371008.8;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(b.lat - a.lat), dLon = rad(b.lon - a.lon);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(a.lat)) *
          math.cos(rad(b.lat)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(h)));
}

double trackLength(List<TrackPoint> pts) {
  var d = 0.0;
  for (var i = 1; i < pts.length; i++) {
    d += distanceMetres(pts[i - 1], pts[i]);
  }
  return d;
}

String _esc(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s);

String _coord(TrackPoint p) =>
    '${p.lon.toStringAsFixed(7)},${p.lat.toStringAsFixed(7)},${(p.alt ?? 0).toStringAsFixed(1)}';

String _local(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}

String describeDistance(double m) =>
    m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(2)} km';

/// Builds the KML document: the route as a red line, start/end markers and a
/// placemark per photo whose icon and pop-up show the photo's thumbnail.
String buildKml({
  required String name,
  required List<TrackPoint> points,
  required List<TrackPhoto> photos,
}) {
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<kml xmlns="http://www.opengis.net/kml/2.2">')
    ..writeln('<Document>')
    ..writeln('  <name>${_esc(name)}</name>');

  final all = [...points]..sort((a, b) => a.time.compareTo(b.time));
  final start = all.isEmpty ? null : all.first.time;
  final end = all.isEmpty ? null : all.last.time;
  b.writeln('  <description><![CDATA['
      '${photos.length} photo${photos.length == 1 ? '' : 's'}, '
      '${describeDistance(trackLength(all))} recorded'
      '${start == null ? '' : ' from ${_local(start)} to ${_local(end!)}'}'
      ' with GoPro GPS Cam.]]></description>');

  b
    ..writeln(
        '  <Style id="track"><LineStyle><color>ff1e1eff</color><width>4</width></LineStyle></Style>')
    ..writeln(
        '  <Style id="start"><IconStyle><color>ff00c000</color><scale>1.1</scale>'
        '<Icon><href>http://maps.google.com/mapfiles/kml/paddle/go.png</href></Icon></IconStyle></Style>')
    ..writeln('  <Style id="end"><IconStyle><scale>1.1</scale>'
        '<Icon><href>http://maps.google.com/mapfiles/kml/paddle/red-square.png</href></Icon></IconStyle></Style>');

  // ---- the route
  if (all.length >= 2) {
    b
      ..writeln('  <Placemark>')
      ..writeln(
          '    <name>Route (${describeDistance(trackLength(all))})</name>')
      ..writeln('    <styleUrl>#track</styleUrl>')
      ..writeln('    <TimeSpan><begin>${start!.toIso8601String()}</begin>'
          '<end>${end!.toIso8601String()}</end></TimeSpan>')
      ..writeln(
          '    <LineString><tessellate>1</tessellate><altitudeMode>clampToGround</altitudeMode>')
      ..write('      <coordinates>');
    for (final p in all) {
      b.write('${_coord(p)} ');
    }
    b
      ..writeln('</coordinates>')
      ..writeln('    </LineString>')
      ..writeln('  </Placemark>');
  }
  if (all.isNotEmpty) {
    for (final (label, p, style) in [
      ('Start', all.first, 'start'),
      ('End', all.last, 'end')
    ]) {
      if (label == 'End' && all.length < 2) continue;
      b
        ..writeln(
            '  <Placemark><name>$label</name><description>${_local(p.time)}</description>')
        ..writeln(
            '    <styleUrl>#$style</styleUrl><TimeStamp><when>${p.time.toIso8601String()}</when></TimeStamp>')
        ..writeln(
            '    <Point><coordinates>${_coord(p)}</coordinates></Point></Placemark>');
    }
  }

  // ---- photos
  b.writeln('  <Folder><name>Photos (${photos.length})</name>');
  for (final ph in photos) {
    final img = ph.thumbName == null ? null : 'images/${ph.thumbName}';
    b
      ..writeln('    <Placemark>')
      ..writeln('      <name>${_esc(ph.fileName)}</name>')
      ..writeln(
          '      <TimeStamp><when>${ph.at.time.toIso8601String()}</when></TimeStamp>');
    if (img != null) {
      b.writeln(
          '      <Style><IconStyle><scale>2.0</scale><Icon><href>$img</href></Icon></IconStyle>'
          '<BalloonStyle><text>\$[description]</text></BalloonStyle></Style>');
    }
    b
      ..write('      <description><![CDATA[')
      ..write(img == null ? '' : '<img src="$img" width="400"/><br/>')
      ..write('<b>${_esc(ph.fileName)}</b><br/>')
      ..write('Taken ${_local(ph.at.time)}<br/>')
      ..write(
          '${ph.at.lat.toStringAsFixed(6)}, ${ph.at.lon.toStringAsFixed(6)}')
      ..write(ph.at.accuracy == null ? '' : ' (±${ph.at.accuracy!.round()} m)')
      ..write(ph.folder.isEmpty ? '' : '<br/>Folder: ${_esc(ph.folder)}')
      ..writeln(']]></description>')
      ..writeln(
          '      <Point><coordinates>${_coord(ph.at)}</coordinates></Point>')
      ..writeln('    </Placemark>');
  }
  b
    ..writeln('  </Folder>')
    ..writeln('</Document>')
    ..writeln('</kml>');
  return b.toString();
}

/// Packs the KML and thumbnails into a KMZ (zip with doc.kml first).
Uint8List buildKmz(String kml, Map<String, List<int>> images) {
  final archive = Archive()..addFile(ArchiveFile.string('doc.kml', kml));
  images.forEach((name, bytes) =>
      archive.addFile(ArchiveFile.bytes('images/$name', bytes)));
  return ZipEncoder().encodeBytes(archive);
}
