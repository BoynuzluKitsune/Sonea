import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

final themeControllerProvider =
    NotifierProvider<ThemeController, SoneaThemeTokens>(ThemeController.new);

class ThemeController extends Notifier<SoneaThemeTokens> {
  static const _kPackIdKey = 'theme_pack_id';
  static const _kThemeModeKey = 'theme_appearance_mode';
  static const _kCornerRadiusKey = 'theme_corner_radius';
  static const _kFormatBadgesKey = 'theme_format_badges';
  static const _kTrackDurationKey = 'theme_track_duration';
  static const _kCompactListKey = 'theme_compact_list';
  static const _kDynamicGlowKey = 'theme_dynamic_glow';
  static const _kStartupTabKey = 'theme_startup_tab';
  static const _kProgressStyleKey = 'theme_progress_style';
  static const _kAlphabetScrollerKey = 'theme_alphabet_scroller';

  SharedPreferences? _prefs;
  bool _hasCustomCornerRadius = false;

  @override
  SoneaThemeTokens build() {
    _initPrefs();
    final brightness = _effectiveBrightnessFor(ThemeMode.system);
    return SoneaThemePalette.wada255
        .forBrightness(brightness)
        .copyWith(themeMode: ThemeMode.system);
  }

  Future<SharedPreferences> _ensurePrefs() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  ThemeMode _decodeThemeMode(String? raw) {
    return switch (raw) {
      'system' => ThemeMode.system,
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  String _encodeThemeMode(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.system => 'system',
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
    };
  }

  Brightness _effectiveBrightnessFor(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
    };
  }

  Future<void> _initPrefs() async {
    final prefs = await _ensurePrefs();
    final savedPackId = prefs.getString(_kPackIdKey);
    final palette = SoneaThemePalette.findById(savedPackId);

    // Migrate removed legacy theme IDs cleanly to 'wada_255'.
    if (savedPackId != null && savedPackId != palette.id) {
      await prefs.setString(_kPackIdKey, palette.id);
    }

    final mode = _decodeThemeMode(prefs.getString(_kThemeModeKey));
    final brightness = _effectiveBrightnessFor(mode);
    final basePack = palette.forBrightness(brightness);

    final customRadius = prefs.getDouble(_kCornerRadiusKey);
    _hasCustomCornerRadius = customRadius != null;
    final customBadges = prefs.getBool(_kFormatBadgesKey) ?? false;
    final customDuration = prefs.getBool(_kTrackDurationKey) ?? true;
    final customCompact = prefs.getBool(_kCompactListKey) ?? false;
    final customGlow = prefs.getBool(_kDynamicGlowKey) ?? true;
    final customStartupTab = prefs.getInt(_kStartupTabKey) ?? 1;
    final customStyleIdx =
        prefs.getInt(_kProgressStyleKey) ?? ProgressBarStyle.thinLine.index;
    final customScroller = prefs.getBool(_kAlphabetScrollerKey) ?? true;

    state = basePack.copyWith(
      themeMode: mode,
      cornerRadius: customRadius,
      showFormatBadges: customBadges,
      showTrackDuration: customDuration,
      compactListMode: customCompact,
      useDynamicCoverGlow: customGlow,
      startupTab: customStartupTab,
      progressBarStyle: ProgressBarStyle.values[
          customStyleIdx.clamp(0, ProgressBarStyle.values.length - 1)],
      showAlphabetScroller: customScroller,
    );
  }

  Future<void> selectPack(String packId) async {
    final palette = SoneaThemePalette.findById(packId);
    final brightness = _effectiveBrightnessFor(state.themeMode);
    final basePack = palette.forBrightness(brightness);

    state = basePack.copyWith(
      themeMode: state.themeMode,
      cornerRadius: _hasCustomCornerRadius ? state.cornerRadius : null,
      showFormatBadges: state.showFormatBadges,
      showTrackDuration: state.showTrackDuration,
      compactListMode: state.compactListMode,
      useDynamicCoverGlow: state.useDynamicCoverGlow,
      startupTab: state.startupTab,
      progressBarStyle: state.progressBarStyle,
      showAlphabetScroller: state.showAlphabetScroller,
    );

    final prefs = await _ensurePrefs();
    await prefs.setString(_kPackIdKey, palette.id);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (state.themeMode == mode) return;
    final palette = SoneaThemePalette.findById(state.packId);
    final brightness = _effectiveBrightnessFor(mode);
    final basePack = palette.forBrightness(brightness);

    state = basePack.copyWith(
      themeMode: mode,
      cornerRadius: _hasCustomCornerRadius ? state.cornerRadius : null,
      showFormatBadges: state.showFormatBadges,
      showTrackDuration: state.showTrackDuration,
      compactListMode: state.compactListMode,
      useDynamicCoverGlow: state.useDynamicCoverGlow,
      startupTab: state.startupTab,
      progressBarStyle: state.progressBarStyle,
      showAlphabetScroller: state.showAlphabetScroller,
    );

    final prefs = await _ensurePrefs();
    await prefs.setString(_kThemeModeKey, _encodeThemeMode(mode));
  }

  Future<void> setCornerRadius(double radius) async {
    _hasCustomCornerRadius = true;
    state = state.copyWith(cornerRadius: radius);
    final prefs = await _ensurePrefs();
    await prefs.setDouble(_kCornerRadiusKey, radius);
  }

  Future<void> setCornerStyle(SoneaCornerStyle style) async {
    final radius = switch (style) {
      SoneaCornerStyle.sharp => 4.0,
      SoneaCornerStyle.soft => 12.0,
      SoneaCornerStyle.rounded => 20.0,
    };
    await setCornerRadius(radius);
  }

  Future<void> setShowFormatBadges(bool show) async {
    state = state.copyWith(showFormatBadges: show);
    final prefs = await _ensurePrefs();
    await prefs.setBool(_kFormatBadgesKey, show);
  }

  Future<void> setShowTrackDuration(bool show) async {
    state = state.copyWith(showTrackDuration: show);
    final prefs = await _ensurePrefs();
    await prefs.setBool(_kTrackDurationKey, show);
  }

  Future<void> setCompactListMode(bool compact) async {
    state = state.copyWith(compactListMode: compact);
    final prefs = await _ensurePrefs();
    await prefs.setBool(_kCompactListKey, compact);
  }

  Future<void> setUseDynamicCoverGlow(bool glow) async {
    state = state.copyWith(useDynamicCoverGlow: glow);
    final prefs = await _ensurePrefs();
    await prefs.setBool(_kDynamicGlowKey, glow);
  }

  Future<void> setStartupTab(int tab) async {
    state = state.copyWith(startupTab: tab);
    final prefs = await _ensurePrefs();
    await prefs.setInt(_kStartupTabKey, tab);
  }

  Future<void> setProgressBarStyle(ProgressBarStyle style) async {
    state = state.copyWith(progressBarStyle: style);
    final prefs = await _ensurePrefs();
    await prefs.setInt(_kProgressStyleKey, style.index);
  }

  Future<void> setShowAlphabetScroller(bool show) async {
    state = state.copyWith(showAlphabetScroller: show);
    final prefs = await _ensurePrefs();
    await prefs.setBool(_kAlphabetScrollerKey, show);
  }

  /// Restores Sonea's recommended visual defaults cleanly without touching
  /// any library, playlist, favorite, or lyrics data.
  Future<void> resetToDefaults() async {
    _hasCustomCornerRadius = false;
    final brightness = _effectiveBrightnessFor(ThemeMode.system);
    state = SoneaThemePalette.wada255.forBrightness(brightness).copyWith(
          themeMode: ThemeMode.system,
          progressBarStyle: ProgressBarStyle.thinLine,
          useDynamicCoverGlow: true,
          showFormatBadges: false,
          showTrackDuration: true,
          compactListMode: false,
          showAlphabetScroller: true,
          startupTab: 1,
        );

    final prefs = await _ensurePrefs();
    await Future.wait([
      prefs.remove(_kPackIdKey),
      prefs.remove(_kThemeModeKey),
      prefs.remove(_kCornerRadiusKey),
      prefs.remove(_kFormatBadgesKey),
      prefs.remove(_kTrackDurationKey),
      prefs.remove(_kCompactListKey),
      prefs.remove(_kDynamicGlowKey),
      prefs.remove(_kStartupTabKey),
      prefs.remove(_kProgressStyleKey),
      prefs.remove(_kAlphabetScrollerKey),
    ]);
  }
}
