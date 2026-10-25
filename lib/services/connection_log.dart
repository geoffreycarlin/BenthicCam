import 'package:flutter/foundation.dart';

/// A short, timestamped log of what happened while connecting to the camera,
/// viewable in the app (menu ⋮ > Connection log) to diagnose slow connects.
class ConnectionLog extends ChangeNotifier {
  ConnectionLog._();
  static final instance = ConnectionLog._();

  final List<(DateTime, String)> entries = [];
  DateTime? _start;

  /// Starts a new connection: clears the log and resets the timer.
  void begin(String message) {
    entries.clear();
    _start = DateTime.now();
    add(message);
  }

  void add(String message) {
    entries.add((DateTime.now(), message));
    if (entries.length > 400) entries.removeAt(0);
    debugPrint('[connect] $message');
    notifyListeners();
  }

  /// "+12.3 s" since [begin].
  String elapsed(DateTime t) {
    final s =
        _start == null ? 0.0 : t.difference(_start!).inMilliseconds / 1000;
    return '+${s.toStringAsFixed(1)} s';
  }

  String asText() =>
      entries.map((e) => '${elapsed(e.$1).padLeft(8)}  ${e.$2}').join('\n');
}

void logConnect(String message) => ConnectionLog.instance.add(message);
