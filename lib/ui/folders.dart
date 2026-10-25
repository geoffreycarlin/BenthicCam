import 'package:flutter/material.dart';

import '../services/capture_service.dart';
import '../services/photo_library.dart';

/// Compact "📁 Folder name ▾" button; tapping it opens [showFolderSheet].
class FolderChip extends StatelessWidget {
  final CaptureService svc;
  const FolderChip({super.key, required this.svc});

  @override
  Widget build(BuildContext context) => ActionChip(
        avatar: const Icon(Icons.folder, size: 18),
        label: Row(mainAxisSize: MainAxisSize.min, children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(svc.currentFolder, overflow: TextOverflow.ellipsis),
          ),
          const Icon(Icons.arrow_drop_down, size: 20),
        ]),
        tooltip: 'Folder new photos are saved in',
        onPressed: () => showFolderSheet(context, svc),
      );
}

/// Pick the folder new photos go into; create or delete folders.
Future<void> showFolderSheet(BuildContext context, CaptureService svc) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => ListenableBuilder(
      listenable: svc,
      builder: (sheet, _) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(sheet).size.height * 0.7),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 12, 8),
              child: Row(children: [
                Expanded(
                  child: Text('Save new photos in…',
                      style: Theme.of(sheet).textTheme.titleLarge),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _newFolder(sheet, svc),
                  icon: const Icon(Icons.create_new_folder),
                  label: const Text('New folder'),
                ),
              ]),
            ),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final f in svc.folders)
                  ListTile(
                    leading: Icon(
                        f == svc.currentFolder
                            ? Icons.folder_open
                            : Icons.folder,
                        color: f == svc.currentFolder
                            ? Theme.of(sheet).colorScheme.primary
                            : null),
                    title: Text(f),
                    subtitle: FutureBuilder<int>(
                      future: svc.library?.countIn(f),
                      builder: (_, n) => Text(n.hasData
                          ? '${n.data} photo${n.data == 1 ? '' : 's'}'
                          : ''),
                    ),
                    selected: f == svc.currentFolder,
                    trailing: f == PhotoLibrary.defaultFolder
                        ? null
                        : IconButton(
                            tooltip: 'Delete folder',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _deleteFolder(sheet, svc, f),
                          ),
                    onTap: () async {
                      await svc.selectFolder(f);
                      if (sheet.mounted) Navigator.pop(sheet);
                    },
                  ),
              ]),
            ),
          ]),
        ),
      ),
    ),
  );
}

Future<void> _newFolder(BuildContext context, CaptureService svc) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _NewFolderDialog(svc: svc),
  );
  if (name == null || !context.mounted) return;
  try {
    await svc.createFolder(name);
    if (context.mounted) Navigator.pop(context); // close the sheet
  } catch (e) {
    if (context.mounted) _error(context, e);
  }
}

Future<void> _deleteFolder(
    BuildContext context, CaptureService svc, String f) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete folder "$f"?'),
      content: const Text('Only empty folders can be deleted. '
          'Move the photos out first (open a photo and tap the move icon).'),
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
  if (ok != true || !context.mounted) return;
  try {
    await svc.deleteFolder(f);
  } catch (e) {
    if (context.mounted) _error(context, e);
  }
}

void _error(BuildContext context, Object e) =>
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));

class _NewFolderDialog extends StatefulWidget {
  final CaptureService svc;
  const _NewFolderDialog({required this.svc});
  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  Future<void> _submit() async {
    final err = await widget.svc.library?.validateNewName(_ctrl.text);
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, _ctrl.text.trim());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New folder'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: 'Folder name',
          hintText: 'e.g. Site visit 18 Oct',
          errorText: _error,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
