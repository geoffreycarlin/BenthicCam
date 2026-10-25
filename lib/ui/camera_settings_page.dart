import 'package:flutter/material.dart';

import '../services/camera_settings.dart';
import '../services/capture_service.dart';

/// Shows the camera's current photo settings next to the settings
/// recommended for quadrat surveys, and applies the chosen ones.
class CameraSettingsPage extends StatefulWidget {
  final CaptureService svc;
  const CameraSettingsPage({super.key, required this.svc});

  @override
  State<CameraSettingsPage> createState() => _CameraSettingsPageState();
}

class _CameraSettingsPageState extends State<CameraSettingsPage> {
  late final CameraSettingsController c = CameraSettingsController(widget.svc);

  @override
  void initState() {
    super.initState();
    if (_connected) c.load();
  }

  bool get _connected =>
      widget.svc.state == CamState.ready ||
      widget.svc.state == CamState.capturing;

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, widget.svc]),
      builder: (context, _) {
        final busy = c.loading || c.applying;
        final ready = widget.svc.state == CamState.ready;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Camera settings'),
            actions: [
              IconButton(
                tooltip: 'Read again from camera',
                icon: const Icon(Icons.refresh),
                onPressed: busy || !ready ? null : c.load,
              ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: _body(context, busy),
            ),
          ),
          bottomNavigationBar: c.rows.isEmpty
              ? null
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: busy ? null : c.selectAllRecommended,
                          child: const Text('Select recommended'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(48)),
                          onPressed:
                              busy || !ready || c.toApply == 0 ? null : c.apply,
                          icon: c.applying
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.check),
                          label: Text(c.toApply == 0
                              ? 'Nothing to change'
                              : 'Apply ${c.toApply} change${c.toApply == 1 ? '' : 's'}'),
                        ),
                      ),
                    ]),
                  ),
                ),
        );
      },
    );
  }

  Widget _body(BuildContext context, bool busy) {
    if (!_connected && c.rows.isEmpty) {
      return const _Message(
          icon: Icons.videocam_off,
          text: 'Connect to the GoPro first, then open Camera settings.');
    }
    if (c.loading && c.rows.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (c.rows.isEmpty) {
      return _Message(
          icon: Icons.error_outline,
          text: c.error ?? 'The camera did not report its settings.',
          action:
              TextButton(onPressed: c.load, child: const Text('Try again')));
    }
    final available = c.rows.where((r) => r.available).toList();
    final good = available.where((r) => r.ok).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      children: [
        Card(
          color: c.allOk
              ? Colors.green.withValues(alpha: 0.12)
              : Colors.orange.withValues(alpha: 0.12),
          child: ListTile(
            leading: Icon(c.allOk ? Icons.verified : Icons.tune,
                color: c.allOk ? Colors.green.shade700 : Colors.orange.shade800,
                size: 32),
            title: Text(c.allOk
                ? 'Camera matches the survey settings'
                : '$good of ${available.length} settings match the survey '
                    'recommendations'),
            subtitle: const Text(
                'Changes apply to the camera\'s current Photo preset. '
                'Untick anything you want to leave as it is.'),
          ),
        ),
        if (c.error != null)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(c.error!)),
          ),
        if (busy) const LinearProgressIndicator(),
        for (final r in c.rows) _SettingCard(row: r, c: c, enabled: !busy),
      ],
    );
  }
}

class _SettingCard extends StatelessWidget {
  final SettingRow row;
  final CameraSettingsController c;
  final bool enabled;
  const _SettingCard(
      {required this.row, required this.c, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final d = row.def;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (!row.available) {
      return Card(
        child: ListTile(
          enabled: false,
          title: Text(d.name),
          subtitle: Text('Not available on this camera · '
              'recommended ${d.recommended}'),
        ),
      );
    }
    final okColour = Colors.green.shade700;
    final offColour = Colors.orange.shade800;
    final options = {...row.options, if (row.choice != null) row.choice!};
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 16, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Checkbox(
            value: row.apply,
            onChanged: !enabled || row.choice == null
                ? null
                : (v) => c.setApply(row, v ?? false),
          ),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SizedBox(height: 10),
              Text(d.name, style: t.titleMedium),
              const SizedBox(height: 6),
              Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(row.ok ? Icons.check_circle : Icons.info,
                          size: 18, color: row.ok ? okColour : offColour),
                      const SizedBox(width: 4),
                      Text('Now: ${d.label(row.current)}',
                          style: t.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: row.ok ? okColour : offColour)),
                    ]),
                    Text('Recommended: ${d.recommended}', style: t.bodyMedium),
                  ]),
              const SizedBox(height: 8),
              Row(children: [
                Text('Set to ', style: t.bodyMedium),
                Flexible(
                  child: DropdownButton<int>(
                    value: row.choice,
                    hint: const Text('—'),
                    isDense: true,
                    isExpanded: true,
                    onChanged: enabled
                        ? (v) {
                            if (v != null) c.setChoice(row, v);
                          }
                        : null,
                    items: [
                      for (final o in options)
                        DropdownMenuItem(
                          value: o,
                          child: Text(
                              '${d.label(o)}${d.preferred.contains(o) || d.alternates.contains(o) ? '  ★' : ''}'),
                        ),
                    ],
                  ),
                ),
              ]),
              if (row.choice == null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                      'The camera does not offer the recommended option '
                      'with its current settings.',
                      style: t.bodySmall?.copyWith(color: offColour)),
                ),
              const SizedBox(height: 6),
              Text(d.why, style: t.bodySmall?.copyWith(color: muted)),
              if (row.result != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    Icon(row.resultOk ? Icons.done : Icons.warning_amber,
                        size: 16, color: row.resultOk ? okColour : offColour),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(row.result!,
                          style: t.bodySmall?.copyWith(
                              color: row.resultOk ? okColour : offColour)),
                    ),
                  ]),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const _Message({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            if (action != null) action!,
          ]),
        ),
      );
}
