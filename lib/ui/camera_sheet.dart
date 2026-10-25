import 'package:flutter/material.dart';

import '../services/capture_service.dart';
import 'camera_settings_page.dart';
import 'clock_card.dart';
import 'log_page.dart';

/// Everything about the connected camera in one place: mode, clock,
/// disconnect. Opened by tapping the camera bar on the main screen.
Future<void> showCameraSheet(BuildContext context, CaptureService svc) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => ListenableBuilder(
      listenable: svc,
      builder: (sheet, _) {
        final connected =
            svc.state == CamState.ready || svc.state == CamState.capturing;
        final mode = svc.mode;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: Icon(
                        connected ? Icons.videocam : Icons.videocam_off,
                        size: 32),
                    title: Text(connected ? svc.cameraName : 'Not connected',
                        style: Theme.of(sheet).textTheme.titleLarge),
                    subtitle: Text(svc.status,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                  if (connected) ...[
                    ListTile(
                      leading: Icon(
                        mode == null || mode.isPhoto
                            ? Icons.photo_camera
                            : Icons.warning_amber,
                        color: mode != null && !mode.isPhoto
                            ? Colors.orange
                            : null,
                      ),
                      title: Text('Mode: ${mode?.name ?? 'unknown'}'),
                      trailing: mode != null &&
                              !mode.isPhoto &&
                              svc.state == CamState.ready
                          ? FilledButton(
                              onPressed: svc.ensurePhotoMode,
                              child: const Text('Change to Photo'))
                          : null,
                    ),
                    ListTile(
                      leading: const Icon(Icons.tune),
                      title: const Text('Camera settings'),
                      subtitle: const Text(
                          'Lens, RAW, shutter, ISO, EV, white balance, sharpness'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(sheet).push(MaterialPageRoute(
                          builder: (_) => CameraSettingsPage(svc: svc))),
                    ),
                    ClockCard(svc: svc),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.pop(sheet);
                          await svc.disconnect();
                        },
                        icon: const Icon(Icons.link_off),
                        label: const Text('Disconnect camera'),
                      ),
                    ),
                  ],
                  TextButton.icon(
                    onPressed: () => Navigator.of(sheet).push(
                        MaterialPageRoute(builder: (_) => const LogPage())),
                    icon: const Icon(Icons.receipt_long),
                    label: const Text('Connection log'),
                  ),
                ]),
          ),
        );
      },
    ),
  );
}
