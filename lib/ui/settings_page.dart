import 'package:flutter/material.dart';

import '../services/capture_service.dart';
import 'camera_settings_page.dart';
import 'log_page.dart';
import 'position_map.dart';
import 'tracks_page.dart';

class SettingsPage extends StatelessWidget {
  final CaptureService svc;
  const SettingsPage({super.key, required this.svc});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        final st = svc.settings;
        final track = svc.tracks;
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(children: [
            const _Header('Camera'),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Camera settings'),
              subtitle: Text(svc.state == CamState.ready
                  ? 'Compare with and apply the survey settings'
                  : 'Connect to the GoPro first'),
              trailing: const Icon(Icons.chevron_right),
              enabled: svc.state == CamState.ready,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => CameraSettingsPage(svc: svc))),
            ),
            const _Header('Photos'),
            SwitchListTile(
              secondary: const Icon(Icons.fact_check_outlined),
              title: const Text('Review each photo before saving'),
              subtitle: const Text('Show it full screen with Keep / Discard'),
              value: svc.reviewBeforeSaving,
              onChanged: st == null
                  ? null
                  : (v) => st.update((s) => s.reviewBeforeSaving = v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.photo_library_outlined),
              title: const Text('Also save to the phone gallery'),
              subtitle: const Text('Album "GoPro GPS - <folder>"'),
              value: svc.saveToGallery,
              onChanged: st == null
                  ? null
                  : (v) => st.update((s) => s.saveToGallery = v),
            ),
            const _Header('GPS'),
            SwitchListTile(
              secondary: const Icon(Icons.route),
              title: const Text('Record GPS track (KMZ map)'),
              subtitle: const Text(
                  'Starts at the first photo, ends when you close the app'),
              value: track?.enabled ?? false,
              onChanged: track == null ? null : svc.setRecordTrack,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.satellite_alt),
              title: const Text('Use GPS satellites only'),
              subtitle: const Text(
                  'Ignore Wi-Fi / mobile positioning (outdoors only)'),
              value: st?.gpsOnly ?? false,
              onChanged: svc.setGpsOnly,
            ),
            ListTile(
              leading: const Icon(Icons.gps_fixed),
              title: const Text('Current GPS position & accuracy'),
              onTap: () => showGpsDetails(context, svc),
            ),
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: const Text('Saved GPS tracks (KMZ)'),
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => TracksPage(svc: svc))),
            ),
            const _Header('Help'),
            ListTile(
              leading: const Icon(Icons.receipt_long),
              title: const Text('Connection log'),
              subtitle:
                  const Text('Step-by-step log of the last camera connection'),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const LogPage())),
            ),
          ]),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text,
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600)),
      );
}
