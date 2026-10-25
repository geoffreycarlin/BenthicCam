import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/capture_service.dart';

Future<void> shareKmz(File kmz) => SharePlus.instance.share(ShareParams(
      files: [XFile(kmz.path, mimeType: 'application/vnd.google-earth.kmz')],
      subject: kmz.uri.pathSegments.last,
    ));

/// Lists saved KMZ tracks with share and delete.
class TracksPage extends StatefulWidget {
  final CaptureService svc;
  const TracksPage({super.key, required this.svc});
  @override
  State<TracksPage> createState() => _TracksPageState();
}

class _TracksPageState extends State<TracksPage> {
  List<File> _files = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final f = await widget.svc.tracks?.savedTracks() ?? <File>[];
    if (mounted) setState(() => _files = f);
  }

  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${f.uri.pathSegments.last}?'),
        content: const Text('The photos themselves are not affected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await f.delete();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.svc.tracks?.active ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('GPS tracks (KMZ)')),
      body: _files.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                    'No tracks yet. Tick "Record GPS track" on the main screen; '
                    'recording starts with your first photo.',
                    textAlign: TextAlign.center),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(8),
              children: [
                for (final f in _files)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.map, size: 32),
                      title: Text(f.uri.pathSegments.last),
                      subtitle: Text('${(f.lengthSync() / 1024).round()} KB'
                          '${active && f.path == widget.svc.tracks!.kmzFile.path ? ' · recording now (updated after each photo)' : ''}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                            tooltip: 'Share',
                            icon: const Icon(Icons.share),
                            onPressed: () => shareKmz(f)),
                        IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(f)),
                      ]),
                    ),
                  ),
              ],
            ),
    );
  }
}
