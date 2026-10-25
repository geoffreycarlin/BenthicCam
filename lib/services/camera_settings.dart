import 'package:flutter/foundation.dart';

import '../gopro/camera.dart';
import 'capture_service.dart';
import 'connection_log.dart';

/// One camera setting shown on the Camera settings screen, with the value
/// recommended for photo quadrat surveys.
///
/// Setting ids and option codes: Open GoPro spec (lens 122, photo output
/// 125, control mode 175) and the long-standing GoPro photo Protune ids
/// (21 Protune, 22 white balance, 24 ISO max, 25 sharpness, 26 EV, 75 ISO
/// min, 82 RAW, 97 shutter). The camera itself says which settings and
/// options it supports, so anything a model lacks is shown as unavailable.
class CamSettingDef {
  final int id;
  final String name;

  /// Recommended value, as text ("1/250 s or 1/500 s").
  final String recommended;
  final String why;
  final Map<int, String> labels;

  /// Recommended options, best first. Any of them counts as "OK".
  final List<int> preferred;

  /// Acceptable in some conditions (starred in the list, but not counted
  /// as matching the recommendation).
  final List<int> alternates;

  /// Leave the row out entirely if the camera doesn't have this setting.
  final bool hideIfMissing;

  /// Leave the row out if the camera has this other setting (old RAW switch
  /// when the newer "Photo output" setting exists).
  final int? hideIfPresent;

  const CamSettingDef({
    required this.id,
    required this.name,
    required this.recommended,
    required this.why,
    required this.labels,
    required this.preferred,
    this.alternates = const [],
    this.hideIfMissing = false,
    this.hideIfPresent,
  });

  String label(int? v) => v == null ? '—' : labels[v] ?? 'Option $v';
  bool isOk(int? v) => v != null && preferred.contains(v);

  /// The option to suggest, given what the camera allows ([allowed] is null
  /// when the camera didn't say).
  int? suggest(int? current, List<int>? allowed) {
    if (isOk(current)) return current;
    if (allowed != null && allowed.isNotEmpty) {
      for (final p in preferred) {
        if (allowed.contains(p)) return p;
      }
      return null; // none of the recommended options is possible
    }
    return preferred.first;
  }
}

/// Linear lens codes differ between models (HERO9/10: 102, HERO11+: 28/32
/// by resolution, HERO13 lens mods: 37/38/44). Pick the linear lens that
/// matches the camera's current resolution when the camera doesn't list its
/// options.
class _LensDef extends CamSettingDef {
  const _LensDef()
      : super(
          id: 122,
          name: 'Digital lens',
          recommended: 'Linear',
          why: 'Straight lines stay straight, so the quadrat border is not '
              'bent by fisheye distortion.',
          labels: const {
            0: 'Wide 12 MP',
            10: 'Linear 12 MP',
            15: 'Wide 9 MP',
            19: 'Narrow',
            27: 'Wide 23 MP',
            28: 'Linear 23 MP',
            31: 'Wide 27 MP',
            32: 'Linear 27 MP',
            37: 'Linear 9 MP',
            38: 'Linear 13 MP',
            39: 'Wide 13 MP',
            40: 'Ultra Wide 13 MP',
            41: 'Ultra Wide 12 MP',
            44: 'Ultra Linear 13 MP',
            100: 'Max SuperView',
            101: 'Wide',
            102: 'Linear',
          },
          preferred: const [32, 28, 102, 10, 38, 37, 44],
        );

  @override
  int? suggest(int? current, List<int>? allowed) {
    if (isOk(current)) return current;
    if (allowed != null && allowed.isNotEmpty) {
      return super.suggest(current, allowed);
    }
    return switch (current) {
      27 => 28,
      31 => 32,
      0 || 41 => 10,
      39 || 40 => 38,
      15 => 37,
      _ => 102,
    };
  }
}

const _iso = {0: '800', 1: '400', 2: '200', 3: '100'};

/// In the order they are applied: Protune / Pro controls first (they unlock
/// the rest), then lens before RAW (RAW may depend on the lens), ISO min
/// before ISO max.
const List<CamSettingDef> surveySettings = [
  CamSettingDef(
    id: 175,
    name: 'Controls',
    recommended: 'Pro',
    why: 'Needed for manual shutter, ISO and other Protune settings on '
        'newer cameras.',
    labels: {0: 'Easy', 1: 'Pro'},
    preferred: [1],
    hideIfMissing: true,
  ),
  CamSettingDef(
    id: 21,
    name: 'Protune',
    recommended: 'On',
    why: 'Unlocks manual shutter, ISO, EV, white balance and sharpness.',
    labels: {0: 'Off', 1: 'On'},
    preferred: [1],
    hideIfMissing: true,
  ),
  _LensDef(),
  CamSettingDef(
    id: 125,
    name: 'Photo output',
    recommended: 'RAW (+ JPEG)',
    why: 'Saves a .GPR RAW file alongside the JPEG. RAW keeps the sensor '
        'data without the camera washing out features with aggressive JPEG '
        'processing. Note: this app downloads and GPS-tags the JPEG; the '
        'RAW stays on the SD card with the same file number.',
    labels: {0: 'Standard', 1: 'RAW', 2: 'HDR', 3: 'SuperPhoto'},
    preferred: [1],
  ),
  CamSettingDef(
    id: 82,
    name: 'RAW photo',
    recommended: 'On',
    why: 'Saves a .GPR RAW file alongside the JPEG.',
    labels: {0: 'Off', 1: 'On'},
    preferred: [1],
    hideIfMissing: true,
    hideIfPresent: 125,
  ),
  CamSettingDef(
    id: 97,
    name: 'Shutter speed',
    recommended: '1/250 s or 1/500 s',
    why: 'The person lowering the frame will shake and waves bounce the rig; '
        'a fast fixed shutter removes micro-blur on benthic organisms.',
    labels: {
      0: 'Auto',
      1: '1/125 s',
      2: '1/250 s',
      3: '1/500 s',
      4: '1/1000 s',
      5: '1/2000 s',
    },
    preferred: [2, 3],
  ),
  CamSettingDef(
    id: 26,
    name: 'EV compensation',
    recommended: '−0.5',
    why: 'Stops bright sun reflections (caustics) bleaching white corals, '
        'sand or shiny shells in the quadrat.',
    labels: {
      0: '+2.0',
      1: '+1.5',
      2: '+1.0',
      3: '+0.5',
      4: '0',
      5: '−0.5',
      6: '−1.0',
      7: '−1.5',
      8: '−2.0',
    },
    preferred: [5],
  ),
  CamSettingDef(
    id: 75,
    name: 'ISO min',
    recommended: '100',
    why: 'Lowest noise when there is plenty of light.',
    labels: _iso,
    preferred: [3],
  ),
  CamSettingDef(
    id: 24,
    name: 'ISO max',
    recommended: '400 (800 on a deeply overcast day)',
    why: 'Capping ISO keeps digital grain from being mistaken for substrate '
        'texture.',
    labels: _iso,
    preferred: [1],
    alternates: [0],
  ),
  CamSettingDef(
    id: 22,
    name: 'White balance',
    recommended: 'Auto, or 5500 K fixed',
    why: 'Use 5500 K if you will colour-correct the whole batch later with a '
        'standard target profile; otherwise Auto.',
    labels: {
      0: 'Auto',
      1: '3000 K',
      2: '5500 K',
      3: '6500 K',
      4: 'Native',
      5: '4000 K',
      6: '4800 K',
      7: '6000 K',
      8: '2300 K',
      9: '2800 K',
      10: '3200 K',
      11: '4500 K',
      12: '5000 K',
    },
    preferred: [0, 2],
  ),
  CamSettingDef(
    id: 25,
    name: 'Sharpness',
    recommended: 'Medium or Low',
    why: 'High sharpness adds digital artefacts around edges.',
    labels: {0: 'High', 1: 'Medium', 2: 'Low'},
    preferred: [1, 2],
  ),
];

/// A row on the screen: the setting, what the camera has now, and what the
/// user has chosen to apply.
class SettingRow {
  final CamSettingDef def;
  int? current;
  List<int>? allowed;
  int? choice;
  bool apply = false;
  String? result; // after Apply: what happened
  bool resultOk = true;

  SettingRow(this.def);

  bool get available => current != null;
  bool get ok => def.isOk(current);

  /// Options for the drop-down: what the camera allows, else our list.
  List<int> get options {
    final a = allowed;
    if (a != null && a.isNotEmpty) return a;
    return def.labels.keys.toList();
  }
}

/// Reads and applies the survey settings on the connected camera.
class CameraSettingsController extends ChangeNotifier {
  final CaptureService svc;
  CameraSettingsController(this.svc,
      {List<CamSettingDef> defs = surveySettings})
      : _defs = defs;

  final List<CamSettingDef> _defs;
  List<SettingRow> rows = [];
  bool loading = false;
  bool applying = false;
  String? error;
  DateTime? readAt;

  bool get allOk => rows.isNotEmpty && rows.every((r) => !r.available || r.ok);
  int get toApply => rows.where((r) => r.apply && r.choice != null).length;

  /// Reads the camera's current settings and builds the rows.
  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      await svc.useCamera('Reading camera settings…', (cam) async {
        final values = await cam.getSettings();
        final caps = await _options(cam);
        logConnect('Camera settings read: ${values.length} settings, '
            '${caps.length} with options. Survey settings: '
            '${[
          for (final d in _defs) '${d.id}=${values[d.id] ?? '-'}'
        ].join(' ')}');
        rows = [
          for (final d in _defs)
            if (!(d.hideIfMissing && !values.containsKey(d.id)) &&
                !(d.hideIfPresent != null &&
                    values.containsKey(d.hideIfPresent)))
              SettingRow(d)
        ];
        _fill(values, caps, resetChoice: true);
      });
      readAt = DateTime.now();
    } catch (e) {
      error = 'Could not read the camera settings: '
          '${e.toString().replaceFirst('Exception: ', '')}';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<Map<int, List<int>>> _options(GoProCamera cam) async {
    try {
      return await cam.getSettingOptions();
    } catch (e) {
      logConnect('Camera did not list setting options: $e');
      return const {};
    }
  }

  void _fill(Map<int, int> values, Map<int, List<int>> caps,
      {required bool resetChoice}) {
    for (final r in rows) {
      r.current = values[r.def.id];
      r.allowed = caps[r.def.id];
      if (resetChoice) {
        r.choice = r.available ? r.def.suggest(r.current, r.allowed) : null;
        r.apply = r.available && !r.ok && r.choice != null;
      }
    }
  }

  void setChoice(SettingRow r, int v) {
    r.choice = v;
    r.apply = v != r.current;
    notifyListeners();
  }

  void setApply(SettingRow r, bool v) {
    r.apply = v;
    notifyListeners();
  }

  /// Ticks every setting that isn't at a recommended value.
  void selectAllRecommended() {
    for (final r in rows) {
      if (!r.available) continue;
      r.choice = r.def.suggest(r.current, r.allowed);
      r.apply = !r.ok && r.choice != null;
    }
    notifyListeners();
  }

  /// Applies the ticked settings in order, then reads everything back.
  Future<void> apply() async {
    applying = true;
    error = null;
    for (final r in rows) {
      r.result = null;
    }
    notifyListeners();
    try {
      await svc.useCamera('Changing camera settings…', (cam) async {
        // Photo settings belong to the photo preset: be in Photo mode first.
        try {
          final m = await cam.getMode();
          if (!m.isPhoto) await cam.setPhotoMode();
        } catch (_) {}
        var caps = await _options(cam);
        for (final r in rows) {
          final v = r.choice;
          if (!r.apply || v == null) continue;
          final allowed = caps[r.def.id];
          if (allowed != null && allowed.isNotEmpty && !allowed.contains(v)) {
            r.result = 'Camera does not allow ${r.def.label(v)} with the '
                'other current settings';
            r.resultOk = false;
            notifyListeners();
            continue;
          }
          int code;
          try {
            code = await cam.setSetting(r.def.id, v);
          } catch (e) {
            code = -1;
          }
          logConnect('Set ${r.def.name} (${r.def.id}) = $v → result $code');
          r.resultOk = code == 0;
          r.result = switch (code) {
            0 => 'Set to ${r.def.label(v)}',
            2 => 'Camera refused ${r.def.label(v)} (not allowed right now)',
            -1 => 'No answer from the camera',
            _ => 'Camera could not set ${r.def.label(v)}',
          };
          notifyListeners();
          // Settings unlock / restrict others: refresh the allowed options.
          await Future.delayed(const Duration(milliseconds: 250));
          caps = await _options(cam);
        }
        final values = await cam.getSettings();
        _fill(values, caps, resetChoice: false);
        for (final r in rows) {
          if (r.result != null && r.resultOk && r.current != r.choice) {
            r.result = '${r.result} — but the camera now reports '
                '${r.def.label(r.current)}';
            r.resultOk = false;
          }
          if (r.ok || r.current == r.choice) r.apply = false;
        }
      });
      readAt = DateTime.now();
    } catch (e) {
      error = 'Could not change the camera settings: '
          '${e.toString().replaceFirst('Exception: ', '')}';
    } finally {
      applying = false;
      notifyListeners();
    }
  }
}
