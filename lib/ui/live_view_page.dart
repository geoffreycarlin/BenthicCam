import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../gopro/preview_relay.dart';
import '../services/capture_service.dart';
import '../services/connection_log.dart';

/// Full-screen live view from the GoPro with a shutter button, so you can
/// take the photo at exactly the right moment. GPS is recorded at the instant
/// the shutter button is pressed, as on the main screen.
class LiveViewPage extends StatefulWidget {
  final CaptureService svc;
  const LiveViewPage({super.key, required this.svc});

  @override
  State<LiveViewPage> createState() => _LiveViewPageState();
}

class _LiveViewPageState extends State<LiveViewPage> {
  Player? _player;
  VideoController? _video;
  bool _hasPicture = false;
  String? _error;
  final _relay = PreviewRelay();
  DateTime? _startedAt;
  Timer? _watchdog;
  final List<StreamSubscription> _subs = [];

  CaptureService get svc => widget.svc;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _hasPicture = false;
    });
    try {
      // Start receiving before asking the camera to send.
      await _relay.start();
      await svc.startPreview();
      if (!mounted) return;
      logConnect(
          'Live view: camera accepted preview start; waiting for video on UDP ${_relay.udpPort}');
      _startedAt = DateTime.now();
      _watchdog?.cancel();
      _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {}); // refresh the "data received" readout
      });
      if (_player == null) {
        final player = Player(
          configuration: const PlayerConfiguration(
            muted: true,
            bufferSize: 2 * 1024 * 1024, // small buffer = low delay
            logLevel: MPVLogLevel.warn,
          ),
        );
        // Low-latency settings for a live camera feed.
        final native = player.platform;
        if (native is NativePlayer) {
          for (final kv in const {
            'cache': 'no',
            'untimed': 'yes',
            'demuxer-lavf-format': 'mpegts',
            'demuxer-lavf-o': 'fflags=+nobuffer',
            'demuxer-lavf-analyzeduration': '0.5',
            'video-sync': 'desync',
            'framedrop': 'vo',
          }.entries) {
            try {
              await native.setProperty(kv.key, kv.value);
            } catch (_) {}
          }
        }
        _subs.add(player.stream.width.listen((w) {
          if (w != null && w > 0 && !_hasPicture && mounted) {
            logConnect('Live view: picture showing (${w}px wide)');
            setState(() => _hasPicture = true);
          }
        }));
        _subs.add(player.stream.error.listen((e) {
          logConnect('Live view player error: $e');
          if (mounted) setState(() => _error = e);
        }));
        _player = player;
        _video = VideoController(player);
        setState(() {});
      }
      await _player!.open(Media(_relay.url));
    } catch (e) {
      logConnect('Live view FAILED: $e');
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  /// What to show while waiting for the picture, based on whether any video
  /// data is actually arriving from the camera.
  String _waitingText() {
    if (_error != null) return _error!;
    final kb = _relay.bytesReceived.value ~/ 1024;
    final waited = _startedAt == null
        ? 0
        : DateTime.now().difference(_startedAt!).inSeconds;
    if (kb == 0) {
      if (waited < 6) return 'Starting live view…';
      return 'The camera has not sent any preview video ($waited s).\n\n'
          '• Make sure the camera screen is on its normal shooting view, not a menu or playback.\n'
          '• If the camera is recording or saving, wait for it to finish.\n'
          '• Tap ⟳ (top right) to ask the camera again.';
    }
    if (waited < 10) return 'Receiving video from camera ($kb KB)…';
    return 'Receiving video ($kb KB) but it cannot be displayed yet.\n'
        'Tap ⟳ (top right) to restart the live view.';
  }

  Future<void> _shutter() async {
    await svc.capture();
    // Some cameras pause the preview while saving a photo; restart it.
    if (mounted) {
      try {
        await svc.startPreview();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _watchdog?.cancel();
    _player?.dispose();
    svc.stopPreview();
    _relay.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        final busy = svc.state == CamState.capturing;
        final ready = svc.state == CamState.ready;
        final gps = svc.location.last;
        final last = svc.photos.isEmpty ? null : svc.photos.first;
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: const Text('Live view'),
            actions: [
              IconButton(
                tooltip: 'Restart live view',
                onPressed: _start,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: Stack(
            fit: StackFit.expand,
            children: [
              // ---- the picture
              if (_video != null)
                Video(
                    controller: _video!,
                    controls: NoVideoControls,
                    fit: BoxFit.contain),
              if (!_hasPicture)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (_error == null &&
                          !(_relay.bytesReceived.value == 0 &&
                              _startedAt != null &&
                              DateTime.now()
                                      .difference(_startedAt!)
                                      .inSeconds >=
                                  6))
                        const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        _waitingText(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ]),
                  ),
                ),

              // ---- top info: status, folder, GPS
              Positioned(
                left: 12,
                right: 12,
                top: 8,
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  _Chip(icon: Icons.folder, text: svc.currentFolder),
                  _Chip(
                    icon: Icons.gps_fixed,
                    text: gps == null
                        ? 'Waiting for GPS…'
                        : '${gps.latitude.toStringAsFixed(5)}, '
                            '${gps.longitude.toStringAsFixed(5)}  ±${gps.accuracy.toStringAsFixed(0)} m',
                  ),
                  if (svc.mode != null && !svc.mode!.isPhoto)
                    _Chip(
                        icon: Icons.warning_amber,
                        text: 'Camera in ${svc.mode!.name} mode'),
                ]),
              ),

              // ---- bottom: last photo, shutter, status
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                  color: Colors.black54,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      svc.status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 12),
                    Row(children: [
                      SizedBox(
                        width: 64,
                        height: 64,
                        child: last == null
                            ? null
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(last.file,
                                    fit: BoxFit.cover, cacheWidth: 160),
                              ),
                      ),
                      Expanded(
                        child: Center(
                          child: _ShutterButton(
                            busy: busy,
                            enabled: ready,
                            onPressed: _shutter,
                          ),
                        ),
                      ),
                      const SizedBox(width: 64),
                    ]),
                  ]),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ShutterButton extends StatelessWidget {
  final bool busy;
  final bool enabled;
  final VoidCallback onPressed;
  const _ShutterButton(
      {required this.busy, required this.enabled, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Take photo',
      child: GestureDetector(
        onTap: enabled ? onPressed : null,
        child: Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 5),
          ),
          padding: const EdgeInsets.all(6),
          child: busy
              ? const CircularProgressIndicator(
                  color: Colors.white, strokeWidth: 3)
              : DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: enabled ? Colors.white : Colors.white38,
                  ),
                ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Chip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
          color: Colors.black54, borderRadius: BorderRadius.circular(16)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: Colors.white),
        const SizedBox(width: 6),
        Flexible(
            child: Text(text,
                style: const TextStyle(color: Colors.white, fontSize: 13))),
      ]),
    );
  }
}
