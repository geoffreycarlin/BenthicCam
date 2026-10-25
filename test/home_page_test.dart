import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:gopro_gps_cam/exif/exif_gps_writer.dart';
import 'package:gopro_gps_cam/gopro/camera.dart';
import 'package:gopro_gps_cam/services/app_settings.dart';
import 'package:gopro_gps_cam/services/capture_service.dart';
import 'package:gopro_gps_cam/services/photo_library.dart';
import 'package:gopro_gps_cam/services/thumbnailer.dart';
import 'package:gopro_gps_cam/services/track_recorder.dart';
import 'package:gopro_gps_cam/ui/home_page.dart';

import 'support/fake_camera.dart';

/// Renders the main screen (phone + tablet) and checks the key controls.
/// Set SHOTS=1 to also write PNG screenshots to /tmp/claude-0/shots.
void main() {
  final shots = Platform.environment['SHOTS'] == '1';

  Future<void> loadFonts() async {
    Future<ByteData> f(String p) async =>
        ByteData.sublistView(File(p).readAsBytesSync());
    const dj = '/usr/share/fonts/truetype/dejavu';
    if (!File('$dj/DejaVuSans.ttf').existsSync()) return;
    await (FontLoader('Roboto')
          ..addFont(f('$dj/DejaVuSans.ttf'))
          ..addFont(f('$dj/DejaVuSans-Bold.ttf')))
        .load();
    final icons = '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}'
        '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
    if (File(icons).existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(f(icons))).load();
    }
  }

  Future<CaptureService> makeService(Directory tmp) async {
    final svc = CaptureService()
      ..settings = AppSettings(File('${tmp.path}/settings.json'))
      ..library = PhotoLibrary(Directory('${tmp.path}/GoProGPS'))
      ..tracks = TrackRecorder(Directory('${tmp.path}/tracks'),
          makeThumb: makeThumbnail)
      ..scannerFactory = FakeScanner.new
      ..location.debugFix = GpsFix(
          latitude: -28.1747,
          longitude: 153.5408,
          horizontalAccuracy: 4,
          timestamp: DateTime.now());
    await svc.library!.load();
    await svc.tracks!.init();
    await svc.reloadPhotos();
    svc.location.debugEmit(Position(
        longitude: 153.5408,
        latitude: -28.1747,
        timestamp: DateTime.now(),
        accuracy: 4,
        altitude: 12,
        altitudeAccuracy: 3,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0));
    return svc;
  }

  Widget app(CaptureService svc) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            colorSchemeSeed: const Color(0xFF0B6FB8),
            useMaterial3: true,
            fontFamily: 'Roboto'),
        home: HomePage(service: svc),
      );

  testWidgets('main screen: phone and tablet layouts', (tester) async {
    await tester.runAsync(loadFonts);
    final tmp = Directory.systemTemp.createTempSync('home');
    // The map's tile cache asks path_provider for a folder.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => tmp.path);
    final svc = (await tester.runAsync(() => makeService(tmp)))!;
    tester.view.devicePixelRatio = 1.0;

    // ---- phone, not connected
    tester.view.physicalSize = const Size(412, 860);
    await tester.pumpWidget(app(svc));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Connect to GoPro'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('GPS ±4 m'), findsOneWidget);
    expect(find.text('Simulated GoPro'), findsNothing);
    if (shots) {
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('/tmp/claude-0/shots/home_phone_idle.png'));
    }

    // ---- connect (camera in Video mode, clock 9 years out) and take 2 photos
    svc.confirmPhotoMode =
        (_) async => false; // leave it in video for the warning
    await tester.runAsync(() async {
      await svc.tracks!.setEnabled(true);
      await svc.connectTo(FoundCamera(
          id: 'F4:33:72:DA:5C:0E',
          name: 'GoPro 5992',
          rssi: -50,
          create: () => FakeGoProCamera('GoPro 5992',
              clockOffset: -const Duration(days: 3567),
              mode: const CameraMode(17, 1001))));
      svc.reviewPhoto = null;
      await svc.capture();
      await svc.capture();
      (svc.tracks!).distance = 840;
    });
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Take photo'), findsOneWidget);
    expect(find.text('Live view'), findsOneWidget);
    expect(find.text('GoPro 5992'), findsOneWidget);
    expect(find.textContaining('clock is off'), findsOneWidget);
    expect(find.textContaining('REC'), findsOneWidget);
    if (shots) {
      // Close the "recording started" dialog, let thumbnails decode, repaint.
      await tester.tap(find.text('OK'));
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 15; i++) {
        await tester
            .runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
        await tester.pump();
      }
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('/tmp/claude-0/shots/home_phone_connected.png'));

      // ---- tablet landscape
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('/tmp/claude-0/shots/home_tablet.png'));
    }
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pump();
    expect(find.text('Take photo'), findsOneWidget);

    await tester.runAsync(() => svc.disconnect());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    tmp.deleteSync(recursive: true);
  });
}
