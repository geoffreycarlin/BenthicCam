import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/connection_log.dart';

/// Shows the step-by-step log of the last connection attempt.
class LogPage extends StatelessWidget {
  const LogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final log = ConnectionLog.instance;
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Connection log'),
          actions: [
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: log.asText()));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Log copied')));
              },
            ),
          ],
        ),
        body: log.entries.isEmpty
            ? const Center(
                child: Text('Connect to a camera to see the log here.'))
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: log.entries.length,
                itemBuilder: (_, i) {
                  final (t, msg) = log.entries[i];
                  final bad = msg.contains('FAIL') || msg.contains('did not');
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 72,
                            child: Text(log.elapsed(t),
                                style: const TextStyle(fontFeatures: [
                                  FontFeature.tabularFigures()
                                ])),
                          ),
                          Expanded(
                            child: Text(msg,
                                style:
                                    TextStyle(color: bad ? Colors.red : null)),
                          ),
                        ]),
                  );
                },
              ),
      ),
    );
  }
}
