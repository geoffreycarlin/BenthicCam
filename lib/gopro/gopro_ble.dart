import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../services/connection_log.dart';
import 'packets.dart';

/// Open GoPro BLE control (HERO9 and newer).
/// Spec: https://gopro.github.io/OpenGoPro/ble/
class GoProBle {
  static String _gp(String id) => 'b5f9$id-aa8d-11e3-9046-0002a5d5c51b';

  static final Guid advertisedService = Guid('FEA6');
  static final Guid _wifiSsid = Guid(_gp('0002'));
  static final Guid _wifiPassword = Guid(_gp('0003'));
  static final Guid _command = Guid(_gp('0072'));
  static final Guid _commandResp = Guid(_gp('0073'));
  static final Guid _settings = Guid(_gp('0074'));
  static final Guid _settingsResp = Guid(_gp('0075'));
  static final Guid _query = Guid(_gp('0076'));
  static final Guid _queryResp = Guid(_gp('0077'));

  BluetoothDevice? _device;
  final Map<Guid, BluetoothCharacteristic> _chars = {};
  final List<StreamSubscription> _subs = [];
  final List<StreamSubscription> _respSubs = [];
  Timer? _keepAlive;
  _Pending? _pendingCommand;
  _Pending? _pendingQuery;
  _Pending? _pendingSetting;
  final Map<Guid, GoProPacketAssembler> _assemblers = {};

  /// Fires when the BLE link drops.
  final _disconnected = StreamController<void>.broadcast();
  Stream<void> get onDisconnected => _disconnected.stream;

  bool get isConnected => _device?.isConnected ?? false;
  String get name {
    final n = _device?.platformName ?? '';
    return n.isEmpty ? 'GoPro' : n;
  }

  /// Makes sure Bluetooth LE is available and switched on.
  static Future<void> ensureBluetoothOn() async {
    if (await FlutterBluePlus.isSupported == false) {
      throw Exception('Bluetooth LE is not supported on this device');
    }
    await FlutterBluePlus.adapterState
        .where((s) => s == BluetoothAdapterState.on)
        .first
        .timeout(const Duration(seconds: 10),
            onTimeout: () => throw Exception('Please turn Bluetooth on'));
  }

  /// Starts scanning for advertising GoPros (camera on and awake; for the very
  /// first pairing put it in pairing mode: Preferences > Wireless Connections >
  /// Connect Device > GoPro Quik). Listen to [scanResults] for the live list.
  static Future<void> startScan(
      {Duration timeout = const Duration(seconds: 20)}) async {
    await ensureBluetoothOn();
    await FlutterBluePlus.startScan(
      withServices: [advertisedService],
      timeout: timeout,
      continuousUpdates: true, // keep signal strength fresh
      removeIfGone: const Duration(seconds: 6),
    );
  }

  static Stream<List<ScanResult>> get scanResults =>
      FlutterBluePlus.onScanResults;
  static Stream<bool> get isScanning => FlutterBluePlus.isScanning;
  static Future<void> stopScan() => FlutterBluePlus.stopScan();

  /// Connects, pairs and subscribes, retrying when the link fails.
  ///
  /// Older Android phones often fail the first Bluetooth LE connection with
  /// "android code 133" (GATT_ERROR) — a generic "link could not be set up in
  /// time". Known triggers, all avoided here: connecting while a scan is still
  /// running, asking for a larger packet size (MTU) straight after connecting,
  /// and pairing/discovering before the link has settled. If it still fails,
  /// the link is closed, the phone is given a few seconds, and it tries again
  /// (clearing Android's cached service list on the retry).
  Future<void> connect(BluetoothDevice device,
      {void Function(String)? status,
      void Function(String? message)? pairing,
      int attempts = 4}) async {
    _device = device;
    if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    await Future.delayed(const Duration(milliseconds: 700));

    // Pair through Android first if the phone has never paired with this
    // camera (same as adding it in Android's Bluetooth settings). Without
    // this, some phones reject the connection at once with error 133.
    if (Platform.isAndroid) await _ensurePaired(device, pairing);

    Object? lastError;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        if (attempt > 1) {
          status?.call(
              'Bluetooth link failed — retrying ($attempt of $attempts)…');
        }
        logConnect('Bluetooth: link attempt $attempt of $attempts');
        // FlutterBluePlus is free for personal / nonprofit use; for-profit use
        // needs License.commercial (paid). See https://pub.dev/packages/flutter_blue_plus
        await device.connect(
          license: License.nonprofit,
          timeout: const Duration(seconds: 30),
          autoConnect: false,
          mtu: null, // GoPro messages are small; a MTU request can cause 133
        );
        logConnect('Bluetooth: link up');
        await _setUpLink(device, clearCache: attempt > 1);
        lastError = null;
        break;
      } catch (e) {
        lastError = e;
        logConnect('Bluetooth: attempt $attempt failed: ${_describe(e)}');
        try {
          await device.disconnect();
        } catch (_) {}
        if (attempt < attempts) {
          await Future.delayed(Duration(seconds: 2 + 2 * attempt));
        }
      }
    }
    if (lastError != null) {
      final code =
          lastError is FlutterBluePlusException ? lastError.code : null;
      if (Platform.isAndroid && !await isPaired(device.remoteId.str)) {
        throw NotPairedException(device.remoteId.str, code);
      }
      throw Exception('Could not connect to the camera over Bluetooth'
          '${code == null ? '' : ' (Android code $code)'} after $attempts tries. '
          'Try: switch the camera off and on, turn the phone\'s Bluetooth off and on, '
          'and if it keeps failing remove the GoPro from the phone\'s Bluetooth '
          'settings ("Forget"/"Unpair") and pair again.');
    }

    _subs.add(device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) {
        _keepAlive?.cancel();
        _disconnected.add(null);
      }
    }));
    _startKeepAlive();
  }

  static const _bond = MethodChannel('gopro_gps_cam/bond');

  static Future<int?> _bondState(String address) async {
    try {
      return await _bond.invokeMethod<int>('bondState', {'address': address});
    } catch (_) {
      return null;
    }
  }

  /// Opens Android's Bluetooth settings (manual pairing fallback).
  static Future<void> openBluetoothSettings() async {
    try {
      await _bond.invokeMethod('openBluetoothSettings');
    } catch (_) {}
  }

  /// True if Android has this camera in its paired devices.
  static Future<bool> isPaired(String address) async =>
      await _bondState(address) == 12;

  /// Uses Android's own pairing (with its "Pair with GoPro…?" prompt) when
  /// the phone isn't paired with the camera yet. Waits up to 45 s.
  Future<void> _ensurePaired(
      BluetoothDevice device, void Function(String?)? pairing) async {
    final address = device.remoteId.str;
    final state = await _bondState(address);
    logConnect('Bluetooth: phone pairing state = '
        '${{
              10: 'not paired',
              11: 'pairing',
              12: 'paired'
            }[state] ?? 'unknown'}');
    if (state == null || state == 12) return;
    pairing?.call('Pairing the phone with the camera…');
    String? how;
    try {
      how = await _bond.invokeMethod<String>('bondLe', {'address': address});
      logConnect('Bluetooth: system pairing request: $how');
    } catch (e) {
      logConnect('Bluetooth: system pairing could not start: $e');
    }
    if (how == null || how == 'failed') {
      pairing?.call(null);
      return;
    }
    final sw = Stopwatch()..start();
    int? s = state;
    var sawPairing = false;
    while (sw.elapsed < const Duration(seconds: 45)) {
      await Future.delayed(const Duration(milliseconds: 500));
      s = await _bondState(address);
      if (s == 11) sawPairing = true;
      if (s == 12) break;
      // Back to "not paired" after pairing started = refused or failed.
      if (s == 10 && (sawPairing || sw.elapsed > const Duration(seconds: 15))) {
        break;
      }
    }
    logConnect(
        'Bluetooth: pairing ${s == 12 ? 'succeeded' : 'did not complete (state $s)'} '
        'after ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
    pairing?.call(null);
    if (s == 12) await Future.delayed(const Duration(seconds: 1));
  }

  static String _describe(Object e) => e is FlutterBluePlusException
      ? '${e.function}: code ${e.code} ${e.description ?? ''}'
      : '$e';

  /// Pairing, service discovery and notifications on an established link.
  Future<void> _setUpLink(BluetoothDevice device,
      {required bool clearCache}) async {
    if (Platform.isAndroid) {
      // Let the link settle before pairing / discovery (older phones need it).
      await Future.delayed(const Duration(milliseconds: 1000));
      if (clearCache) {
        try {
          await device.clearGattCache();
          logConnect('Bluetooth: cleared Android\'s cached service list');
        } catch (_) {}
      }
      // GoPro characteristics require an encrypted (bonded) link.
      var bonded = false;
      try {
        bonded =
            await device.bondState.first.timeout(const Duration(seconds: 2)) ==
                BluetoothBondState.bonded;
      } catch (_) {}
      if (!bonded) {
        logConnect('Bluetooth: pairing with camera');
        try {
          await device.createBond(timeout: 60);
        } catch (e) {
          logConnect('Bluetooth: pairing request: ${_describe(e)}');
        }
      }
    }

    final services = await device.discoverServices(timeout: 30);
    _chars.clear();
    for (final s in services) {
      for (final c in s.characteristics) {
        _chars[c.uuid] = c;
      }
    }
    for (final id in [_command, _settings, _wifiSsid, _wifiPassword]) {
      if (!_chars.containsKey(id)) {
        throw Exception(
            'This camera does not expose the Open GoPro API (needs HERO9 or newer)');
      }
    }

    // Subscribing to the response characteristics triggers pairing on iOS.
    for (final s in _respSubs) {
      await s.cancel();
    }
    _respSubs.clear();
    _assemblers.clear();
    for (final id in [_commandResp, _settingsResp, _queryResp]) {
      final c = _chars[id];
      if (c == null) continue;
      await c.setNotifyValue(true, timeout: 30);
      _respSubs.add(c.onValueReceived.listen((v) => _onResponse(id, v)));
    }
  }

  void _onResponse(Guid source, List<int> v) {
    final msg =
        _assemblers.putIfAbsent(source, GoProPacketAssembler.new).add(v);
    if (msg == null || msg.length < 2) return;
    // Message: [command / query / setting id, status, ...data]
    final p = source == _commandResp
        ? _pendingCommand
        : source == _queryResp
            ? _pendingQuery
            : source == _settingsResp
                ? _pendingSetting
                : null;
    if (p != null && msg[0] == p.commandId && !p.completer.isCompleted) {
      p.completer.complete(msg.sublist(1)); // [status, ...data]
    }
  }

  /// Sends a query ([queryId] + [ids]) and returns [status, ...data].
  Future<List<int>> _sendQuery(int queryId, List<int> ids,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final c = _chars[_query];
    if (c == null) throw Exception('Camera does not support queries');
    final pending = _Pending(queryId);
    _pendingQuery = pending;
    await c.write([ids.length + 1, queryId, ...ids], withoutResponse: false);
    return pending.completer.future.timeout(timeout,
        onTimeout: () => throw Exception(
            'GoPro did not answer query 0x${queryId.toRadixString(16)}'));
  }

  /// Current value of every camera setting (query 0x12, no ids = all).
  Future<Map<int, int>> getSettingValues() async {
    final r =
        await _sendQuery(0x12, const [], timeout: const Duration(seconds: 8));
    if (r.first != 0) {
      throw Exception('Settings query failed (status ${r.first})');
    }
    return {for (final (id, v) in parseTlv(r.sublist(1))) id: uintOfBytes(v)};
  }

  /// Options the camera currently allows for each setting (query 0x32, no
  /// ids = all). These depend on other settings (e.g. lens vs RAW).
  Future<Map<int, List<int>>> getSettingCapabilities() async {
    final r =
        await _sendQuery(0x32, const [], timeout: const Duration(seconds: 8));
    if (r.first != 0) {
      throw Exception('Capabilities query failed (status ${r.first})');
    }
    final out = <int, List<int>>{};
    for (final (id, v) in parseTlv(r.sublist(1))) {
      (out[id] ??= []).add(uintOfBytes(v));
    }
    return out;
  }

  /// Sets one camera setting. Returns the camera's result code:
  /// 0 = done, 1 = failed, 2 = not allowed (invalid option or camera busy).
  Future<int> setSetting(int id, int value) async {
    final c = _chars[_settings]!;
    final pending = _Pending(id);
    _pendingSetting = pending;
    await c.write([3, id, 1, value], withoutResponse: false);
    final r = await pending.completer.future.timeout(const Duration(seconds: 5),
        onTimeout: () => throw Exception('GoPro did not answer setting $id'));
    return r.first;
  }

  /// Reads camera status values (query 0x13). Returns statusId -> raw bytes.
  Future<Map<int, List<int>>> getStatuses(List<int> ids) async {
    final resp = await _sendQuery(0x13, ids);
    if (resp.first != 0) {
      throw Exception('Status query failed (status ${resp.first})');
    }
    return parseStatusData(resp);
  }

  /// Parses a status-query response [status, (id, len, value...)*] into
  /// statusId -> raw value bytes.
  static Map<int, List<int>> parseStatusData(List<int> resp) {
    final out = <int, List<int>>{};
    var i = 1;
    while (i + 1 < resp.length) {
      final id = resp[i], len = resp[i + 1];
      if (i + 2 + len > resp.length) break;
      out[id] = resp.sublist(i + 2, i + 2 + len);
      i += 2 + len;
    }
    return out;
  }

  static int uintOf(List<int>? b) =>
      b == null ? -1 : b.fold(0, (v, x) => (v << 8) | x);

  /// Camera mode: status 89 (flat mode) and 96 (active preset group).
  Future<({int flatMode, int presetGroup})> getMode() async {
    final st = await getStatuses([89, 96]);
    return (flatMode: uintOf(st[89]), presetGroup: uintOf(st[96]));
  }

  /// Whether the camera's Wi-Fi access point is up (status 69).
  Future<bool> isApOn() async => uintOf((await getStatuses([69]))[69]) == 1;

  /// Sends a TLV command, waits for the response and returns the data that
  /// follows the status byte. Throws unless the status is 0 (success).
  Future<List<int>> _sendCommand(int commandId,
      [List<int> params = const []]) async {
    final c = _chars[_command]!;
    final pending = _Pending(commandId);
    _pendingCommand = pending;
    final payload = [commandId, ...params];
    await c.write([payload.length, ...payload], withoutResponse: false);
    final resp = await pending.completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw Exception(
          'GoPro did not answer command 0x${commandId.toRadixString(16)}'),
    );
    if (resp.first != 0) {
      throw Exception(
          'GoPro rejected command 0x${commandId.toRadixString(16)} (status ${resp.first})');
    }
    return resp.sublist(1);
  }

  void _startKeepAlive() {
    _keepAlive?.cancel();
    // Setting 91 (keep alive) = 66, recommended every 3 s.
    _keepAlive = Timer.periodic(const Duration(seconds: 3), (_) async {
      try {
        await _chars[_settings]
            ?.write([0x03, 0x5B, 0x01, 0x42], withoutResponse: false);
      } catch (_) {}
    });
  }

  Future<({String ssid, String password})> readWifiCredentials() async {
    final ssid =
        utf8.decode(await _chars[_wifiSsid]!.read(), allowMalformed: true);
    final pass =
        utf8.decode(await _chars[_wifiPassword]!.read(), allowMalformed: true);
    return (ssid: ssid.trim(), password: pass.trim());
  }

  /// Turns on the camera's Wi-Fi access point.
  Future<void> enableWifiAp() => _sendCommand(0x17, [0x01, 0x01]);

  /// Switches the camera to the Photo preset group (id 1001).
  Future<void> loadPhotoPresetGroup() => _sendCommand(0x3E, [0x02, 0x03, 0xE9]);

  /// Reads the camera's clock (command 0x0E). The response data is
  /// [7, year hi, year lo, month, day, hour, minute, second] in camera local time.
  Future<DateTime> getLocalDateTime() async {
    final d = await _sendCommand(0x0E);
    if (d.length < 8) {
      throw Exception('Unexpected date/time response from camera');
    }
    return DateTime((d[1] << 8) | d[2], d[3], d[4], d[5], d[6], d[7]);
  }

  /// Sets the camera's clock to the phone's local time (command 0x0F:
  /// date/time + UTC offset in minutes + DST flag), so the photo's own
  /// DateTime tags are correct.
  Future<void> setLocalDateTime(DateTime t) async {
    final tz = t.timeZoneOffset.inMinutes;
    await _sendCommand(0x0F, [
      10, // length of the date/time parameter
      t.year >> 8, t.year & 0xFF, t.month, t.day, t.hour, t.minute, t.second,
      (tz >> 8) & 0xFF, tz & 0xFF, // int16 big-endian
      0, // DST already included in the offset
    ]);
  }

  /// Presses the shutter (takes a photo in Photo mode).
  Future<void> shutter() => _sendCommand(0x01, [0x01, 0x01]);

  Future<void> disconnect() async {
    _keepAlive?.cancel();
    for (final s in [..._subs, ..._respSubs]) {
      await s.cancel();
    }
    _subs.clear();
    _respSubs.clear();
    await _device?.disconnect();
    _device = null;
  }
}

class _Pending {
  final int commandId;
  final completer = Completer<List<int>>();
  _Pending(this.commandId);
}

/// The phone could not connect and is not paired with the camera: the user
/// needs to pair it (camera in pairing mode, then Android Bluetooth settings).
class NotPairedException implements Exception {
  final String address;
  final int? code;
  NotPairedException(this.address, this.code);
  @override
  String toString() => 'The phone is not paired with the camera '
      '(Bluetooth error${code == null ? '' : ' $code'}).';
}
