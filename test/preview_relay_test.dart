import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gopro_gps_cam/gopro/preview_relay.dart';

/// Simulates a GoPro sending its preview (H.264 in MPEG-TS over UDP) with
/// ffmpeg, and checks a player (ffprobe) can decode it through the relay.
void main() {
  final hasFfmpeg = Process.runSync('which', ['ffmpeg']).exitCode == 0;

  test('relay turns UDP MPEG-TS into a playable HTTP stream', () async {
    final relay = PreviewRelay(udpPort: 18554);
    await relay.start();
    final sender = await Process.start('ffmpeg', [
      '-loglevel',
      'error',
      '-re',
      '-f',
      'lavfi',
      '-i',
      'testsrc=size=640x480:rate=30',
      '-t',
      '8',
      '-c:v',
      'libx264',
      '-g',
      '30',
      '-tune',
      'zerolatency',
      '-f',
      'mpegts',
      'udp://127.0.0.1:18554?pkt_size=1316',
    ]);
    await Future.delayed(const Duration(milliseconds: 500));
    final probe = await Process.run('ffprobe', [
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-show_entries',
      'stream=codec_name,width,height',
      '-of',
      'csv=p=0',
      relay.url,
    ]).timeout(const Duration(seconds: 15));
    sender.kill();
    await relay.stop();
    expect(probe.stdout.toString(), contains('h264,640,480'),
        reason: probe.stderr.toString());
    expect(relay.packets, greaterThan(50));
  }, skip: !hasFfmpeg);
}
