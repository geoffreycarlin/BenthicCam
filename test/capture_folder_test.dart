import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_camera.dart';
import 'package:gopro_gps_cam/exif/exif_gps_writer.dart';
import 'package:gopro_gps_cam/gopro/camera.dart';
import 'package:gopro_gps_cam/services/capture_service.dart';
import 'package:gopro_gps_cam/services/photo_library.dart';
import 'package:gopro_gps_cam/ui/folders.dart';

void main() {
  testWidgets('shutter saves a GPS-tagged photo into the chosen folder',
      (tester) async {
    final tmp = Directory.systemTemp.createTempSync('lv');
    final svc = CaptureService()
      ..library = PhotoLibrary(Directory('${tmp.path}/GoProGPS'))
      ..location.debugFix = GpsFix(
          latitude: -28.1747,
          longitude: 153.5408,
          horizontalAccuracy: 4,
          timestamp: DateTime.utc(2026, 10, 19, 1, 2, 3));
    await tester.runAsync(() async {
      await svc.library!.load();
      await svc.createFolder('Bridge inspection');
      await svc.connectTo(FoundCamera(
          id: 'x',
          name: 'Sim',
          rssi: -50,
          create: () => FakeGoProCamera('Sim')));
    });
    expect(svc.state, CamState.ready, reason: svc.status);

    // Same action as the shutter buttons (run with real timers).
    await tester.runAsync(() => svc.capture());
    await tester.pump();
    expect(svc.status, contains('Saved'));
    expect(svc.status, contains('Bridge inspection'));
    final saved = svc.photos.first.file;
    expect(saved.path, contains('/GoProGPS/Bridge inspection/'));
    final gps = ExifGpsWriter.read(saved.readAsBytesSync())!;
    expect(gps.latitude, closeTo(-28.1747, 1e-6));

    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: FolderChip(svc: svc))));
    expect(find.text('Bridge inspection'), findsOneWidget);

    await tester.runAsync(() => svc.disconnect());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    tmp.deleteSync(recursive: true);
  });
}
