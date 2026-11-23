import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ListDensity { compact, normal, comfortable }

enum AppTextScale { small, normal, large }

enum CoverCornerStyle { sharp, soft, rounded }

enum NowPlayingBgEffect { off, subtle, rich }

enum AudioInterruptionBehavior { duck, pause }

enum LyricsFontSize { small, medium, large }

enum LyricsAlignment { left, center }

class AppSettings {
  const AppSettings({
    this.listDensity = ListDensity.normal,
    this.textScale = AppTextScale.normal,
    this.coverCornerStyle = CoverCornerStyle.soft,
    this.nowPlayingBgEffect = NowPlayingBgEffect.subtle,
    this.pauseOnNoisy = true,
    this.interruptionBehavior = AudioInterruptionBehavior.duck,
    this.skipSeconds = 10,
    this.playbackSpeed = 1.0,
    this.gaplessPlayback = true,
    this.autoScanOnStartup = true,
    this.autoFetchLyrics = true,
    this.lyricsFontSize = LyricsFontSize.medium,
    this.lyricsAlignment = LyricsAlignment.center,
    this.lyricsAutoScroll = true,
    this.japaneseTransliteration = true,
    this.hasCompletedOnboarding = true,
    this.isLoaded = false,
  });

  final ListDensity listDensity;
  final AppTextScale textScale;
  final CoverCornerStyle coverCornerStyle;
  final NowPlayingBgEffect nowPlayingBgEffect;
  final bool pauseOnNoisy;
  final AudioInterruptionBehavior interruptionBehavior;
  final int skipSeconds;
  final double playbackSpeed;
  final bool gaplessPlayback;
  final bool autoScanOnStartup;
  final bool autoFetchLyrics;
  final LyricsFontSize lyricsFontSize;
  final LyricsAlignment lyricsAlignment;
  final bool lyricsAutoScroll;
  final bool japaneseTransliteration;
  final bool hasCompletedOnboarding;
  final bool isLoaded;

  double get trackRowHeight => switch (listDensity) {
        ListDensity.compact => 54.0,
        ListDensity.normal => 64.0,
        ListDensity.comfortable => 76.0,
      };

  double get trackArtworkSize => switch (listDensity) {
        ListDensity.compact => 36.0,
        ListDensity.normal => 46.0,
        ListDensity.comfortable => 54.0,
      };

  double get textScaleFactor => switch (textScale) {
        AppTextScale.small => 0.90,
        AppTextScale.normal => 1.0,
        AppTextScale.large => 1.12,
      };

  double get coverCornerRadius => switch (coverCornerStyle) {
        CoverCornerStyle.sharp => 4.0,
        CoverCornerStyle.soft => 12.0,
        CoverCornerStyle.rounded => 20.0,
      };

  double get lyricsActiveFontSize => switch (lyricsFontSize) {
        LyricsFontSize.small => 19.0,
        LyricsFontSize.medium => 22.0,
        LyricsFontSize.large => 26.0,
      };

  double get lyricsInactiveFontSize => switch (lyricsFontSize) {
        LyricsFontSize.small => 14.0,
        LyricsFontSize.medium => 16.0,
        LyricsFontSize.large => 19.0,
      };

  AppSettings copyWith({
    ListDensity? listDensity,
    AppTextScale? textScale,
    CoverCornerStyle? coverCornerStyle,
    NowPlayingBgEffect? nowPlayingBgEffect,
    bool? pauseOnNoisy,
    AudioInterruptionBehavior? interruptionBehavior,
    int? skipSeconds,
    double? playbackSpeed,
    bool? gaplessPlayback,
    bool? autoScanOnStartup,
    bool? autoFetchLyrics,
    LyricsFontSize? lyricsFontSize,
    LyricsAlignment? lyricsAlignment,
    bool? lyricsAutoScroll,
    bool? japaneseTransliteration,
    bool? hasCompletedOnboarding,
    bool? isLoaded,
  }) {
    return AppSettings(
      listDensity: listDensity ?? this.listDensity,
      textScale: textScale ?? this.textScale,
      coverCornerStyle: coverCornerStyle ?? this.coverCornerStyle,
      nowPlayingBgEffect: nowPlayingBgEffect ?? this.nowPlayingBgEffect,
      pauseOnNoisy: pauseOnNoisy ?? this.pauseOnNoisy,
      interruptionBehavior: interruptionBehavior ?? this.interruptionBehavior,
      skipSeconds: skipSeconds ?? this.skipSeconds,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      gaplessPlayback: gaplessPlayback ?? this.gaplessPlayback,
      autoScanOnStartup: autoScanOnStartup ?? this.autoScanOnStartup,
      autoFetchLyrics: autoFetchLyrics ?? this.autoFetchLyrics,
      lyricsFontSize: lyricsFontSize ?? this.lyricsFontSize,
      lyricsAlignment: lyricsAlignment ?? this.lyricsAlignment,
      lyricsAutoScroll: lyricsAutoScroll ?? this.lyricsAutoScroll,
      japaneseTransliteration:
          japaneseTransliteration ?? this.japaneseTransliteration,
      hasCompletedOnboarding:
          hasCompletedOnboarding ?? this.hasCompletedOnboarding,
      isLoaded: isLoaded ?? this.isLoaded,
    );
  }

  Map<String, dynamic> toJson() => {
        'listDensity': listDensity.index,
        'textScale': textScale.index,
        'coverCornerStyle': coverCornerStyle.index,
        'nowPlayingBgEffect': nowPlayingBgEffect.index,
        'pauseOnNoisy': pauseOnNoisy,
        'interruptionBehavior': interruptionBehavior.index,
        'skipSeconds': skipSeconds,
        'playbackSpeed': playbackSpeed,
        'gaplessPlayback': gaplessPlayback,
        'autoScanOnStartup': autoScanOnStartup,
        'autoFetchLyrics': autoFetchLyrics,
        'lyricsFontSize': lyricsFontSize.index,
        'lyricsAlignment': lyricsAlignment.index,
        'lyricsAutoScroll': lyricsAutoScroll,
        'japaneseTransliteration': japaneseTransliteration,
      };
}

final appSettingsProvider =
    NotifierProvider<AppSettingsController, AppSettings>(
  AppSettingsController.new,
);

class AppSettingsController extends Notifier<AppSettings> {
  static const _kListDensity = 'settings_list_density';
  static const _kTextScale = 'settings_text_scale';
  static const _kCoverCornerStyle = 'settings_cover_corner_style';
  static const _kNowPlayingBgEffect = 'settings_now_playing_bg_effect';
  static const _kPauseOnNoisy = 'settings_pause_on_noisy';
  static const _kInterruptionBehavior = 'settings_interruption_behavior';
  static const _kSkipSeconds = 'settings_skip_seconds';
  static const _kPlaybackSpeed = 'settings_playback_speed';
  static const _kGaplessPlayback = 'settings_gapless_playback';
  static const _kAutoScanOnStartup = 'settings_auto_scan_startup';
  static const _kAutoFetchLyrics = 'settings_auto_fetch_lyrics';
  static const _kLyricsFontSize = 'settings_lyrics_font_size';
  static const _kLyricsAlignment = 'settings_lyrics_alignment';
  static const _kLyricsAutoScroll = 'settings_lyrics_auto_scroll';
  static const _kJapaneseTranslit = 'settings_japanese_translit';
  static const _kOnboardingCompleted = 'settings_onboarding_completed';

  SharedPreferences? _prefs;

  @override
  AppSettings build() {
    _load();
    return const AppSettings();
  }

  Future<SharedPreferences> _ensurePrefs() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  Future<void> _load() async {
    final prefs = await _ensurePrefs();
    state = AppSettings(
      listDensity: ListDensity.values[
          (prefs.getInt(_kListDensity) ?? ListDensity.normal.index)
              .clamp(0, ListDensity.values.length - 1)],
      textScale: AppTextScale.values[
          (prefs.getInt(_kTextScale) ?? AppTextScale.normal.index)
              .clamp(0, AppTextScale.values.length - 1)],
      coverCornerStyle: CoverCornerStyle.values[
          (prefs.getInt(_kCoverCornerStyle) ?? CoverCornerStyle.soft.index)
              .clamp(0, CoverCornerStyle.values.length - 1)],
      nowPlayingBgEffect: NowPlayingBgEffect.values[
          (prefs.getInt(_kNowPlayingBgEffect) ??
                  NowPlayingBgEffect.subtle.index)
              .clamp(0, NowPlayingBgEffect.values.length - 1)],
      pauseOnNoisy: prefs.getBool(_kPauseOnNoisy) ?? true,
      interruptionBehavior: AudioInterruptionBehavior.values[
          (prefs.getInt(_kInterruptionBehavior) ??
                  AudioInterruptionBehavior.duck.index)
              .clamp(0, AudioInterruptionBehavior.values.length - 1)],
      skipSeconds: (prefs.getInt(_kSkipSeconds) ?? 10).clamp(5, 30),
      playbackSpeed: (prefs.getDouble(_kPlaybackSpeed) ?? 1.0).clamp(0.75, 2.0),
      gaplessPlayback: prefs.getBool(_kGaplessPlayback) ?? true,
      autoScanOnStartup: prefs.getBool(_kAutoScanOnStartup) ?? true,
      autoFetchLyrics: prefs.getBool(_kAutoFetchLyrics) ?? true,
      lyricsFontSize: LyricsFontSize.values[
          (prefs.getInt(_kLyricsFontSize) ?? LyricsFontSize.medium.index)
              .clamp(0, LyricsFontSize.values.length - 1)],
      lyricsAlignment: LyricsAlignment.values[
          (prefs.getInt(_kLyricsAlignment) ?? LyricsAlignment.center.index)
              .clamp(0, LyricsAlignment.values.length - 1)],
      lyricsAutoScroll: prefs.getBool(_kLyricsAutoScroll) ?? true,
      japaneseTransliteration: prefs.getBool(_kJapaneseTranslit) ?? true,
      hasCompletedOnboarding: prefs.getBool(_kOnboardingCompleted) ?? false,
      isLoaded: true,
    );
  }

  Future<void> completeOnboarding() async {
    state = state.copyWith(hasCompletedOnboarding: true, isLoaded: true);
    final prefs = await _ensurePrefs();
    await prefs.setBool(_kOnboardingCompleted, true);
  }

  Future<void> resetOnboarding() async {
    state = state.copyWith(hasCompletedOnboarding: false, isLoaded: true);
    final prefs = await _ensurePrefs();
    await prefs.setBool(_kOnboardingCompleted, false);
  }

  Future<void> setListDensity(ListDensity density) async {
    state = state.copyWith(listDensity: density);
    final prefs = await _ensurePrefs();
    await prefs.setInt(_kListDensity, density.index);
  }

  Future<void> setTextScale(AppTextScale scale) async {
    state = state.copyWith(textScale: scale);
    final prefs = await _ensurePrefs();
    await prefs.setInt(_kTextScale, scale.index);
  }

  Future<void> setCoverCornerStyle(CoverCornerStyle style) async {
    state = state.copyWith(coverCornerStyle: style);
    final prefs = await _ensurePrefs();
    await prefs.setInt(_kCoverCornerStyle, style.index);
  }

  Future<void> setNowPlayingBgEffect(NowPlayingBgEffect effect) async {
    state = state.copyWith(nowPlayingBgEffect: effect);
    final prefs = await _ensurePrefs();
    await prefs.setInt(_kNowPlayingBgEffect, effect.index);
  }

  Future<void> setPauseOnNoisy(bool value) async {
    state = state.copyWith(pauseOnNoisy: value);
    final prefs = await _ensurePrefs();
    await prefs.setBool(_kPauseOnNoisy, value);
  }

  Future<void> setInterruptionBehavior(AudioInterruptionBehavior behavior) async {
    state = state.copyWith(interruptionBehavior: behavior);
    final prefs = await _ensurePrefs();
    await prefs.setInt(_kInterruptionBehavior, behavior.index);
  }

  Future<void> setSkipSeconds(int seconds) async {
    final safe = seconds.clamp(5, 30);
    state = state.copyWith(skipSeconds: safe);
    final prefs = await _ensurePrefs();
    await prefs.setInt(_kSkipSeconds, safe);
  }

  Future<void> setPlaybackSpeed(double speed) async {
    final safe = speed.clamp(0.75, 2.0);
    state = state.copyWith(playbackSpeed: safe);
    final prefs = await _ensurePrefs();
    await prefs.setDouble(_kPlaybackSpeed, safe);
  }

  Future<void> setGaplessPlayback(bool value) async {
    state = state.copyWith(gaplessPlayback: value);
    final prefs = await _ensurePrefs();
    await prefs.setBool(_kGaplessPlayback, value);
  }

  Future<void> setAutoScanOnStartup(bool value) async {
    state = state.copyWith(autoScanOnStartup: value);
    final prefs = await _ensurePrefs();
    await prefs.setBool(_kAutoScanOnStartup, value);
  }

  Future<void> setAutoFetchLyrics(bool value) async {
    state = state.copyWith(autoFetchLyrics: value);
    final prefs = await _ensurePrefs();
    await prefs.setBool(_kAutoFetchLyrics, value);
  }

  Future<void> setLyricsFontSize(LyricsFontSize size) async {
    state = state.copyWith(lyricsFontSize: size);
    final prefs = await _ensurePrefs();
    await prefs.setInt(_kLyricsFontSize, size.index);
  }

  Future<void> setLyricsAlignment(LyricsAlignment alignment) async {
    state = state.copyWith(lyricsAlignment: alignment);
    final prefs = await _ensurePrefs();
    await prefs.setInt(_kLyricsAlignment, alignment.index);
  }

  Future<void> setLyricsAutoScroll(bool value) async {
    state = state.copyWith(lyricsAutoScroll: value);
    final prefs = await _ensurePrefs();
    await prefs.setBool(_kLyricsAutoScroll, value);
  }

  Future<void> setJapaneseTransliteration(bool value) async {
    state = state.copyWith(japaneseTransliteration: value);
    final prefs = await _ensurePrefs();
    await prefs.setBool(_kJapaneseTranslit, value);
  }

  Future<void> applyJson(Map<String, dynamic> map) async {
    if (map['listDensity'] is int) {
      await setListDensity(ListDensity.values[
          (map['listDensity'] as int).clamp(0, ListDensity.values.length - 1)]);
    }
    if (map['textScale'] is int) {
      await setTextScale(AppTextScale.values[
          (map['textScale'] as int).clamp(0, AppTextScale.values.length - 1)]);
    }
    if (map['coverCornerStyle'] is int) {
      await setCoverCornerStyle(CoverCornerStyle.values[
          (map['coverCornerStyle'] as int)
              .clamp(0, CoverCornerStyle.values.length - 1)]);
    }
    if (map['nowPlayingBgEffect'] is int) {
      await setNowPlayingBgEffect(NowPlayingBgEffect.values[
          (map['nowPlayingBgEffect'] as int)
              .clamp(0, NowPlayingBgEffect.values.length - 1)]);
    }
    if (map['pauseOnNoisy'] is bool) {
      await setPauseOnNoisy(map['pauseOnNoisy'] as bool);
    }
    if (map['interruptionBehavior'] is int) {
      await setInterruptionBehavior(AudioInterruptionBehavior.values[
          (map['interruptionBehavior'] as int)
              .clamp(0, AudioInterruptionBehavior.values.length - 1)]);
    }
    if (map['skipSeconds'] is int) {
      await setSkipSeconds(map['skipSeconds'] as int);
    }
    if (map['playbackSpeed'] is num) {
      await setPlaybackSpeed((map['playbackSpeed'] as num).toDouble());
    }
    if (map['gaplessPlayback'] is bool) {
      await setGaplessPlayback(map['gaplessPlayback'] as bool);
    }
    if (map['autoScanOnStartup'] is bool) {
      await setAutoScanOnStartup(map['autoScanOnStartup'] as bool);
    }
    if (map['autoFetchLyrics'] is bool) {
      await setAutoFetchLyrics(map['autoFetchLyrics'] as bool);
    }
    if (map['lyricsFontSize'] is int) {
      await setLyricsFontSize(LyricsFontSize.values[
          (map['lyricsFontSize'] as int)
              .clamp(0, LyricsFontSize.values.length - 1)]);
    }
    if (map['lyricsAlignment'] is int) {
      await setLyricsAlignment(LyricsAlignment.values[
          (map['lyricsAlignment'] as int)
              .clamp(0, LyricsAlignment.values.length - 1)]);
    }
    if (map['lyricsAutoScroll'] is bool) {
      await setLyricsAutoScroll(map['lyricsAutoScroll'] as bool);
    }
    if (map['japaneseTransliteration'] is bool) {
      await setJapaneseTransliteration(map['japaneseTransliteration'] as bool);
    }
  }

  /// Restores recommended playback, interface, and lyrics defaults while
  /// preserving onboarding completion state and user data.
  Future<void> resetToDefaults() async {
    final keepCompleted = state.hasCompletedOnboarding;
    state = AppSettings(
      hasCompletedOnboarding: keepCompleted,
      isLoaded: true,
    );
    final prefs = await _ensurePrefs();
    await Future.wait([
      prefs.remove(_kListDensity),
      prefs.remove(_kTextScale),
      prefs.remove(_kCoverCornerStyle),
      prefs.remove(_kNowPlayingBgEffect),
      prefs.remove(_kPauseOnNoisy),
      prefs.remove(_kInterruptionBehavior),
      prefs.remove(_kSkipSeconds),
      prefs.remove(_kPlaybackSpeed),
      prefs.remove(_kGaplessPlayback),
      prefs.remove(_kAutoScanOnStartup),
      prefs.remove(_kAutoFetchLyrics),
      prefs.remove(_kLyricsFontSize),
      prefs.remove(_kLyricsAlignment),
      prefs.remove(_kLyricsAutoScroll),
      prefs.remove(_kJapaneseTranslit),
    ]);
  }
}
