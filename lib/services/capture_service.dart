import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../exif/exif_gps_writer.dart';
import '../gopro/camera.dart';
import '../gopro/gopro_ble.dart';
import 'app_settings.dart';
import 'connection_log.dart';
import 'location_service.dart';
import 'kml_builder.dart';
import 'photo_library.dart';
import 'thumbnailer.dart';
import 'track_recorder.dart';

enum CamState { disconnected, connecting, ready, capturing }

/// The camera clock relative to the tablet clock.
class ClockReading {
  /// Camera time minus tablet time (positive = camera is ahead).
  final Duration offset;
  final DateTime readAt;
  const ClockReading(this.offset, this.readAt);

  /// The camera's time right now, extrapolated from the last reading.
  DateTime cameraNow() => DateTime.now().add(offset);
}

/// A photo that has been downloaded and GPS-tagged but not yet saved,
/// waiting for the user to keep or discard it.
class PendingPhoto {
  final String name;
  final String cameraFile; // name on the camera's SD card
  final Uint8List bytes;
  final GpsFix fix;
  final String folder;
  const PendingPhoto(
      this.name, this.cameraFile, this.bytes, this.fix, this.folder);
}

class SavedPhoto {
  final File file;
  final GpsFix? fix;
  SavedPhoto(this.file, this.fix);
}

/// Connect → fire shutter → download → embed the phone's GPS fix →
/// save locally (and optionally to the gallery).
class CaptureService extends ChangeNotifier {
  final location = LocationService();

  GoProCamera? _camera;

  /// Name of the connected camera (e.g. "GoPro 5992").
  String get cameraName => _camera?.name ?? 'GoPro';

  /// The camera's clock is more than a minute away from the tablet's.
  bool get clockIsOff => (clock?.offset.inSeconds.abs() ?? 0) > 60;
  StreamSubscription<void>? _disconnectSub;

  CamState state = CamState.disconnected;
  String status = 'Switch the GoPro on, then tap "Connect to GoPro".';

  /// Preferences (set in [init]; tests may preset them).
  AppSettings? settings;
  bool get saveToGallery => settings?.saveToGallery ?? true;
  bool get reviewBeforeSaving => settings?.reviewBeforeSaving ?? true;

  final List<SavedPhoto> photos = [];
  StreamSubscription? _gpsSub;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void _set(CamState s, String msg) {
    state = s;
    status = msg;
    notifyListeners();
  }

  /// Folders of saved photos (null until [init] has run).
  PhotoLibrary? library;
  List<String> folders = const [PhotoLibrary.defaultFolder];
  String get currentFolder =>
      library?.currentFolder ?? PhotoLibrary.defaultFolder;

  // ------------------------------------------------------------- GPS track

  /// GPS track recorder (KMZ maps). Set in [init]; tests may preset it.
  TrackRecorder? tracks;

  /// UI hook: shown once when recording starts ("GPS data is being saved").
  Future<void> Function()? onTrackStarted;

  /// Set at start-up when a track left running last time was finished.
  File? recoveredTrack;

  Future<TrackRecorder> _tracks() async {
    if (tracks == null) {
      final docs = await getApplicationDocumentsDirectory();
      tracks = TrackRecorder(Directory('${docs.path}/GoProGPS_Tracks'),
          makeThumb: makeThumbnail);
    }
    return tracks!;
  }

  Future<void> setRecordTrack(bool v) async {
    await (await _tracks()).setEnabled(v);
    notifyListeners();
  }

  /// Ends the GPS track: writes the final KMZ and stops background GPS.
  Future<File?> finishTrack() async {
    final t = await _tracks();
    final f = await t.finish();
    try {
      await location.start(background: false); // removes the notification
    } catch (_) {}
    notifyListeners();
    return f;
  }

  Future<void> _addToTrack(File photo, String folder, GpsFix fix) async {
    final t = await _tracks();
    if (!t.enabled) return;
    final first = !t.active;
    if (first) {
      await t.start();
      try {
        await location.start(background: true); // keeps recording off-screen
      } catch (e) {
        debugPrint('Background GPS: $e');
      }
    }
    await t.addPhoto(
        photo,
        folder,
        TrackPoint(fix.latitude, fix.longitude, fix.timestamp.toUtc(),
            alt: fix.altitude, accuracy: fix.horizontalAccuracy));
    if (first) onTrackStarted?.call(); // don't block the camera on the dialog
  }

  Future<PhotoLibrary> _lib() async {
    if (library == null) {
      final docs = await getApplicationDocumentsDirectory();
      library = PhotoLibrary(Directory('${docs.path}/GoProGPS'));
      await library!.load();
    }
    return library!;
  }

  /// Reloads the folder list and the photos shown for the current folder.
  Future<void> reloadPhotos() async {
    final lib = await _lib();
    folders = await lib.folders();
    final files = await lib.photosIn();
    photos
      ..clear()
      ..addAll(files.map((f) => SavedPhoto(f, null)));
    notifyListeners();
  }

  Future<void> createFolder(String name, {bool select = true}) async {
    final lib = await _lib();
    await lib.createFolder(name);
    if (select) await lib.selectFolder(name.trim());
    await reloadPhotos();
  }

  Future<void> selectFolder(String name) async {
    await (await _lib()).selectFolder(name);
    await reloadPhotos();
  }

  Future<void> deleteFolder(String name) async {
    await (await _lib()).deleteFolder(name);
    await reloadPhotos();
  }

  Future<void> movePhoto(SavedPhoto photo, String folder) async {
    await (await _lib()).move(photo.file, folder);
    await reloadPhotos();
  }

  Future<void> init() async {
    if (settings == null) {
      final docs = await getApplicationDocumentsDirectory();
      settings = AppSettings(File('${docs.path}/GoProGPS_settings.json'));
      await settings!.load();
    }
    settings!.addListener(notifyListeners);
    location.gpsOnly = settings!.gpsOnly;
    await reloadPhotos();

    // A track left running when the app was last closed is finished now.
    try {
      final t = await _tracks();
      recoveredTrack = await t.init();
      t.addListener(notifyListeners);
    } catch (e) {
      debugPrint('Track recorder: $e');
    }

    // Start GPS early so a fix is ready by the time you take a photo.
    try {
      await location.start();
      _gpsSub ??= location.updates.listen((p) {
        final t = tracks;
        if (t != null && t.active) {
          final f = LocationService.toFix(p);
          t.addPoint(TrackPoint(f.latitude, f.longitude, f.timestamp.toUtc(),
              alt: f.altitude, accuracy: f.horizontalAccuracy));
        }
        notifyListeners();
      });
    } catch (e) {
      status = 'GPS: ${_msg(e)}';
      notifyListeners();
    }
  }

  // Permissions are requested by the plugins themselves when first needed:
  // geolocator (location), flutter_blue_plus (Bluetooth scan/connect) and
  // gal (photo library).

  /// Shown while the phone is pairing with the camera (null otherwise).
  String? pairingMessage;

  /// UI hook: the phone isn't paired with [camera] and couldn't connect —
  /// show the user how to pair it.
  void Function(FoundCamera camera)? onNeedsPairing;

  /// Switches between GPS-only and normal (fused) positioning.
  Future<void> setGpsOnly(bool v) async {
    await settings?.update((s) => s.gpsOnly = v);
    location.gpsOnly = v;
    try {
      await location.start();
    } catch (e) {
      status = 'GPS: ${_msg(e)}';
    }
    notifyListeners();
  }

  /// Finds nearby GoPros for the "choose a GoPro" list. Tests replace this.
  CameraScanner Function() scannerFactory = GoProBleScanner.new;
  CameraScanner newScanner() => scannerFactory();

  Future<void> connectTo(FoundCamera found) async {
    try {
      _set(CamState.connecting, 'Starting GPS…');
      try {
        await location.start();
      } catch (e) {
        debugPrint('GPS: $e'); // shown on screen; not fatal for connecting
      }

      ConnectionLog.instance.begin(
          'Connecting to ${found.name} (${found.id}, ${found.rssi} dBm)');
      final cam = found.create();
      _camera = cam;
      await cam.connect((m) => _set(CamState.connecting, m), pairing: (m) {
        pairingMessage = m;
        notifyListeners();
      });

      _disconnectSub?.cancel();
      _disconnectSub = cam.onDisconnected.listen((_) {
        if (state != CamState.disconnected) {
          clock = null;
          _set(CamState.disconnected, 'Camera disconnected');
        }
      });
      logConnect('Connected — ready');
      _set(CamState.ready, 'Ready — connected to ${cam.name}');
      await ensurePhotoMode();
      await refreshCameraClock();
    } catch (e) {
      logConnect('FAILED: ${_msg(e)}');
      pairingMessage = null;
      _set(CamState.disconnected, 'Error: ${_msg(e)}');
      await _camera?.disconnect();
      if (e is NotPairedException) onNeedsPairing?.call(found);
      _camera = null;
    }
  }

  // ------------------------------------------------------------ camera clock

  /// Last reading of the camera clock, or null if not read yet.
  ClockReading? clock;
  bool clockBusy = false;
  String? clockError;

  /// Reads the camera's clock and works out how far it is from the tablet's.
  Future<void> refreshCameraClock() async {
    final cam = _camera;
    if (cam == null || clockBusy) return;
    clockBusy = true;
    clockError = null;
    notifyListeners();
    try {
      final sent = DateTime.now();
      final camTime = await cam.getCameraTime();
      final received = DateTime.now();
      // Best estimate of the tablet time at the moment the camera answered:
      // halfway through the round trip.
      final tabletAt = sent.add(received.difference(sent) ~/ 2);
      clock = ClockReading(camTime.difference(tabletAt), received);
    } catch (e) {
      clockError = 'Could not read camera time: ${_msg(e)}';
    } finally {
      clockBusy = false;
      notifyListeners();
    }
  }

  /// Sets the camera's clock to the tablet's time, then reads it back.
  Future<void> setCameraClockFromTablet() async {
    final cam = _camera;
    if (cam == null || clockBusy) return;
    clockBusy = true;
    clockError = null;
    notifyListeners();
    try {
      // The camera only takes whole seconds: wait for the start of the next
      // second so the camera is set as accurately as possible.
      final now = DateTime.now();
      await Future.delayed(Duration(milliseconds: 1000 - now.millisecond));
      await cam.setCameraTime(DateTime.now());
    } catch (e) {
      clockError = 'Could not set camera time: ${_msg(e)}';
    } finally {
      clockBusy = false;
    }
    await refreshCameraClock();
  }

  // ------------------------------------------------------------- live view

  /// Starts the camera preview; returns the camera-side stream URL.
  Future<String> startPreview() async {
    final cam = _camera;
    if (cam == null) throw Exception('Not connected');
    return cam.startPreview();
  }

  Future<void> stopPreview() async => _camera?.stopPreview();

  // -------------------------------------------------------- camera settings

  /// Runs [job] on the connected camera while showing it as busy (so no
  /// photo is taken half-way through changing settings).
  Future<T> useCamera<T>(
      String busyMessage, Future<T> Function(GoProCamera cam) job) async {
    final cam = _camera;
    if (cam == null || state != CamState.ready) {
      throw Exception('The camera is not connected and ready');
    }
    _set(CamState.capturing, busyMessage);
    try {
      return await job(cam);
    } finally {
      if (_camera == cam && state == CamState.capturing) {
        _set(CamState.ready, 'Ready — connected to ${cam.name}');
      }
    }
  }

  // ------------------------------------------------------------ camera mode

  /// Set by the UI: shows "Camera is currently in X — press OK to change to
  /// Photo" and returns true if the user pressed OK.
  Future<bool> Function(String currentMode)? confirmPhotoMode;

  /// Last mode read from the camera.
  CameraMode? mode;

  /// Checks the camera is in a single-photo mode; if not, asks the user and
  /// switches it. Returns true when the camera is (now) in Photo mode.
  Future<bool> ensurePhotoMode() async {
    final cam = _camera;
    if (cam == null) return false;
    try {
      mode = await cam.getMode();
    } catch (e) {
      debugPrint('Could not read camera mode: $e');
      mode = null;
      return true; // can't tell (older firmware): let the shot go ahead
    }
    notifyListeners();
    if (mode!.isPhoto) return true;

    final ok =
        await (confirmPhotoMode?.call(mode!.name) ?? Future.value(false));
    if (!ok) {
      _set(state,
          'Camera is in ${mode!.name} mode — switch it to Photo to take photos');
      return false;
    }
    try {
      _set(state, 'Switching camera to Photo mode…');
      await cam.setPhotoMode();
      mode = await cam.getMode();
      if (!mode!.isPhoto) {
        _set(state, 'Camera did not switch to Photo (still ${mode!.name})');
        return false;
      }
      _set(state, 'Camera is in Photo mode — ready');
      return true;
    } catch (e) {
      _set(state, 'Could not switch to Photo mode: ${_msg(e)}');
      return false;
    }
  }

  /// UI hook: shows the photo full screen; returns true to keep it.
  Future<bool> Function(PendingPhoto photo)? reviewPhoto;

  Future<void> capture() async {
    final cam = _camera;
    if (state != CamState.ready || cam == null) return;
    // The mode may have been changed on the camera itself since connecting.
    if (!await ensurePhotoMode()) return;
    try {
      _set(CamState.capturing, 'Getting GPS fix…');
      GpsFix? shutterFix;
      final photo = await cam.takePhoto(
        (m) => _set(CamState.capturing, m),
        beforeShutter: () async {
          shutterFix = await location.currentFix();
        },
      );
      final fix = shutterFix!;

      _set(CamState.capturing, 'Embedding GPS…');
      final tagged = ExifGpsWriter.inject(photo.bytes, fix);

      final stamp = fix.timestamp
          .toLocal()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final name = '${photo.fileName.split('.').first}_$stamp.jpg';
      final lib = await _lib();
      final folder = lib.currentFolder;

      if (reviewBeforeSaving && reviewPhoto != null) {
        _set(CamState.capturing, 'Is this photo OK?');
        final keep = await reviewPhoto!(
            PendingPhoto(name, photo.fileName, tagged, fix, folder));
        if (!keep) {
          _set(CamState.ready,
              'Photo not kept (${photo.fileName} is still on the camera\'s SD card)');
          return;
        }
      }

      final dir = lib.currentDir;
      if (!await dir.exists()) await dir.create(recursive: true);
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(tagged, flush: true);

      if (saveToGallery) {
        try {
          if (!await Gal.hasAccess(toAlbum: true)) {
            await Gal.requestAccess(toAlbum: true);
          }
          await Gal.putImage(file.path, album: lib.galleryAlbumFor(folder));
        } catch (e) {
          debugPrint('Gallery save failed: $e');
        }
      }

      photos.insert(0, SavedPhoto(file, fix));
      try {
        await _addToTrack(file, folder, fix);
      } catch (e) {
        debugPrint('Track: $e');
      }
      // Read the GPS back from the saved file to confirm it is really there.
      final stored = ExifGpsWriter.read(await file.readAsBytes());
      _set(
          CamState.ready,
          stored == null
              ? 'Saved $name to "$folder" — WARNING: GPS could not be verified in the file'
              : 'Saved $name to "$folder" — GPS embedded ✓ $stored');
    } catch (e) {
      _set(cam.isConnected ? CamState.ready : CamState.disconnected,
          'Capture failed: ${_msg(e)}');
    }
  }

  Future<void> disconnect() async {
    await _camera?.disconnect();
    _camera = null;
    clock = null;
    mode = null;
    _set(CamState.disconnected, 'Disconnected');
  }

  String _msg(Object e) => e.toString().replaceFirst('Exception: ', '');

  @override
  void dispose() {
    _disposed = true;
    _gpsSub?.cancel();
    _disconnectSub?.cancel();
    location.stop();
    _camera?.disconnect();
    super.dispose();
  }
}
