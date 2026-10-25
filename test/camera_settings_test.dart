import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gopro_gps_cam/gopro/camera.dart';
import 'package:gopro_gps_cam/gopro/packets.dart';
import 'package:gopro_gps_cam/services/camera_settings.dart';
import 'package:gopro_gps_cam/services/capture_service.dart';
import 'package:gopro_gps_cam/ui/camera_settings_page.dart';

import 'support/fake_camera.dart';

Future<(CaptureService, FakeGoProCamera)> _connected() async {
  final svc = CaptureService();
  final cam = FakeGoProCamera('GoPro TEST');
  await svc.connectTo(
      FoundCamera(id: 'X', name: 'GoPro TEST', rssi: -50, create: () => cam));
  return (svc, cam);
}

void main() {
  test('packet assembler joins multi-packet messages', () {
    final payload = [0x12, 0, for (var i = 0; i < 300; i++) i & 0xFF];
    final packets = GoProPacketAssembler.split(payload);
    expect(packets.length, greaterThan(10));
    final a = GoProPacketAssembler();
    List<int>? msg;
    for (final p in packets) {
      msg = a.add(p) ?? msg;
    }
    expect(msg, payload);
    // short single-packet message
    expect(GoProPacketAssembler().add([3, 0x01, 0x00, 0x05]), [1, 0, 5]);
  });

  test('capability TLV keeps repeated ids', () {
    final t = parseTlv([97, 1, 0, 97, 1, 2, 26, 1, 5]);
    expect(t.length, 3);
    expect(t[1].$1, 97);
    expect(t[1].$2, [2]);
  });

  test('lens suggestion picks the matching linear lens', () {
    final lens = surveySettings.firstWhere((d) => d.id == 122);
    expect(lens.suggest(31, null), 32); // Wide 27 MP -> Linear 27 MP
    expect(lens.suggest(101, null), 102); // HERO9/10
    expect(lens.suggest(27, [27, 28, 19]), 28);
    expect(lens.suggest(102, null), 102); // already linear
  });

  test('controller reads, suggests and applies survey settings', () async {
    final (svc, cam) = await _connected();
    final c = CameraSettingsController(svc);
    await c.load();
    expect(c.error, isNull);
    // Controls (175) and old RAW (82) are hidden: this camera lacks 175
    // and has the newer photo output setting.
    expect(c.rows.map((r) => r.def.id), isNot(contains(175)));
    expect(c.rows.map((r) => r.def.id), isNot(contains(82)));
    final byId = {for (final r in c.rows) r.def.id: r};
    expect(byId[122]!.choice, 32);
    expect(byId[122]!.apply, isTrue);
    expect(byId[75]!.ok, isTrue); // ISO min already 100
    expect(byId[75]!.apply, isFalse);
    expect(byId[22]!.ok, isTrue); // auto WB
    await c.apply();
    expect(c.error, isNull);
    expect(cam.settings[122], 32);
    expect(cam.settings[125], 1);
    expect(cam.settings[97], 2);
    expect(cam.settings[26], 5);
    expect(cam.settings[24], 1);
    expect(cam.settings[25], 1);
    expect(c.allOk, isTrue);
    // applied in order: lens before RAW
    final ids = [for (final a in cam.applied) a.$1];
    expect(ids.indexOf(122), lessThan(ids.indexOf(125)));
    expect(svc.state, CamState.ready);
  });

  testWidgets('camera settings page shows current and recommended',
      (tester) async {
    late CaptureService svc;
    await tester.runAsync(() async {
      svc = (await _connected()).$1;
    });
    await tester.binding.setSurfaceSize(const Size(420, 900));
    await tester.pumpWidget(MaterialApp(home: CameraSettingsPage(svc: svc)));
    await tester
        .runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Digital lens'), findsOneWidget);
    expect(find.text('Now: Wide 27 MP'), findsOneWidget);
    expect(find.textContaining('Apply 6 changes'), findsOneWidget);
    if (const bool.fromEnvironment('SHOTS')) {
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('/tmp/claude-0/shots/camera_settings.png'));
    }
    await tester.tap(find.textContaining('Apply 6 changes'));
    await tester
        .runAsync(() => Future.delayed(const Duration(milliseconds: 2000)));
    await tester.pumpAndSettle();
    expect(find.text('Camera matches the survey settings'), findsOneWidget);
    if (const bool.fromEnvironment('SHOTS')) {
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('/tmp/claude-0/shots/camera_settings_done.png'));
    }
  });
}
