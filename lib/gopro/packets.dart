/// Open GoPro BLE packet framing. A message longer than one BLE packet is
/// split: the first packet carries a header with the total length, the rest
/// are "continuation" packets. Spec:
/// https://gopro.github.io/OpenGoPro/ble/protocol/data_protocol.html
class GoProPacketAssembler {
  final List<int> _buf = [];
  int _expected = -1;

  /// Feeds one received packet. Returns the complete message when this
  /// packet finishes one, otherwise null.
  List<int>? add(List<int> p) {
    if (p.isEmpty) return null;
    final b0 = p[0];
    if (b0 & 0x80 != 0) {
      // continuation packet
      if (_expected < 0) return null; // no start seen: ignore
      _buf.addAll(p.skip(1));
    } else {
      final type = (b0 >> 5) & 0x03;
      int len, hdr;
      if (type == 0) {
        len = b0 & 0x1F;
        hdr = 1;
      } else if (type == 1) {
        if (p.length < 2) return null;
        len = ((b0 & 0x1F) << 8) | p[1];
        hdr = 2;
      } else if (type == 2) {
        if (p.length < 3) return null;
        len = (p[1] << 8) | p[2];
        hdr = 3;
      } else {
        return null; // reserved
      }
      _buf
        ..clear()
        ..addAll(p.skip(hdr));
      _expected = len;
    }
    if (_buf.length >= _expected) {
      final msg = _buf.sublist(0, _expected);
      _buf.clear();
      _expected = -1;
      return msg;
    }
    return null;
  }

  /// Splits [payload] into BLE packets of at most [mtu] bytes (for tests and
  /// long writes).
  static List<List<int>> split(List<int> payload, {int mtu = 20}) {
    final out = <List<int>>[];
    final List<int> header;
    if (payload.length < 32) {
      header = [payload.length];
    } else if (payload.length < 8192) {
      header = [0x20 | (payload.length >> 8), payload.length & 0xFF];
    } else {
      header = [0x40, payload.length >> 8, payload.length & 0xFF];
    }
    var i = 0;
    var first = true;
    while (i < payload.length || first) {
      final head = first ? header : [0x80];
      final n = (mtu - head.length).clamp(0, payload.length - i);
      out.add([...head, ...payload.sublist(i, i + n)]);
      i += n;
      first = false;
    }
    return out;
  }
}

/// Parses a query response body [(id, len, value...)*] into a list of
/// (id, value) pairs, keeping repeats (capability responses list one entry
/// per allowed value).
List<(int, List<int>)> parseTlv(List<int> data) {
  final out = <(int, List<int>)>[];
  var i = 0;
  while (i + 1 < data.length) {
    final id = data[i], len = data[i + 1];
    if (i + 2 + len > data.length) break;
    out.add((id, data.sublist(i + 2, i + 2 + len)));
    i += 2 + len;
  }
  return out;
}

int uintOfBytes(List<int> b) => b.fold(0, (v, x) => (v << 8) | x);
