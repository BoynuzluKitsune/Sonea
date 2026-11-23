import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonea/settings/app_settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AppSettingsController persists all preferences across restarts', () async {
    SharedPreferences.setMockInitialValues({});

    final c1 = ProviderContainer();
    final ctrl1 = c1.read(appSettingsProvider.notifier);
    await ctrl1.setListDensity(ListDensity.comfortable);
    await ctrl1.setTextScale(AppTextScale.large);
    await ctrl1.setCoverCornerStyle(CoverCornerStyle.rounded);
    await ctrl1.setNowPlayingBgEffect(NowPlayingBgEffect.rich);
    await ctrl1.setPauseOnNoisy(false);
    await ctrl1.setInterruptionBehavior(AudioInterruptionBehavior.pause);
    await ctrl1.setSkipSeconds(30);
    await ctrl1.setPlaybackSpeed(1.5);
    await ctrl1.setGaplessPlayback(false);
    await ctrl1.setAutoScanOnStartup(false);
    await ctrl1.setAutoFetchLyrics(false);
    await ctrl1.setLyricsFontSize(LyricsFontSize.large);
    await ctrl1.setLyricsAlignment(LyricsAlignment.left);
    await ctrl1.setLyricsAutoScroll(false);
    await ctrl1.setJapaneseTransliteration(false);
    c1.dispose();

    // Re-create container to verify SharedPreferences reload.
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    c2.read(appSettingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final loaded = c2.read(appSettingsProvider);
    expect(loaded.listDensity, ListDensity.comfortable);
    expect(loaded.textScale, AppTextScale.large);
    expect(loaded.coverCornerStyle, CoverCornerStyle.rounded);
    expect(loaded.nowPlayingBgEffect, NowPlayingBgEffect.rich);
    expect(loaded.pauseOnNoisy, isFalse);
    expect(loaded.interruptionBehavior, AudioInterruptionBehavior.pause);
    expect(loaded.skipSeconds, 30);
    expect(loaded.playbackSpeed, 1.5);
    expect(loaded.gaplessPlayback, isFalse);
    expect(loaded.autoScanOnStartup, isFalse);
    expect(loaded.autoFetchLyrics, isFalse);
    expect(loaded.lyricsFontSize, LyricsFontSize.large);
    expect(loaded.lyricsAlignment, LyricsAlignment.left);
    expect(loaded.lyricsAutoScroll, isFalse);
    expect(loaded.japaneseTransliteration, isFalse);

    // Reset to recommended defaults restores smart values.
    await c2.read(appSettingsProvider.notifier).resetToDefaults();
    final reset = c2.read(appSettingsProvider);
    expect(reset.gaplessPlayback, isTrue);
    expect(reset.autoFetchLyrics, isTrue);
    expect(reset.japaneseTransliteration, isTrue);
    expect(reset.listDensity, ListDensity.normal);
  });
}
