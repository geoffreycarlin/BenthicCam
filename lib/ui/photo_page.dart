import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../exif/exif_gps_writer.dart';
import '../services/capture_service.dart';
import 'folders.dart';

/// All photos in the current folder.
class GalleryPage extends StatelessWidget {
  final CaptureService svc;
  const GalleryPage({super.key, required this.svc});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: svc,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            title: Text('${svc.currentFolder} (${svc.photos.length})'),
            actions: [
              IconButton(
                tooltip: 'Change folder',
                icon: const Icon(Icons.folder_open),
                onPressed: () => showFolderSheet(context, svc),
              ),
            ],
          ),
          body: svc.photos.isEmpty
              ? const Center(child: Text('No photos in this folder yet'))
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 200,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4),
                  itemCount: svc.photos.length,
                  itemBuilder: (context, i) =>
                      PhotoThumb(svc: svc, photo: svc.photos[i]),
                ),
        ),
      );
}

/// Tappable thumbnail that opens [PhotoPage].
class PhotoThumb extends StatelessWidget {
  final CaptureService svc;
  final SavedPhoto photo;
  final double radius;
  const PhotoThumb(
      {super.key, required this.svc, required this.photo, this.radius = 6});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(fit: StackFit.expand, children: [
          Image.file(photo.file,
              fit: BoxFit.cover, cacheWidth: 300, gaplessPlayback: true),
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PhotoPage(photo: photo, svc: svc))),
            ),
          ),
        ]),
      );
}

class PhotoPage extends StatelessWidget {
  final SavedPhoto photo;
  final CaptureService? svc;
  const PhotoPage({super.key, required this.photo, this.svc});

  Future<void> _move(BuildContext context) async {
    final s = svc!;
    final target = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Move to folder'),
        children: [
          for (final f in s.folders)
            SimpleDialogOption(
              onPressed:
                  f == s.currentFolder ? null : () => Navigator.pop(context, f),
              child: Row(children: [
                Icon(f == s.currentFolder ? Icons.folder_open : Icons.folder),
                const SizedBox(width: 12),
                Text(f == s.currentFolder ? '$f (current)' : f),
              ]),
            ),
        ],
      ),
    );
    if (target == null || !context.mounted) return;
    await s.movePhoto(photo, target);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Moved to "$target"')));
    Navigator.of(context).pop();
  }

  /// Reads the GPS position back out of the saved file itself, so what you
  /// see here is exactly what is stored in the JPEG.
  Future<GpsFix?> _readGps() async =>
      ExifGpsWriter.read(await photo.file.readAsBytes());

  Future<void> _share() => SharePlus.instance.share(ShareParams(
        files: [XFile(photo.file.path, mimeType: 'image/jpeg')],
      ));

  @override
  Widget build(BuildContext context) {
    final name = photo.file.uri.pathSegments.last;
    return Scaffold(
      appBar: AppBar(
        title: Text(name, overflow: TextOverflow.ellipsis),
        actions: [
          if (svc != null)
            IconButton(
              tooltip: 'Move to folder',
              icon: const Icon(Icons.drive_file_move),
              onPressed: () => _move(context),
            ),
          IconButton(
            tooltip: 'Share original (keeps GPS)',
            icon: const Icon(Icons.share),
            onPressed: _share,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: InteractiveViewer(child: Image.file(photo.file))),
          FutureBuilder<GpsFix?>(
            future: _readGps(),
            builder: (context, snap) {
              final Widget text;
              if (snap.connectionState != ConnectionState.done) {
                text = const Text('Reading GPS from file…');
              } else if (snap.data == null) {
                text = const Text('No GPS stored in this file',
                    style: TextStyle(color: Colors.red));
              } else {
                text = Text('GPS stored in file: ${snap.data}');
              }
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Icon(snap.data == null
                      ? Icons.location_off
                      : Icons.location_on),
                  const SizedBox(width: 8),
                  Expanded(child: text),
                ]),
              );
            },
          ),
        ],
      ),
    );
  }
}
