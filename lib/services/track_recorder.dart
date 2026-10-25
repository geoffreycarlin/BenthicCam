import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'kml_builder.dart';

typedef ThumbnailMaker = Future<Uint8List?> Function(Uint8List jpeg);

/// Records the GPS track of a photo session and turns it into a KMZ map.
///
/// Everything is written to disk as it happens (Documents/GoProGPS_Tracks/
/// active/), so nothing is lost if Android closes the app. The KMZ
/// (`Track_DATE_TIME.kmz`) is rebuilt after every photo and once more when
/// the session finishes. A session left unfinished (app swiped away) is
/// finished automatically the next time the app starts.
class TrackRecorder extends ChangeNotifier {
  final Directory root;
  final ThumbnailMaker makeThumb;

  TrackRecorder(this.root, {required this.makeThumb});

  Directory get _active => Directory('${root.path}/active');
  File get _meta => File('${_active.path}/session.json');
  File get _pointsFile => File('${_active.path}/track.jsonl');
  File get _photosFile => File('${_active.path}/photos.jsonl');
  Directory get _thumbs => Directory('${_active.path}/images');
  File get _settings => File('${root.path}/settings.json');

  /// The "Record GPS track" check box (remembered).
  bool enabled = false;

  DateTime? startedAt;
  final List<TrackPoint> points = [];
  final List<TrackPhoto> photos = [];
  double distance = 0;

  bool get active => startedAt != null;

  String get _baseName {
    final t = startedAt!.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Track_${t.year}-${two(t.month)}-${two(t.day)}_${two(t.hour)}${two(t.minute)}';
  }

  File get kmzFile => File('${root.path}/$_baseName.kmz');

  /// Loads settings. If a session was left unfinished, finishes it and
  /// returns the KMZ it produced.
  Future<File?> init() async {
    if (!await root.exists()) await root.create(recursive: true);
    try {
      enabled =
          (jsonDecode(await _settings.readAsString())['enabled'] as bool?) ??
              false;
    } catch (_) {}
    if (await _meta.exists()) {
      await _load();
      return finish();
    }
    return null;
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    await _settings.writeAsString(jsonEncode({'enabled': v}));
    notifyListeners();
  }

  Future<void> start() async {
    if (active) return;
    startedAt = DateTime.now().toUtc();
    points.clear();
    photos.clear();
    distance = 0;
    await _thumbs.create(recursive: true);
    await _meta
        .writeAsString(jsonEncode({'started': startedAt!.toIso8601String()}));
    notifyListeners();
  }

  Future<void> _load() async {
    final m = jsonDecode(await _meta.readAsString());
    startedAt = DateTime.parse(m['started'] as String).toUtc();
    points
      ..clear()
      ..addAll(await _readLines(_pointsFile, TrackPoint.fromJson));
    photos
      ..clear()
      ..addAll(await _readLines(_photosFile, TrackPhoto.fromJson));
    distance = trackLength(points);
  }

  static Future<List<T>> _readLines<T>(
      File f, T Function(Map<String, dynamic>) parse) async {
    if (!await f.exists()) return [];
    final out = <T>[];
    for (final line in await f.readAsLines()) {
      try {
        out.add(parse((jsonDecode(line) as Map).cast<String, dynamic>()));
      } catch (_) {/* a half-written last line after a crash */}
    }
    return out;
  }

  /// Adds a GPS position to the track (skips poor or duplicate fixes).
  Future<void> addPoint(TrackPoint p) async {
    if (!active) return;
    if ((p.accuracy ?? 0) > 50) return; // too inaccurate to plot
    if (points.isNotEmpty) {
      final last = points.last;
      final moved = distanceMetres(last, p);
      final waited = p.time.difference(last.time);
      if (moved < 3 && waited < const Duration(seconds: 30)) return;
      distance += moved;
    }
    points.add(p);
    await _pointsFile.writeAsString('${jsonEncode(p.toJson())}\n',
        mode: FileMode.append, flush: true);
    notifyListeners();
  }

  /// Adds a photo (with its thumbnail) and refreshes the KMZ.
  Future<void> addPhoto(File photo, String folder, TrackPoint at) async {
    if (!active) return;
    final name = photo.uri.pathSegments.last;
    String? thumbName;
    try {
      final thumb = await makeThumb(await photo.readAsBytes());
      if (thumb != null) {
        thumbName = '${(photos.length + 1).toString().padLeft(4, '0')}.jpg';
        await File('${_thumbs.path}/$thumbName')
            .writeAsBytes(thumb, flush: true);
      }
    } catch (e) {
      debugPrint('Thumbnail failed: $e');
    }
    final tp = TrackPhoto(name, folder, at, thumbName: thumbName);
    photos.add(tp);
    await _photosFile.writeAsString('${jsonEncode(tp.toJson())}\n',
        mode: FileMode.append, flush: true);
    // The photo's own position is part of the route too.
    await addPoint(
        TrackPoint(at.lat, at.lon, at.time, alt: at.alt, accuracy: 0));
    await writeKmz();
    notifyListeners();
  }

  /// Writes the KMZ for the session so far.
  Future<File> writeKmz() async {
    final images = <String, List<int>>{};
    for (final ph in photos) {
      if (ph.thumbName == null) continue;
      final f = File('${_thumbs.path}/${ph.thumbName}');
      if (await f.exists()) images[ph.thumbName!] = await f.readAsBytes();
    }
    final kml = buildKml(
        name: _baseName.replaceAll('_', ' '), points: points, photos: photos);
    final out = kmzFile;
    final tmp = File('${out.path}.part');
    await tmp.writeAsBytes(buildKmz(kml, images), flush: true);
    return tmp.rename(out.path);
  }

  /// Ends the session: writes the final KMZ and clears the working files.
  /// Returns the KMZ, or null if nothing was recorded.
  Future<File?> finish() async {
    if (!active) return null;
    File? out;
    if (points.isNotEmpty || photos.isNotEmpty) out = await writeKmz();
    try {
      await _active.delete(recursive: true);
    } catch (_) {}
    startedAt = null;
    points.clear();
    photos.clear();
    distance = 0;
    notifyListeners();
    return out;
  }

  /// Saved KMZ files, newest first.
  Future<List<File>> savedTracks() async {
    if (!await root.exists()) return [];
    final list = <File>[];
    await for (final e in root.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.kmz')) list.add(e);
    }
    list.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return list;
  }
}
