import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/app_settings.dart';
import '../services/capture_service.dart';

/// Map of where the tablet is (blue dot + accuracy circle), with the GPS
/// track being recorded (red line) and the photos taken on it. Fills the
/// space it is given.
///
/// Tiles are cached on the device, so areas viewed before connecting still
/// show while the tablet is on the GoPro's Wi-Fi (which has no internet).
class PositionMap extends StatefulWidget {
  final CaptureService svc;
  const PositionMap({super.key, required this.svc});

  @override
  State<PositionMap> createState() => _PositionMapState();
}

class _PositionMapState extends State<PositionMap> {
  final _map = MapController();
  bool _ready = false;
  bool _follow = true;
  LatLng? _lastCentered;

  static final _cache = BuiltInMapCachingProvider.getOrCreateInstance(
    maxCacheSize: 400 * 1024 * 1024,
    // Use cached imagery without re-checking it online for 60 days, so the
    // map still works with no internet (e.g. while on the GoPro's Wi-Fi).
    overrideFreshAge: const Duration(days: 60),
  );

  void _followPosition(LatLng here) {
    if (!_ready || !_follow) return;
    if (_lastCentered != null &&
        const Distance().as(LengthUnit.Meter, _lastCentered!, here) < 2) {
      return;
    }
    _lastCentered = here;
    _map.move(here, _map.camera.zoom);
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.svc;
    final layer = svc.settings?.mapLayer ?? MapLayer.esri;
    final pos = svc.location.last;
    final here = pos == null ? null : LatLng(pos.latitude, pos.longitude);
    if (here != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _followPosition(here));
    }
    final t = svc.tracks;
    final track = t == null || !t.active
        ? const <LatLng>[]
        : [for (final p in t.points) LatLng(p.lat, p.lon)];
    final shots = t == null || !t.active
        ? const <LatLng>[]
        : [for (final p in t.photos) LatLng(p.at.lat, p.at.lon)];

    return Stack(children: [
      FlutterMap(
        mapController: _map,
        options: MapOptions(
          initialCenter: here ?? const LatLng(-28.17, 153.54),
          initialZoom: here == null ? 4 : 18,
          maxZoom: 21,
          onMapReady: () {
            _ready = true;
            if (here != null) _map.move(here, 18);
          },
          onPositionChanged: (camera, hasGesture) {
            if (hasGesture && _follow) setState(() => _follow = false);
          },
        ),
        children: [
          TileLayer(
            key: ValueKey(layer),
            urlTemplate: layer.url,
            userAgentPackageName: 'com.goprogps.gopro_gps_cam',
            maxNativeZoom: layer.maxNativeZoom,
            tileProvider: NetworkTileProvider(
              cachingProvider: _cache,
              silenceExceptions: true, // offline: just show what's cached
            ),
          ),
          if (track.length >= 2)
            PolylineLayer(polylines: [
              Polyline(points: track, color: Colors.redAccent, strokeWidth: 4),
            ]),
          if (pos != null && here != null)
            CircleLayer(circles: [
              CircleMarker(
                point: here,
                radius: pos.accuracy,
                useRadiusInMeter: true,
                color: Colors.blue.withValues(alpha: 0.18),
                borderColor: Colors.blue.withValues(alpha: 0.7),
                borderStrokeWidth: 1.5,
              ),
            ]),
          MarkerLayer(markers: [
            for (final s in shots)
              Marker(
                point: s,
                width: 26,
                height: 26,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                      color: Colors.white, shape: BoxShape.circle),
                  child:
                      Icon(Icons.photo_camera, size: 16, color: Colors.black87),
                ),
              ),
            if (here != null)
              Marker(
                point: here,
                width: 22,
                height: 22,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: const [
                      BoxShadow(blurRadius: 4, color: Colors.black45)
                    ],
                  ),
                ),
              ),
          ]),
          SimpleAttributionWidget(source: Text(layer.attribution)),
        ],
      ),
      if (here == null)
        const Center(
          child: Card(
            child: Padding(
                padding: EdgeInsets.all(12), child: Text('Waiting for GPS…')),
          ),
        ),
      // ---- GPS quality (tap for details)
      Positioned(
        left: 8,
        top: 8,
        child: _GpsChip(svc: svc),
      ),
      // ---- map buttons
      Positioned(
        right: 8,
        top: 8,
        child: Column(children: [
          _MapButton(
            tooltip: 'Map type',
            icon: Icons.layers,
            onPressed: () => _chooseLayer(context),
          ),
          if (!_follow && here != null) ...[
            const SizedBox(height: 8),
            _MapButton(
              tooltip: 'Back to my position',
              icon: Icons.my_location,
              onPressed: () {
                setState(() => _follow = true);
                _lastCentered = null;
                _followPosition(here);
              },
            ),
          ],
        ]),
      ),
    ]);
  }

  Future<void> _chooseLayer(BuildContext context) async {
    final svc = widget.svc;
    final current = svc.settings?.mapLayer ?? MapLayer.esri;
    final chosen = await showModalBottomSheet<MapLayer>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'If your position looks shifted on the photo imagery, compare with '
              'the street map: if the dot sits on the right road there, the '
              'imagery is misaligned — pick another imagery source.',
            ),
          ),
          for (final l in MapLayer.values)
            ListTile(
              leading: Icon(l == current
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off),
              title: Text(l.label),
              subtitle: Text(l.attribution),
              onTap: () => Navigator.pop(context, l),
            ),
        ]),
      ),
    );
    if (chosen != null) await svc.settings?.update((s) => s.mapLayer = chosen);
  }
}

class _MapButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  const _MapButton(
      {required this.tooltip, required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surface,
        shape: const CircleBorder(),
        elevation: 1,
        child: IconButton(
            tooltip: tooltip, icon: Icon(icon), onPressed: onPressed),
      );
}

/// "GPS ±4 m" — green / orange / red by accuracy. Tap for details.
class _GpsChip extends StatelessWidget {
  final CaptureService svc;
  const _GpsChip({required this.svc});

  @override
  Widget build(BuildContext context) {
    final p = svc.location.last;
    final acc = p?.accuracy;
    final colour = acc == null
        ? Colors.grey
        : acc <= 10
            ? Colors.green.shade700
            : acc <= 25
                ? Colors.orange.shade800
                : Colors.red.shade700;
    return Material(
      color: colour,
      borderRadius: BorderRadius.circular(18),
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => showGpsDetails(context, svc),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.gps_fixed, size: 16, color: Colors.white),
            const SizedBox(width: 6),
            Text(
              acc == null ? 'No GPS yet' : 'GPS ±${acc.round()} m',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Explains the current fix and how to tell GPS error from map misalignment.
Future<void> showGpsDetails(BuildContext context, CaptureService svc) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        final p = svc.location.last;
        String two(int n) => n.toString().padLeft(2, '0');
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('GPS position',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              if (p == null)
                const Text('Waiting for the first GPS fix…')
              else ...[
                Text(
                    '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}'),
                Text('Accuracy ±${p.accuracy.toStringAsFixed(1)} m'
                    '${p.altitude == 0 ? '' : '   ·   Height ${p.altitude.toStringAsFixed(0)} m'}'),
                Text(
                    'Updated ${two(p.timestamp.toLocal().hour)}:${two(p.timestamp.toLocal().minute)}:'
                    '${two(p.timestamp.toLocal().second)}'),
              ],
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Use GPS satellites only'),
                subtitle: const Text(
                    'Ignore Wi-Fi / mobile-network positioning. More accurate outdoors, '
                    'slower to get a fix, does not work indoors.'),
                value: svc.settings?.gpsOnly ?? false,
                onChanged: svc.setGpsOnly,
              ),
              const Divider(),
              const Text('Position looks wrong on the map?',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                  '• Large blue circle (more than ±15 m): the phone\'s fix is poor — '
                  'go outside with a clear view of the sky and wait a minute, or turn on '
                  '"Use GPS satellites only". Also check Android Settings → Location → '
                  'Location services → Google Location Accuracy is on.\n'
                  '• Small circle but the dot is beside where you are: the imagery may '
                  'be misaligned. Tap the layers button and compare with the Street map '
                  'or the NSW aerial imagery.'),
            ]),
          ),
        );
      },
    ),
  );
}
