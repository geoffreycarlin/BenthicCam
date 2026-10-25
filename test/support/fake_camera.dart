// Test-only stand-ins for a real GoPro (the app itself no longer has a
// simulated camera).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:gopro_gps_cam/gopro/camera.dart';

// ----------------------------------------------------------- simulated GoPro

/// Pretend scanner for the emulator: "finds" two simulated GoPros.
class FakeScanner implements CameraScanner {
  final _results = StreamController<List<FoundCamera>>.broadcast();
  final _scanning = StreamController<bool>.broadcast();
  Timer? _timer;

  @override
  Stream<List<FoundCamera>> get results => _results.stream;
  @override
  Stream<bool> get isScanning => _scanning.stream;

  @override
  Future<void> start() async {
    _scanning.add(true);
    var tick = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 700), (t) {
      tick++;
      _results.add([
        FoundCamera(
            id: 'SIM-A',
            name: 'GoPro 1234 (simulated)',
            rssi: -55 - tick % 4,
            // Camera clock 9 years slow, like a GoPro whose clock was never set.
            create: () => FakeGoProCamera('GoPro 1234 (simulated)',
                clockOffset: -const Duration(days: 3567, hours: 4, minutes: 12),
                mode: const CameraMode(12, 1000))), // starts in Video mode
        if (tick > 1)
          FoundCamera(
              id: 'SIM-B',
              name: 'GoPro 5678 (simulated)',
              rssi: -78 + tick % 3,
              create: () => FakeGoProCamera('GoPro 5678 (simulated)',
                  clockOffset: const Duration(seconds: 47))),
      ]);
      if (tick >= 15) stop();
    });
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _scanning.add(false);
  }
}

/// A pretend GoPro for the Android emulator (which has no Bluetooth).
/// Returns a bundled sample JPEG so the rest of the flow — GPS fix, EXIF
/// tagging, saving — runs exactly as it would with a real camera.
class FakeGoProCamera implements GoProCamera {
  @override
  final String name;
  Duration clockOffset;
  bool _connected = false;
  int _counter = 1;
  final _disconnected = StreamController<void>.broadcast();

  CameraMode mode;

  FakeGoProCamera(this.name,
      {this.clockOffset = Duration.zero,
      this.mode = const CameraMode(17, 1001)});

  @override
  Future<String> startPreview() async => 'http://127.0.0.1:1/none';

  @override
  Future<void> stopPreview() async {}

  @override
  Future<CameraMode> getMode() async {
    await Future.delayed(const Duration(milliseconds: 100));
    return mode;
  }

  @override
  Future<void> setPhotoMode() async {
    await Future.delayed(const Duration(milliseconds: 400));
    mode = const CameraMode(17, 1001);
  }

  @override
  bool get isConnected => _connected;
  @override
  Stream<void> get onDisconnected => _disconnected.stream;

  @override
  Future<void> connect(StatusCallback status,
      {void Function(String?)? pairing}) async {
    status('Connecting to $name…');
    await Future.delayed(const Duration(milliseconds: 800));
    _connected = true;
  }

  @override
  Future<CameraPhoto> takePhoto(StatusCallback status,
      {required Future<void> Function() beforeShutter}) async {
    await beforeShutter();
    status('Taking photo (simulated)…');
    await Future.delayed(const Duration(milliseconds: 500));
    final data = Uint8List.fromList(
        File('test/fixtures/sample_gopro.jpg').readAsBytesSync());
    final file = 'GOPR${(_counter++).toString().padLeft(4, '0')}.JPG';
    status('Downloading $file (simulated)…');
    await Future.delayed(const Duration(milliseconds: 500));
    return CameraPhoto(file, data);
  }

  @override
  Future<DateTime> getCameraTime() async {
    await Future.delayed(const Duration(milliseconds: 150));
    final t = DateTime.now().add(clockOffset);
    return DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second);
  }

  @override
  Future<void> setCameraTime(DateTime localTime) async {
    await Future.delayed(const Duration(milliseconds: 150));
    clockOffset = localTime.difference(DateTime.now());
  }

  /// Like a HERO11 out of the box: Wide lens, standard JPEG, auto shutter.
  final Map<int, int> settings = {
    21: 1,
    122: 31,
    125: 0,
    97: 0,
    26: 4,
    75: 3,
    24: 0,
    22: 0,
    25: 0,
    2: 1,
  };
  final Map<int, List<int>> options = {
    21: [0, 1],
    122: [19, 31, 32, 100],
    125: [0, 1, 3],
    97: [0, 1, 2, 3, 4, 5],
    26: [0, 1, 2, 3, 4, 5, 6, 7, 8],
    75: [0, 1, 2, 3],
    24: [0, 1, 2, 3],
    22: [0, 2, 5, 7, 3, 4],
    25: [0, 1, 2],
  };
  final List<(int, int)> applied = [];

  @override
  Future<Map<int, int>> getSettings() async => Map.of(settings);

  @override
  Future<Map<int, List<int>>> getSettingOptions() async => options;

  @override
  Future<int> setSetting(int id, int option) async {
    if (!(options[id]?.contains(option) ?? false)) return 2;
    settings[id] = option;
    applied.add((id, option));
    return 0;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _disconnected.add(null);
  }
}
