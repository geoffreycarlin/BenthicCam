import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_camera.dart';
import 'package:gopro_gps_cam/exif/exif_gps_writer.dart';
import 'package:gopro_gps_cam/gopro/camera.dart';
import 'package:gopro_gps_cam/services/capture_service.dart';
import 'package:gopro_gps_cam/services/kml_builder.dart';
import 'package:gopro_gps_cam/services/photo_library.dart';
import 'package:gopro_gps_cam/services/thumbnailer.dart';
import 'package:gopro_gps_cam/services/track_recorder.dart';
import 'package:xml/xml.dart';

TrackPoint pt(double dLat, int sec, {double acc = 5}) =>
    TrackPoint(-28.1747 + dLat, 153.5408, DateTime.utc(2026, 10, 24, 1, 0, sec),
        accuracy: acc, alt: 20);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('trk'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('KML is valid and contains route, start/end and photo thumbnails', () {
    final kml = buildKml(
      name: 'Track 2026-10-24 1100',
      points: [pt(0, 0), pt(0.0001, 10), pt(0.0002, 20)],
      photos: [
        TrackPhoto('GOPR0001 & x.jpg', 'Bridge', pt(0.0001, 10),
            thumbName: '0001.jpg')
      ],
    );
    final doc = XmlDocument.parse(kml); // throws if malformed
    final coords = doc
        .findAllElements('LineString')
        .single
        .getElement('coordinates')!
        .innerText
        .trim()
        .split(' ');
    expect(coords, hasLength(3));
    expect(coords.first, '153.5408000,-28.1747000,20.0');
    final names = doc.findAllElements('name').map((e) => e.innerText).toList();
    expect(names, containsAll(['Start', 'End', 'GOPR0001 & x.jpg']));
    expect(kml, contains('<img src="images/0001.jpg"'));
    expect(kml, contains('<href>images/0001.jpg</href>'));
    expect(trackLength([pt(0, 0), pt(0.0002, 20)]), closeTo(22.2, 0.3));

    final kmz = buildKmz(kml, {
      '0001.jpg': [1, 2, 3]
    });
    final zip = ZipDecoder().decodeBytes(kmz);
    expect(zip.files.first.name, 'doc.kml');
    expect(zip.files.map((f) => f.name), contains('images/0001.jpg'));
  });

  test(
      'recorder filters points, writes KMZ, and recovers an unfinished session',
      () async {
    final root = Directory('${tmp.path}/tracks');
    Future<Uint8List?> fakeThumb(Uint8List _) async =>
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
    final rec = TrackRecorder(root, makeThumb: fakeThumb);
    expect(await rec.init(), isNull);
    await rec.setEnabled(true);
    await rec.start();
    await rec.addPoint(pt(0, 0));
    await rec.addPoint(pt(0.00001, 2)); // 1 m in 2 s: skipped
    await rec.addPoint(pt(0.001, 4, acc: 80)); // inaccurate: skipped
    await rec.addPoint(pt(0.0005, 6)); // 55 m: kept
    expect(rec.points, hasLength(2));
    final photo = File('${tmp.path}/GOPR0001.jpg')..writeAsBytesSync([1, 2, 3]);
    await rec.addPhoto(photo, 'Photos', pt(0.0006, 8));
    expect(rec.kmzFile.existsSync(), isTrue);

    // App "killed": a new recorder finds the session and finishes it.
    final again = TrackRecorder(root, makeThumb: fakeThumb);
    final kmz = await again.init();
    expect(again.enabled, isTrue);
    expect(again.active, isFalse);
    expect(kmz, isNotNull);
    final zip = ZipDecoder().decodeBytes(kmz!.readAsBytesSync());
    final kml = String.fromCharCodes(zip.files.first.content);
    expect(kml, contains('GOPR0001.jpg'));
    expect(Directory('${root.path}/active').existsSync(), isFalse);
    expect(await again.savedTracks(), hasLength(1));
  });

  for (final keep in [false, true]) {
    testWidgets(
        'review: ${keep ? 'Keep saves + starts track' : 'Discard saves nothing'}',
        (tester) async {
      final svc = CaptureService()
        ..library = PhotoLibrary(Directory('${tmp.path}/GoProGPS'))
        ..tracks = TrackRecorder(Directory('${tmp.path}/tracks'),
            makeThumb: makeThumbnail)
        ..location.debugFix = GpsFix(
            latitude: -28.1747,
            longitude: 153.5408,
            horizontalAccuracy: 4,
            timestamp: DateTime.utc(2026, 10, 24, 1, 2, 3));
      var reviewed = 0, trackStarted = 0;
      svc.reviewPhoto = (p) async {
        reviewed++;
        expect(ExifGpsWriter.read(p.bytes)!.latitude, closeTo(-28.1747, 1e-6));
        return keep;
      };
      svc.onTrackStarted = () async => trackStarted++;
      await tester.runAsync(() async {
        await svc.library!.load();
        await svc.tracks!.init();
        await svc.tracks!.setEnabled(true);
        await svc.connectTo(FoundCamera(
            id: 'x',
            name: 'Sim',
            rssi: -50,
            create: () => FakeGoProCamera('Sim')));
        await svc.capture();
      });
      expect(reviewed, 1);
      final saved = await tester.runAsync(() => svc.library!.photosIn());
      if (!keep) {
        expect(saved, isEmpty);
        expect(svc.status, contains('not kept'));
        expect(svc.tracks!.active, isFalse);
        expect(trackStarted, 0);
      } else {
        expect(saved, hasLength(1));
        expect(svc.tracks!.active, isTrue);
        expect(trackStarted, 1);
        expect(svc.tracks!.photos.single.thumbName, isNotNull,
            reason: 'real thumbnail via dart:ui');
        final kmz = await tester.runAsync(() => svc.tracks!.finish());
        final zip = ZipDecoder().decodeBytes(kmz!.readAsBytesSync());
        final thumb = zip.files.firstWhere((f) => f.name.startsWith('images/'));
        expect(thumb.content.sublist(0, 2), [0xFF, 0xD8]); // a JPEG
        File('${Directory.systemTemp.path}/sample_track.kmz')
            .writeAsBytesSync(kmz.readAsBytesSync());
      }
      await tester.runAsync(() => svc.disconnect());
      await tester.pumpWidget(const SizedBox());
    });
  }
}
