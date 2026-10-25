import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:wifi_iot/wifi_iot.dart';

import '../services/connection_log.dart';

/// A file on the camera's SD card.
class GoProMedia {
  final String folder;
  final String file;
  const GoProMedia(this.folder, this.file);
  String get path => '$folder/$file';
  @override
  bool operator ==(Object other) => other is GoProMedia && other.path == path;
  @override
  int get hashCode => path.hashCode;
}

/// Joins the GoPro's Wi-Fi access point and talks to its HTTP media server.
/// Spec: https://gopro.github.io/OpenGoPro/http
class GoProWifi {
  static const _base = 'http://10.5.5.9:8080';
  http.Client _client = http.Client();

  /// Joins the camera's Wi-Fi and waits until its web server answers.
  ///
  /// Two separate stages, each with its own patience:
  ///  1. Joining the network (Android searches for it; the first search right
  ///     after the camera turns Wi-Fi on can miss it, so we allow 30 s).
  ///  2. Waiting for the camera's web server, which can lag the network by
  ///     several seconds. A good join is NOT torn down just because the server
  ///     is slow (that is what made earlier versions need a 3rd attempt).
  Future<void> join(String ssid, String password,
      {void Function(String)? status, int attempts = 3}) async {
    String lastError = '';
    for (var attempt = 1; attempt <= attempts; attempt++) {
      final suffix = attempt == 1 ? '' : ' (attempt $attempt of $attempts)';
      status?.call('Joining $ssid$suffix…');
      final sw = Stopwatch()..start();
      logConnect('Wi-Fi: requesting network "$ssid" (attempt $attempt)');
      bool ok;
      try {
        ok = await WiFiForIoTPlugin.connect(
          ssid,
          password: password,
          security: NetworkSecurity.WPA,
          joinOnce: true,
          withInternet: false,
          timeoutInSeconds: attempt == 1 ? 30 : 20,
        );
      } catch (e) {
        ok = false;
        lastError = '$e';
      }
      logConnect('Wi-Fi: join ${ok ? 'succeeded' : 'FAILED'} after '
          '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
      if (!ok) {
        lastError =
            lastError.isEmpty ? 'network not found or not accepted' : lastError;
        await leave();
        await Future.delayed(const Duration(seconds: 3));
        continue;
      }
      if (Platform.isAndroid) {
        // The GoPro network has no internet; route our HTTP traffic over it
        // instead of mobile data.
        final bound = await WiFiForIoTPlugin.forceWifiUsage(true);
        logConnect('Wi-Fi: app traffic bound to camera network: $bound');
      }
      // Old keep-alive sockets belong to the previous network; start afresh.
      _client.close();
      _client = http.Client();

      status?.call('Waiting for camera to respond$suffix…');
      sw.reset();
      if (await _waitForHttp(const Duration(seconds: 30))) {
        logConnect('Camera web server answered after '
            '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
        return;
      }
      lastError = 'joined Wi-Fi but the camera did not respond';
      logConnect('Camera web server did not answer within 30 s — rejoining');
      await leave();
      await Future.delayed(const Duration(seconds: 3));
    }
    throw Exception(
        'Could not connect to the camera Wi-Fi "$ssid" ($lastError)');
  }

  /// Polls a tiny endpoint until the camera answers. Returns false on timeout.
  Future<bool> _waitForHttp(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    String? lastErr;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final r = await _client
            .get(Uri.parse('$_base/gopro/version'))
            .timeout(const Duration(seconds: 3));
        if (r.statusCode == 200) return true;
        lastErr = 'HTTP ${r.statusCode}';
      } catch (e) {
        final msg = e.runtimeType.toString();
        if (msg != lastErr) {
          logConnect('Camera web server not ready yet ($msg)');
        }
        lastErr = msg;
      }
      await Future.delayed(const Duration(milliseconds: 700));
    }
    return false;
  }

  /// The preview arrives as an MPEG-TS stream over UDP on this port.
  static const previewPort = 8554;
  static const previewUrl = 'udp://@0.0.0.0:$previewPort';

  /// Starts the camera's live preview stream (sent to this device by UDP).
  Future<void> startPreview() async {
    // Stop first: starting while a stream is already running is refused.
    await stopPreview();
    final r = await _client
        .get(Uri.parse('$_base/gopro/camera/stream/start?port=$previewPort'))
        .timeout(const Duration(seconds: 5));
    if (r.statusCode != 200) {
      throw Exception(
          'Camera refused to start the preview (HTTP ${r.statusCode})');
    }
  }

  Future<void> stopPreview() async {
    try {
      await _client
          .get(Uri.parse('$_base/gopro/camera/stream/stop'))
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// Base URL of the camera's web server.
  static String get baseUrl => _base;
  http.Client get client => _client;

  /// All JPEG photos currently on the SD card.
  Future<Set<GoProMedia>> listPhotos() async {
    final res = await _client
        .get(Uri.parse('$_base/gopro/media/list'))
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) {
      throw Exception('Media list failed (${res.statusCode})');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final out = <GoProMedia>{};
    for (final dir in (json['media'] as List? ?? const [])) {
      final d = dir['d'] as String;
      for (final f in (dir['fs'] as List? ?? const [])) {
        final n = f['n'] as String;
        if (n.toUpperCase().endsWith('.JPG')) out.add(GoProMedia(d, n));
      }
    }
    return out;
  }

  /// Waits for a photo that was not in [before] to appear, then returns it.
  Future<GoProMedia> waitForNewPhoto(Set<GoProMedia> before,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 700));
      try {
        final now = await listPhotos();
        final added = now.difference(before).toList()
          ..sort((a, b) => a.path.compareTo(b.path));
        if (added.isNotEmpty) return added.last;
      } catch (_) {/* camera busy while writing — retry */}
    }
    throw Exception('The new photo did not appear on the camera');
  }

  Future<Uint8List> download(GoProMedia m) async {
    final uri = Uri.parse('$_base/videos/DCIM/${m.folder}/${m.file}');
    // The file can still be finishing writing; retry a few times.
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final res = await _client.get(uri).timeout(const Duration(seconds: 60));
        if (res.statusCode == 200 && res.bodyBytes.length > 4) {
          return res.bodyBytes;
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 1));
    }
    throw Exception('Download of ${m.file} failed');
  }

  Future<void> leave() async {
    try {
      if (Platform.isAndroid) await WiFiForIoTPlugin.forceWifiUsage(false);
    } catch (_) {}
    try {
      await WiFiForIoTPlugin.disconnect();
    } catch (_) {}
  }
}
