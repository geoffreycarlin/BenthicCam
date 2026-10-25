import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../exif/exif_gps_writer.dart';

/// Keeps a live GPS fix so the position at the moment of the shutter press
/// can be captured instantly.
class LocationService {
  Position? _last;
  StreamSubscription<Position>? _sub;

  Position? get last => _last;
  final _updates = StreamController<Position>.broadcast();
  Stream<Position> get updates => _updates.stream;

  /// Use the phone's GPS receiver only (Android LocationManager), never
  /// Wi-Fi / mobile-network positioning. Takes effect on the next [start].
  bool gpsOnly = false;

  bool _background = false;
  bool get background => _background;

  /// Starts (or restarts) the live GPS stream. With [background] = true the
  /// stream runs in an Android foreground service, which shows a notification
  /// ("GPS track is being recorded") and keeps working while the app is not
  /// on screen. Leaving [background] null keeps the current mode.
  Future<void> start({bool? background}) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('Location services are off — please turn on GPS');
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      throw Exception('Location permission is required to tag photos');
    }
    _background = background ?? _background;
    final LocationSettings settings;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 2),
        useMSLAltitude: true, // height above sea level, like a map/GPS unit
        forceLocationManager: gpsOnly,
        foregroundNotificationConfig: _background
            ? const ForegroundNotificationConfig(
                notificationTitle: 'GoPro GPS Cam is recording your GPS track',
                notificationText:
                    'Your route is being saved for the KMZ map. It stops when you close the app.',
                notificationChannelName: 'GPS track recording',
                enableWakeLock: true,
                setOngoing: true,
              )
            : null,
      );
    } else {
      settings = const LocationSettings(
          accuracy: LocationAccuracy.best, distanceFilter: 0);
    }
    // Cancelling first is required for the new settings to take effect.
    await _sub?.cancel();
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen((p) {
      _last = p;
      _updates.add(p);
    });
  }

  /// Tests only: pretend a position arrived from the GPS.
  @visibleForTesting
  void debugEmit(Position p) {
    _last = p;
    _updates.add(p);
  }

  /// Tests only: a fixed position returned by [currentFix].
  @visibleForTesting
  GpsFix? debugFix;

  /// The best fix for "right now": the live fix if fresh, else a new one.
  Future<GpsFix> currentFix(
      {Duration maxAge = const Duration(seconds: 10)}) async {
    if (debugFix != null) return debugFix!;
    var p = _last;
    if (p == null || DateTime.now().difference(p.timestamp) > maxAge) {
      p = await _freshPosition();
      _last = p;
    }
    return GpsFix(
      latitude: p.latitude,
      longitude: p.longitude,
      altitude: p.altitude == 0 ? null : p.altitude,
      horizontalAccuracy: p.accuracy,
      timestamp: p.timestamp,
    );
  }

  Future<Position> _freshPosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 15),
        ),
      );
    } on TimeoutException {
      // No fresh fix (e.g. indoors, or an emulator with no location set):
      // fall back to the most recent position we have.
      final fallback = _last ?? await Geolocator.getLastKnownPosition();
      if (fallback != null) return fallback;
      throw Exception('No GPS fix yet. On an emulator, set a location in '
          'Extended Controls (⋯) > Location.');
    }
  }

  void stop() => _sub?.cancel();

  /// Converts a fix from the stream for other code that shouldn't depend on
  /// geolocator types.
  static GpsFix toFix(Position p) => GpsFix(
        latitude: p.latitude,
        longitude: p.longitude,
        altitude: p.altitude == 0 ? null : p.altitude,
        horizontalAccuracy: p.accuracy,
        timestamp: p.timestamp,
      );
}
