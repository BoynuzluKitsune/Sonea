import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReplayGainMode { off, track, album }

class ReplayGainState {
  const ReplayGainState({
    this.mode = ReplayGainMode.track,
    this.preAmpGainDb = 0.0,
    this.preventClipping = true,
  });

  final ReplayGainMode mode;
  final double preAmpGainDb; // -6.0 to +6.0 dB
  final bool preventClipping;

  ReplayGainState copyWith({
    ReplayGainMode? mode,
    double? preAmpGainDb,
    bool? preventClipping,
  }) {
    return ReplayGainState(
      mode: mode ?? this.mode,
      preAmpGainDb: preAmpGainDb ?? this.preAmpGainDb,
      preventClipping: preventClipping ?? this.preventClipping,
    );
  }

  double computeVolumeMultiplier({
    double? trackGainDb,
    double? albumGainDb,
    double? trackPeak,
  }) {
    if (mode == ReplayGainMode.off) return 1.0;

    double? selectedGain = (mode == ReplayGainMode.album)
        ? (albumGainDb ?? trackGainDb)
        : (trackGainDb ?? albumGainDb);

    if (selectedGain == null && preAmpGainDb == 0.0) return 1.0;

    final gainToUse = selectedGain ?? 0.0;
    final totalDb = gainToUse + preAmpGainDb;
    double multiplier = math.pow(10.0, totalDb / 20.0).toDouble();

    if (preventClipping && trackPeak != null && trackPeak > 0) {
      final maxAllowed = 1.0 / trackPeak;
      multiplier = math.min(multiplier, maxAllowed);
    }

    return multiplier.clamp(0.0, 1.0);
  }
}

final replayGainControllerProvider =
    NotifierProvider<ReplayGainController, ReplayGainState>(
        ReplayGainController.new);

class ReplayGainController extends Notifier<ReplayGainState> {
  static const _kModeKey = 'rg_mode';
  static const _kPreAmpKey = 'rg_preamp';
  static const _kClippingKey = 'rg_prevent_clipping';

  @override
  ReplayGainState build() {
    _loadFromPrefs();
    return const ReplayGainState();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIdx = prefs.getInt(_kModeKey) ?? ReplayGainMode.track.index;
    final preAmp = prefs.getDouble(_kPreAmpKey) ?? 0.0;
    final clipping = prefs.getBool(_kClippingKey) ?? true;

    state = ReplayGainState(
      mode: ReplayGainMode.values[modeIdx.clamp(0, ReplayGainMode.values.length - 1)],
      preAmpGainDb: preAmp,
      preventClipping: clipping,
    );
  }

  Future<void> setMode(ReplayGainMode mode) async {
    state = state.copyWith(mode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kModeKey, mode.index);
  }

  Future<void> setPreAmpGainDb(double gainDb) async {
    state = state.copyWith(preAmpGainDb: gainDb.clamp(-6.0, 6.0));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kPreAmpKey, state.preAmpGainDb);
  }

  Future<void> setPreventClipping(bool prevent) async {
    state = state.copyWith(preventClipping: prevent);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kClippingKey, prevent);
  }

  Future<void> resetToDefaults() async {
    state = const ReplayGainState();
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.remove(_kModeKey),
      prefs.remove(_kPreAmpKey),
      prefs.remove(_kClippingKey),
    ]);
  }
}
