import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../gopro/camera.dart';
import '../gopro/gopro_ble.dart';
import '../services/capture_service.dart';
import '../services/kml_builder.dart';
import 'camera_picker.dart';
import 'camera_sheet.dart';
import 'folders.dart';
import 'live_view_page.dart';
import 'photo_page.dart';
import 'position_map.dart';
import 'review_page.dart';
import 'settings_page.dart';
import 'tracks_page.dart';

/// Main screen.
///
/// Phone (portrait):            Tablet / landscape:
///  ┌ camera bar ─────────┐      ┌ camera bar ──────┬───────────────┐
///  │                     │      │                  │ status        │
///  │        MAP          │      │       MAP        │ [Take photo]  │
///  │                     │      │                  │ [Live view]   │
///  ├ status ─────────────┤      │                  │ folder, track │
///  │ [Live view][ PHOTO ]│      │                  │ recent photos │
///  │ folder · track      │      └──────────────────┴───────────────┘
///  │ recent photos ▸▸▸   │
///  └─────────────────────┘
class HomePage extends StatefulWidget {
  final CaptureService? service; // tests may pass one in
  const HomePage({super.key, this.service});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final CaptureService svc = widget.service ?? CaptureService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    svc.confirmPhotoMode = _confirmPhotoMode;
    svc.reviewPhoto = (photo) =>
        mounted ? ReviewPage.show(context, photo) : Future.value(true);
    svc.onTrackStarted = _showTrackStarted;
    svc.onNeedsPairing = _showPairingHelp;
    if (widget.service == null) {
      svc.init().then((_) {
        final f = svc.recoveredTrack;
        if (f != null && mounted) {
          _showTrackSaved(f, title: 'GPS track from last time saved');
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.service == null) svc.dispose();
    super.dispose();
  }

  /// Android is closing the app: save the track (best effort; if the app is
  /// killed first, the track is completed on the next launch instead).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached && (svc.tracks?.active ?? false)) {
      svc.finishTrack();
    }
  }

  /// The phone couldn't connect because it isn't paired with the camera.
  Future<void> _showPairingHelp(FoundCamera cam) async {
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.bluetooth_disabled),
        title: Text('Pair the phone with ${cam.name}'),
        content: const SingleChildScrollView(
          child: Text(
              'This phone only connects to cameras it is paired with.\n\n'
              '1. On the GoPro: Preferences → Wireless Connections → '
              'Connect Device → GoPro Quik (pairing mode).\n'
              '2. Tap "Open Bluetooth settings", tap the GoPro in the list of '
              'available devices and accept "Pair".\n'
              '3. Come back here and tap "Try again".\n\n'
              'If the GoPro is already in the list but still won\'t connect, '
              'tap ⚙ next to it, choose "Forget"/"Unpair", then pair again.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'settings'),
              child: const Text('Open Bluetooth settings')),
          FilledButton(
              onPressed: () => Navigator.pop(context, 'retry'),
              child: const Text('Try again')),
        ],
      ),
    );
    if (action == 'settings') {
      await GoProBle.openBluetoothSettings();
      if (mounted) await _showPairingHelp(cam); // offer "Try again" on return
    } else if (action == 'retry') {
      await svc.connectTo(cam);
    }
  }

  Future<void> _showTrackStarted() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.route, color: Colors.red),
        title: const Text('GPS track recording started'),
        content: const Text(
            'Your GPS position is now being saved to record your route.\n\n'
            '• It keeps recording while the app is in the background '
            '(Android shows a notification).\n'
            '• It stops when you close the app (Back on the main screen) '
            'or tap "Finish track".\n'
            '• A KMZ map file of the route, with a thumbnail of each photo '
            'where it was taken, is saved and can be shared from "GPS tracks".'),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _showTrackSaved(File kmz,
      {String title = 'GPS track saved'}) async {
    if (!mounted) return;
    final share = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.map),
        title: Text(title),
        content: Text('Saved as ${kmz.uri.pathSegments.last}.\n\n'
            'Open it in Google Earth or Google My Maps to see the route and photos.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Close')),
          FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.share),
              label: const Text('Share')),
        ],
      ),
    );
    if (share == true) await shareKmz(kmz);
  }

  Future<void> _finishTrack() async {
    final f = await svc.finishTrack();
    if (f != null) await _showTrackSaved(f);
  }

  /// Back on the main screen closes the app; finish the track first.
  Future<void> _onBack() async {
    if (svc.tracks?.active ?? false) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Close the app?'),
          content: const Text(
              'This stops recording the GPS track and saves the KMZ map.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep recording')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Finish & close')),
          ],
        ),
      );
      if (ok != true) return;
      final f = await svc.finishTrack();
      if (f != null) await _showTrackSaved(f);
    }
    await SystemNavigator.pop();
  }

  /// "Camera currently is in Video mode — press OK to change to Photo."
  Future<bool> _confirmPhotoMode(String currentMode) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.photo_camera),
        title: const Text('Camera is not in Photo mode'),
        content: Text('Camera currently is in $currentMode mode.\n\n'
            'Press OK to change it to Photo.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('OK')),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Shows the list of nearby GoPros and connects to the one picked.
  Future<void> _chooseAndConnect() async {
    final chosen = await showCameraPicker(context, svc.newScanner());
    if (chosen != null) await svc.connectTo(chosen);
  }

  void _openLiveView() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => LiveViewPage(svc: svc)));

  // ------------------------------------------------------------------ layout

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _onBack();
        },
        child: Scaffold(
          appBar: AppBar(
            title: const Text('GoPro GPS Cam'),
            actions: [
              IconButton(
                tooltip: 'All photos',
                icon: const Icon(Icons.photo_library_outlined),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => GalleryPage(svc: svc))),
              ),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => SettingsPage(svc: svc))),
              ),
            ],
          ),
          body: SafeArea(
            child: LayoutBuilder(builder: (context, c) {
              final wide = c.maxWidth >= 840 || c.maxWidth > c.maxHeight * 1.15;
              final mapArea = Column(children: [
                if (svc.pairingMessage != null)
                  _PairingCard(message: svc.pairingMessage!),
                _CameraBar(svc: svc),
                Expanded(
                    child: _MapWithTrack(svc: svc, onFinish: _finishTrack)),
              ]);
              final controls = _Controls(
                svc: svc,
                wide: wide,
                onConnect: _chooseAndConnect,
                onLiveView: _openLiveView,
              );
              if (wide) {
                return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: mapArea),
                      const VerticalDivider(width: 1),
                      SizedBox(
                          width: c.maxWidth >= 1100 ? 420 : 360,
                          child: controls),
                    ]);
              }
              return Column(children: [
                Expanded(child: mapArea),
                const Divider(height: 1),
                controls,
              ]);
            }),
          ),
        ),
      ),
    );
  }
}

/// Top strip: camera status at a glance; tap for the camera sheet.
class _CameraBar extends StatelessWidget {
  final CaptureService svc;
  const _CameraBar({required this.svc});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final connected =
        svc.state == CamState.ready || svc.state == CamState.capturing;
    final connecting = svc.state == CamState.connecting;
    final warnings = <String>[
      if (connected && svc.mode != null && !svc.mode!.isPhoto)
        '${svc.mode!.name} mode',
      if (connected && svc.clockIsOff) 'clock is off',
    ];
    final String subtitle;
    if (connecting) {
      subtitle = svc.status;
    } else if (connected) {
      subtitle = warnings.isEmpty
          ? 'Photo mode · clock OK'
          : 'Check: ${warnings.join(', ')}';
    } else {
      subtitle = 'Not connected';
    }
    return Material(
      color: warnings.isNotEmpty
          ? Colors.orange.withValues(alpha: 0.15)
          : scheme.surfaceContainer,
      child: InkWell(
        onTap: () => showCameraSheet(context, svc),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(children: [
            Icon(
              connected ? Icons.videocam : Icons.videocam_off_outlined,
              color:
                  connected ? Colors.green.shade700 : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(connected || connecting ? svc.cameraName : 'Camera',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: warnings.isNotEmpty
                                ? Colors.orange.shade900
                                : scheme.onSurfaceVariant)),
                  ]),
            ),
            if (connecting)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            if (warnings.isNotEmpty)
              Icon(Icons.warning_amber, color: Colors.orange.shade800),
            const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}

/// The map, with a "recording" badge when a GPS track is running.
class _MapWithTrack extends StatelessWidget {
  final CaptureService svc;
  final VoidCallback onFinish;
  const _MapWithTrack({required this.svc, required this.onFinish});

  @override
  Widget build(BuildContext context) {
    final t = svc.tracks;
    return Stack(children: [
      Positioned.fill(child: PositionMap(svc: svc)),
      if (t != null && t.active)
        Positioned(
          left: 8,
          bottom: 28,
          child: Material(
            color: Colors.red.shade700,
            borderRadius: BorderRadius.circular(20),
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.fiber_manual_record,
                    color: Colors.white, size: 14),
                const SizedBox(width: 6),
                Text(
                    'REC  ${describeDistance(t.distance)} · ${t.photos.length} photo${t.photos.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                const SizedBox(width: 4),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  onPressed: onFinish,
                  child: const Text('FINISH'),
                ),
              ]),
            ),
          ),
        ),
    ]);
  }
}

/// Status line, shutter buttons, folder / track options and recent photos.
class _Controls extends StatelessWidget {
  final CaptureService svc;
  final bool wide;
  final VoidCallback onConnect;
  final VoidCallback onLiveView;
  const _Controls(
      {required this.svc,
      required this.wide,
      required this.onConnect,
      required this.onLiveView});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = svc.state;
    final ready = state == CamState.ready;
    final busy = state == CamState.capturing || state == CamState.connecting;
    final track = svc.tracks;

    final status = Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(children: [
        if (busy)
          const Padding(
            padding: EdgeInsets.only(right: 10),
            child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        Expanded(
          child: Text(svc.status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      ]),
    );

    final Widget actions;
    if (state == CamState.disconnected) {
      actions = SizedBox(
        height: 64,
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: onConnect,
          icon: const Icon(Icons.bluetooth_searching),
          label: const Text('Connect to GoPro', style: TextStyle(fontSize: 18)),
        ),
      );
    } else {
      final shoot = SizedBox(
        height: 72,
        child: FilledButton.icon(
          onPressed: ready ? svc.capture : null,
          icon: const Icon(Icons.camera, size: 32),
          label: const Text('Take photo', style: TextStyle(fontSize: 20)),
        ),
      );
      final live = SizedBox(
        height: wide ? 52 : 72,
        child: OutlinedButton.icon(
          onPressed: ready ? onLiveView : null,
          icon: const Icon(Icons.live_tv),
          label: const Text('Live view'),
        ),
      );
      actions = wide
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              shoot,
              const SizedBox(height: 8),
              live,
            ])
          : Row(children: [
              Expanded(flex: 2, child: live),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: shoot),
            ]);
    }

    final options = Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FolderChip(svc: svc),
          FilterChip(
            avatar: Icon(Icons.route,
                size: 18,
                color:
                    (track?.enabled ?? false) ? null : scheme.onSurfaceVariant),
            label: const Text('Record track'),
            tooltip:
                'Record a GPS track (KMZ map) from the first photo until you close the app',
            selected: track?.enabled ?? false,
            showCheckmark: false,
            onSelected: track == null ? null : svc.setRecordTrack,
          ),
        ]);

    final recent = svc.photos.take(wide ? 30 : 12).toList();
    final Widget photos;
    if (recent.isEmpty) {
      photos = Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text('No photos in "${svc.currentFolder}" yet',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    } else if (wide) {
      photos = GridView.builder(
        padding: EdgeInsets.zero,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 120, mainAxisSpacing: 6, crossAxisSpacing: 6),
        itemCount: recent.length,
        itemBuilder: (_, i) => PhotoThumb(svc: svc, photo: recent[i]),
      );
    } else {
      photos = SizedBox(
        height: 76,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: recent.length,
          separatorBuilder: (context, i) => const SizedBox(width: 6),
          itemBuilder: (_, i) => SizedBox(
              width: 76, child: PhotoThumb(svc: svc, photo: recent[i])),
        ),
      );
    }
    final photosHeader = Row(children: [
      Text('Recent photos', style: Theme.of(context).textTheme.titleSmall),
      const Spacer(),
      if (svc.photos.isNotEmpty)
        TextButton(
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => GalleryPage(svc: svc))),
          child: Text('All (${svc.photos.length})'),
        ),
    ]);

    final body = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
        children: [
          actions,
          const SizedBox(height: 10),
          options,
          const SizedBox(height: 4),
          photosHeader,
          if (wide) Expanded(child: photos) else photos,
        ],
      ),
    );
    return Column(
      mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [status, if (wide) Expanded(child: body) else body],
    );
  }
}

/// Prominent notice while the phone is pairing with the camera.
class _PairingCard extends StatelessWidget {
  final String message;
  const _PairingCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      color: Colors.amber.shade100,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 3)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: Colors.black87),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 6),
                    const Text(
                        '• Accept the "Pair with GoPro…" request on the phone. On some '
                        'phones it appears as a notification — pull down from the top of the screen.'),
                    const Text(
                        '• The camera must be in pairing mode: Preferences → Wireless '
                        'Connections → Connect Device → GoPro Quik.'),
                  ]),
            ),
          ),
        ]),
      ),
    );
  }
}
