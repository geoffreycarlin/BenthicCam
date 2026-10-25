import 'dart:async';

import 'package:flutter/material.dart';

import '../gopro/camera.dart';

/// Bottom sheet that scans for nearby GoPros and lets you pick one.
/// Returns the chosen camera, or null if cancelled.
Future<FoundCamera?> showCameraPicker(
    BuildContext context, CameraScanner scanner) {
  return showModalBottomSheet<FoundCamera>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CameraPicker(scanner: scanner),
  );
}

class _CameraPicker extends StatefulWidget {
  final CameraScanner scanner;
  const _CameraPicker({required this.scanner});

  @override
  State<_CameraPicker> createState() => _CameraPickerState();
}

class _CameraPickerState extends State<_CameraPicker> {
  List<FoundCamera> _found = const [];
  bool _scanning = false;
  String? _error;
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    _subs.add(widget.scanner.results.listen((r) => setState(() => _found = r)));
    _subs.add(
        widget.scanner.isScanning.listen((s) => setState(() => _scanning = s)));
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _error = null;
      _scanning = true;
    });
    try {
      await widget.scanner.start();
    } catch (e) {
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _scanning = false;
      });
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    widget.scanner.stop();
    super.dispose();
  }

  /// Rough signal bars from RSSI (dBm).
  IconData _signalIcon(int rssi) {
    if (rssi >= -60) return Icons.signal_cellular_alt;
    if (rssi >= -75) return Icons.signal_cellular_alt_2_bar;
    return Icons.signal_cellular_alt_1_bar;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Text('Choose a GoPro',
                    style: Theme.of(context).textTheme.titleLarge),
              ),
              if (_scanning)
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else
                TextButton.icon(
                  onPressed: _scan,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Scan again'),
                ),
            ]),
            const SizedBox(height: 4),
            Text(
              'Make sure each camera is switched on and awake. Nearest cameras are listed first.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              )
            else if (_found.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(_scanning
                      ? 'Searching for GoPros…'
                      : 'No GoPros found. Wake the camera and tap "Scan again".'),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.5),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final cam in _found)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.videocam, size: 32),
                          title: Text(cam.name),
                          subtitle: Text('${cam.id} · signal ${cam.rssi} dBm'),
                          trailing: Icon(_signalIcon(cam.rssi)),
                          onTap: () => Navigator.of(context).pop(cam),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
