import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Receives the GoPro's live preview (MPEG-TS over UDP, port 8554) in the
/// app itself and re-serves it to the video player as a local HTTP stream
/// (`http://127.0.0.1:PORT/live.ts`).
///
/// Why: having the video player (libmpv) listen on UDP itself did not show
/// a picture on a real tablet. Receiving the packets in Dart uses the same
/// network path as the rest of the app, and lets the app tell the user
/// whether the camera is actually sending any video.
class PreviewRelay {
  final int udpPort;
  PreviewRelay({this.udpPort = 8554});

  RawDatagramSocket? _udp;
  HttpServer? _http;
  final _clients = <HttpResponse>{};

  /// Bytes / packets received from the camera since [start].
  final bytesReceived = ValueNotifier<int>(0);
  int packets = 0;
  DateTime? lastPacketAt;

  String get url => 'http://127.0.0.1:${_http!.port}/live.ts';
  bool get running => _udp != null;

  Future<void> start() async {
    if (running) return;
    _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort,
        reuseAddress: true);
    _udp!.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = _udp?.receive()) != null) {
        _forward(d!.data);
      }
    });
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http!.listen(_serve);
  }

  void _forward(Uint8List data) {
    packets++;
    lastPacketAt = DateTime.now();
    bytesReceived.value += data.length;
    for (final c in _clients.toList()) {
      try {
        c.add(data);
      } catch (_) {
        _clients.remove(c);
      }
    }
  }

  void _serve(HttpRequest req) {
    final res = req.response
      ..bufferOutput = false
      ..headers.contentType = ContentType('video', 'mp2t')
      ..headers.set('Cache-Control', 'no-cache')
      ..persistentConnection = true;
    _clients.add(res);
    res.done.whenComplete(() => _clients.remove(res)).ignore();
  }

  Future<void> stop() async {
    for (final c in _clients.toList()) {
      try {
        await c.close();
      } catch (_) {}
    }
    _clients.clear();
    _udp?.close();
    _udp = null;
    await _http?.close(force: true);
    _http = null;
  }
}
