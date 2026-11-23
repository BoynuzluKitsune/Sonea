import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class EqualizerState {
  const EqualizerState({
    this.enabled = false,
    this.presetName = 'Flat',
    this.bandGains = const [0.0, 0.0, 0.0, 0.0, 0.0],
  });

  final bool enabled;
  final String presetName;
  final List<double> bandGains; // in dB (-12.0 to +12.0)

  EqualizerState copyWith({
    bool? enabled,
    String? presetName,
    List<double>? bandGains,
  }) {
    return EqualizerState(
      enabled: enabled ?? this.enabled,
      presetName: presetName ?? this.presetName,
      bandGains: bandGains ?? this.bandGains,
    );
  }
}

final equalizerControllerProvider =
    NotifierProvider<EqualizerController, EqualizerState>(
        EqualizerController.new);

class EqualizerController extends Notifier<EqualizerState> {
  static const _kEnabledKey = 'eq_enabled';
  static const _kPresetKey = 'eq_preset';
  static const _kBandGainsKey = 'eq_band_gains';

  static const Map<String, List<double>> presets = {
    'Flat': [0.0, 0.0, 0.0, 0.0, 0.0],
    'Bass Boost': [6.0, 4.0, 0.0, 1.0, 2.0],
    'Vocal': [-2.0, 2.0, 5.0, 3.0, -1.0],
    'Rock': [4.0, 2.0, -1.0, 3.0, 5.0],
    'Electronic': [5.0, 3.0, 0.0, 2.0, 4.0],
  };

  @override
  EqualizerState build() {
    _loadFromPrefs();
    return const EqualizerState();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_kEnabledKey) ?? false;
    final presetName = prefs.getString(_kPresetKey) ?? 'Flat';
    final gainsStr = prefs.getStringList(_kBandGainsKey);

    List<double> gains = presets[presetName] ?? [0.0, 0.0, 0.0, 0.0, 0.0];
    if (gainsStr != null && gainsStr.length == 5) {
      gains = gainsStr.map((s) => double.tryParse(s) ?? 0.0).toList();
    }

    state = EqualizerState(
      enabled: enabled,
      presetName: presetName,
      bandGains: gains,
    );
  }

  Future<void> _saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, state.enabled);
    await prefs.setString(_kPresetKey, state.presetName);
    await prefs.setStringList(
      _kBandGainsKey,
      state.bandGains.map((g) => g.toStringAsFixed(1)).toList(),
    );
  }

  void setEnabled(bool enabled) {
    state = state.copyWith(enabled: enabled);
    _saveToPrefs();
  }

  void selectPreset(String name) {
    final gains = presets[name];
    if (gains != null) {
      state = state.copyWith(
        presetName: name,
        bandGains: List.from(gains),
      );
      _saveToPrefs();
    }
  }

  void setBandGain(int index, double gainDb) {
    if (index < 0 || index >= 5) return;
    final newGains = List<double>.from(state.bandGains);
    newGains[index] = gainDb.clamp(-12.0, 12.0);
    state = state.copyWith(
      presetName: 'Custom',
      bandGains: newGains,
    );
    _saveToPrefs();
  }
}
