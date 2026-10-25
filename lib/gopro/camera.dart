import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;

import '../services/connection_log.dart';
import 'gopro_ble.dart';
import 'gopro_wifi.dart';

typedef StatusCallback = void Function(String message);

/// A photo fetched from the camera.
class CameraPhoto {
  final String fileName;
  final Uint8List bytes;
  const CameraPhoto(this.fileName, this.bytes);
}

/// What the camera is currently set up to shoot.
class CameraMode {
  final int flatMode; // Open GoPro status 89
  final int
      presetGroup; // Open GoPro status 96 (1000 video, 1001 photo, 1002 time lapse)
  const CameraMode(this.flatMode, this.presetGroup);

  static const _names = {
    4: 'Playback',
    5: 'Setup',
    12: 'Video',
    13: 'Time Lapse Video',
    15: 'Looping Video',
    16: 'Photo',
    17: 'Photo',
    18: 'Night Photo',
    19: 'Burst Photo',
    20: 'Time Lapse Photo',
    21: 'Night Lapse Photo',
    22: 'Live Stream',
    23: 'Live Stream',
    24: 'TimeWarp Video',
    25: 'LiveBurst',
    26: 'Night Lapse Video',
    27: 'Slo-Mo Video',
    29: 'Star Trails',
    30: 'Light Painting',
    31: 'Light Trails',
    32: 'Burst Slo-Mo',
  };
  static const _groupNames = {1000: 'Video', 1001: 'Photo', 1002: 'Time Lapse'};

  /// Single-shot photo modes (one JPEG per shutter press).
  bool get isPhoto {
    if (const {16, 17, 18}.contains(flatMode)) return true;
    if (_names.containsKey(flatMode)) return false;
    return presetGroup == 1001; // idle / unknown flat mode: go by preset group
  }

  String get name =>
      _names[flatMode] ??
      _groupNames[presetGroup] ??
      'an unknown mode ($flatMode)';
}

/// A camera found while scanning, shown in the "choose a GoPro" list.
class FoundCamera {
  final String id;
  final String name;
  final int rssi; // signal strength in dBm (closer to 0 = nearer)
  final GoProCamera Function() create;
  const FoundCamera(
      {required this.id,
      required this.name,
      required this.rssi,
      required this.create});
}

/// Finds nearby cameras.
abstract class CameraScanner {
  /// Live list of cameras found so far (re-emitted as signal strengths change).
  Stream<List<FoundCamera>> get results;
  Stream<bool> get isScanning;
  Future<void> start();
  Future<void> stop();
}

/// Something that can take a photo and hand back the JPEG bytes.
abstract class GoProCamera {
  String get name;
  bool get isConnected;
  Stream<void> get onDisconnected;

  /// [pairing] receives a message while the phone is pairing with the
  /// camera, and null when pairing is over.
  Future<void> connect(StatusCallback status,
      {void Function(String?)? pairing});

  /// Fires the shutter. [beforeShutter] runs immediately before the shutter
  /// fires, so the caller can record the GPS fix at the right moment.
  Future<CameraPhoto> takePhoto(StatusCallback status,
      {required Future<void> Function() beforeShutter});

  /// Live preview: starts the camera's preview stream (sent to this device
  /// over UDP). Returns the camera-side stream URL.
  Future<String> startPreview();
  Future<void> stopPreview();

  /// What the camera is currently set to (photo, video, time lapse…).
  Future<CameraMode> getMode();

  /// Switches the camera to the Photo preset group.
  Future<void> setPhotoMode();

  /// The camera's current clock (camera local time, 1-second resolution).
  Future<DateTime> getCameraTime();

  /// Sets the camera's clock to [localTime] (with the tablet's UTC offset).
  Future<void> setCameraTime(DateTime localTime);

  /// Current value of every setting the camera reports (setting id -> option).
  Future<Map<int, int>> getSettings();

  /// Options the camera currently allows for each setting. May be empty if
  /// the camera does not answer the query.
  Future<Map<int, List<int>>> getSettingOptions();

  /// Sets a setting. Returns 0 when done, 1 when the camera failed, 2 when the
  /// option is not allowed right now.
  Future<int> setSetting(int id, int option);

  Future<void> disconnect();
}

// ---------------------------------------------------------------- real GoPro

class GoProBleScanner implements CameraScanner {
  @override
  Stream<List<FoundCamera>> get results => GoProBle.scanResults.map((list) {
        final cams = [
          for (final r in list)
            FoundCamera(
              id: r.device.remoteId.str,
              name: _nameOf(r.advertisementData.advName, r.device.platformName,
                  r.device.remoteId.str),
              rssi: r.rssi,
              create: () => RealGoProCamera(r.device),
            ),
        ]..sort((a, b) => b.rssi.compareTo(a.rssi)); // nearest first
        return cams;
      });

  static String _nameOf(String adv, String platform, String id) =>
      adv.isNotEmpty ? adv : (platform.isNotEmpty ? platform : 'GoPro ($id)');

  @override
  Stream<bool> get isScanning => GoProBle.isScanning;
  @override
  Future<void> start() => GoProBle.startScan();
  @override
  Future<void> stop() => GoProBle.stopScan();
}

/// A real GoPro (HERO9+): shutter over Bluetooth, download over Wi-Fi.
class RealGoProCamera implements GoProCamera {
  final BluetoothDevice device;
  final _ble = GoProBle();
  final _wifi = GoProWifi();

  RealGoProCamera(this.device);

  @override
  String get name => _ble.name;
  @override
  bool get isConnected => _ble.isConnected;
  @override
  Stream<void> get onDisconnected => _ble.onDisconnected;

  @override
  Future<void> connect(StatusCallback status,
      {void Function(String?)? pairing}) async {
    final label = device.platformName.isEmpty ? 'GoPro' : device.platformName;
    status('Connecting to $label…');
    logConnect('Bluetooth: connecting to $label (${device.remoteId.str})');
    await GoProBle.ensureBluetoothOn();
    await _ble.connect(device, status: status, pairing: pairing);
    logConnect('Bluetooth: connected and paired');

    final creds = await _ble.readWifiCredentials();
    logConnect('Camera Wi-Fi name: ${creds.ssid}');

    status('Turning on camera Wi-Fi…');
    var apWasOn = false;
    try {
      apWasOn = await _ble.isApOn();
    } catch (_) {}
    await _ble.enableWifiAp();
    logConnect('Camera Wi-Fi: on command sent (was already on: $apWasOn)');
    // Wait for the camera to report its access point is up.
    final sw = Stopwatch()..start();
    var apOn = false;
    while (sw.elapsed < const Duration(seconds: 15)) {
      try {
        if (await _ble.isApOn()) {
          apOn = true;
          break;
        }
      } catch (_) {
        break; // status not supported: fall back to a fixed wait
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    logConnect(
        'Camera Wi-Fi: reports on=$apOn after ${sw.elapsedMilliseconds} ms');
    // A freshly started access point needs a few seconds before it is
    // broadcasting reliably enough for Android to find it on the first scan.
    if (!apWasOn) {
      status('Waiting for camera Wi-Fi to start…');
      await Future.delayed(const Duration(seconds: 5));
    }

    await _wifi.join(creds.ssid, creds.password, status: status);
  }

  @override
  Future<String> startPreview() async {
    await _wifi.startPreview();
    return GoProWifi.previewUrl;
  }

  @override
  Future<void> stopPreview() => _wifi.stopPreview();

  @override
  Future<CameraMode> getMode() async {
    final m = await _ble.getMode();
    return CameraMode(m.flatMode, m.presetGroup);
  }

  @override
  Future<void> setPhotoMode() async {
    await _ble.loadPhotoPresetGroup();
    // Give the camera a moment to switch before anyone reads the mode back.
    await Future.delayed(const Duration(milliseconds: 600));
  }

  @override
  Future<CameraPhoto> takePhoto(StatusCallback status,
      {required Future<void> Function() beforeShutter}) async {
    final before = await _wifi.listPhotos();
    await beforeShutter();

    status('Taking photo…');
    await _ble.shutter();

    status('Waiting for photo…');
    final media = await _wifi.waitForNewPhoto(before);

    status('Downloading ${media.file}…');
    return CameraPhoto(media.file, await _wifi.download(media));
  }

  @override
  Future<DateTime> getCameraTime() => _ble.getLocalDateTime();

  @override
  Future<void> setCameraTime(DateTime localTime) =>
      _ble.setLocalDateTime(localTime);

  @override
  Future<Map<int, int>> getSettings() => _ble.getSettingValues();

  @override
  Future<Map<int, List<int>>> getSettingOptions() =>
      _ble.getSettingCapabilities();

  @override
  Future<int> setSetting(int id, int option) => _ble.setSetting(id, option);

  @override
  Future<void> disconnect() async {
    try {
      await _wifi.leave();
    } catch (_) {}
    try {
      await _ble.disconnect();
    } catch (_) {}
  }
}
