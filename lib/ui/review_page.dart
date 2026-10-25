import 'package:flutter/material.dart';

import '../services/capture_service.dart';

/// Full-screen view of the photo just taken: "Keep" stores it, "Discard"
/// goes back without saving it.
class ReviewPage extends StatelessWidget {
  final PendingPhoto photo;
  const ReviewPage({super.key, required this.photo});

  /// Shows the review screen; returns true if the user keeps the photo.
  static Future<bool> show(BuildContext context, PendingPhoto photo) async {
    final keep = await Navigator.of(context).push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ReviewPage(photo: photo),
    ));
    return keep ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final f = photo.fix;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(false); // back = discard
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          InteractiveViewer(
            maxScale: 6,
            child: Center(
              child: Image.memory(photo.bytes,
                  fit: BoxFit.contain, gaplessPlayback: true),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.all(12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12)),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(color: Colors.white),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(photo.cameraFile,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16)),
                        const SizedBox(height: 2),
                        Text(
                            'GPS ${f.latitude.toStringAsFixed(6)}, ${f.longitude.toStringAsFixed(6)}'
                            '${f.horizontalAccuracy == null ? '' : '  ±${f.horizontalAccuracy!.round()} m'}'),
                        Text('Will be saved in folder "${photo.folder}"'),
                      ]),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Is this photo OK?',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: SizedBox(
                        height: 56,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white70),
                          ),
                          onPressed: () => Navigator.of(context).pop(false),
                          icon: const Icon(Icons.close),
                          label: const Text('Discard',
                              style: TextStyle(fontSize: 18)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: SizedBox(
                        height: 56,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: Colors.green),
                          onPressed: () => Navigator.of(context).pop(true),
                          icon: const Icon(Icons.check),
                          label: const Text('Keep',
                              style: TextStyle(fontSize: 18)),
                        ),
                      ),
                    ),
                  ]),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
