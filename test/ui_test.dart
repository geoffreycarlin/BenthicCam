import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_camera.dart';
import 'package:gopro_gps_cam/gopro/camera.dart';
import 'package:gopro_gps_cam/gopro/gopro_ble.dart';
import 'package:gopro_gps_cam/services/capture_service.dart';
import 'package:gopro_gps_cam/ui/camera_picker.dart';
import 'package:gopro_gps_cam/ui/clock_card.dart';

void main() {
  test('clock difference wording', () {
    expect(describeClockOffset(const Duration(milliseconds: 400)),
        'In sync (within 1 second)');
    expect(describeClockOffset(const Duration(seconds: 47)),
        'Camera is 47 s ahead of the tablet');
    expect(describeClockOffset(-const Duration(minutes: 3, seconds: 5)),
        'Camera is 3 min 5 s behind the tablet');
    expect(
        describeClockOffset(-const Duration(days: 3567, hours: 4, minutes: 12)),
        'Camera is 9 y 282 d 4 h 12 min behind the tablet');
  });

  testWidgets('picker lists nearby cameras and returns the one tapped',
      (tester) async {
    FoundCamera? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              picked = await showCameraPicker(context, FakeScanner()),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Choose a GoPro'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.text('GoPro 1234 (simulated)'), findsOneWidget);
    expect(find.text('GoPro 5678 (simulated)'), findsOneWidget);
    await tester.tap(find.text('GoPro 5678 (simulated)'));
    await tester.pumpAndSettle();
    expect(picked?.id, 'SIM-B');
  });

  testWidgets('clock card shows difference and syncs camera from tablet',
      (tester) async {
    final svc = CaptureService();
    final found = FoundCamera(
      id: 'SIM-A',
      name: 'Sim',
      rssi: -50,
      create: () => FakeGoProCamera('Sim',
          clockOffset: -const Duration(days: 3567, hours: 4)),
    );
    await tester.runAsync(() => svc.connectTo(found));
    expect(svc.state, CamState.ready, reason: svc.status);
    expect(svc.clock, isNotNull);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: ListenableBuilder(
              listenable: svc,
              builder: (context, child) => ClockCard(svc: svc))),
    ));
    expect(find.textContaining('behind the tablet'), findsOneWidget);
    expect(find.textContaining('9 y'), findsOneWidget);

    await tester.runAsync(() => svc.setCameraClockFromTablet());
    await tester.pump();
    expect(find.text('In sync (within 1 second)'), findsOneWidget);
    await tester.runAsync(() => svc.disconnect());
    await tester.pumpWidget(const SizedBox()); // stop the ticker
  });

  test('status query response parsing and mode names', () {
    // [status 0, id 89 len 1 = 12 (video), id 96 len 4 = 1000 (video group)]
    final st =
        GoProBle.parseStatusData([0, 89, 1, 12, 96, 4, 0, 0, 0x03, 0xE8]);
    expect(GoProBle.uintOf(st[89]), 12);
    expect(GoProBle.uintOf(st[96]), 1000);
    final video = CameraMode(GoProBle.uintOf(st[89]), GoProBle.uintOf(st[96]));
    expect(video.isPhoto, isFalse);
    expect(video.name, 'Video');
    expect(const CameraMode(17, 1001).isPhoto, isTrue);
    expect(const CameraMode(19, 1001).isPhoto, isFalse); // burst = many files
    expect(const CameraMode(28, 1001).isPhoto, isTrue); // idle, photo group
    expect(const CameraMode(20, 1002).name, 'Time Lapse Photo');
  });

  for (final pressOk in [true, false]) {
    testWidgets(
        'camera in Video mode: ${pressOk ? 'OK switches to Photo' : 'Cancel leaves it'}',
        (tester) async {
      final svc = CaptureService();
      final asked = <String>[];
      svc.confirmPhotoMode = (m) async {
        asked.add(m);
        return pressOk;
      };
      final cam = FakeGoProCamera('Sim', mode: const CameraMode(12, 1000));
      await tester.runAsync(() => svc.connectTo(
          FoundCamera(id: 'x', name: 'Sim', rssi: -50, create: () => cam)));
      expect(asked, ['Video']);
      expect(svc.mode!.isPhoto, pressOk);
      expect(cam.mode.isPhoto, pressOk);
      if (!pressOk) expect(svc.status, contains('switch it to Photo'));
      await tester.runAsync(() => svc.disconnect());
    });
  }
}
