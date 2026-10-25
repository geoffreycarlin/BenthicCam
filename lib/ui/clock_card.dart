import 'dart:async';

import 'package:flutter/material.dart';

import '../services/capture_service.dart';

/// Shows the tablet clock, the camera clock and the difference, live, with a
/// button to set the camera's clock from the tablet.
class ClockCard extends StatefulWidget {
  final CaptureService svc;
  const ClockCard({super.key, required this.svc});

  @override
  State<ClockCard> createState() => _ClockCardState();
}

class _ClockCardState extends State<ClockCard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Tick a few times a second so the seconds roll over close to on time.
    _ticker = Timer.periodic(
        const Duration(milliseconds: 250), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmt(DateTime t) =>
      '${_two(t.day)}/${_two(t.month)}/${t.year}  ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  @override
  Widget build(BuildContext context) {
    final svc = widget.svc;
    final clock = svc.clock;
    final now = DateTime.now();
    final off = clock?.offset;
    final inSync = off != null && off.inMilliseconds.abs() < 1500;
    final colour = off == null
        ? null
        : inSync
            ? Colors.green
            : (off.inSeconds.abs() < 60 ? Colors.orange : Colors.red);

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.schedule),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Clocks',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              IconButton(
                tooltip: 'Re-read camera time',
                onPressed: svc.clockBusy ? null : svc.refreshCameraClock,
                icon: const Icon(Icons.refresh),
              ),
            ]),
            Table(
              columnWidths: const {0: IntrinsicColumnWidth()},
              children: [
                TableRow(children: [
                  const Padding(
                      padding: EdgeInsets.only(right: 16),
                      child: Text('Tablet')),
                  Text(_fmt(now),
                      style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()])),
                ]),
                TableRow(children: [
                  const Padding(
                      padding: EdgeInsets.only(right: 16),
                      child: Text('Camera')),
                  Text(
                    clock == null
                        ? (svc.clockBusy ? 'Reading…' : '—')
                        : _fmt(clock.cameraNow()),
                    style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ]),
              ],
            ),
            const SizedBox(height: 8),
            if (svc.clockError != null)
              Text(svc.clockError!, style: const TextStyle(color: Colors.red))
            else if (off != null)
              Text(describeClockOffset(off),
                  style: TextStyle(color: colour, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: svc.clockBusy ? null : svc.setCameraClockFromTablet,
              icon: svc.clockBusy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
              label: const Text('Set camera time from tablet'),
            ),
          ],
        ),
      ),
    );
  }
}

/// "in sync", "camera 47 s ahead", "camera 9 y 280 d 4 h 12 min behind"...
String describeClockOffset(Duration d) {
  final secs = d.inMilliseconds / 1000;
  if (secs.abs() < 1.5) return 'In sync (within 1 second)';
  final dir = secs > 0 ? 'ahead of' : 'behind';
  var s = secs.abs().round();
  final years = s ~/ (365 * 86400);
  s -= years * 365 * 86400;
  final days = s ~/ 86400;
  s -= days * 86400;
  final h = s ~/ 3600;
  s -= h * 3600;
  final m = s ~/ 60;
  s -= m * 60;
  final parts = [
    if (years > 0) '$years y',
    if (days > 0) '$days d',
    if (h > 0) '$h h',
    if (m > 0) '$m min',
    if (s > 0 && years == 0 && days == 0) '$s s',
  ];
  return 'Camera is ${parts.join(' ')} $dir the tablet';
}
