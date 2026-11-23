import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/playback/lyrics_controller.dart';
import 'package:sonea/playback/playback_backend.dart';
import 'package:sonea/playback/playback_controller.dart';
import 'package:sonea/src/rust/api/library.dart';
import 'package:sonea/src/rust/api/lyrics.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/theme/theme_controller.dart';
import 'package:sonea/ui/components/sonea_logo_mark.dart';
import 'package:sonea/ui/now_playing/synced_lyrics_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

class _TestPlaybackController extends PlaybackController {
  _TestPlaybackController(this._initial);
  final PlaybackStateData _initial;

  @override
  Future<PlaybackStateData> build() async => _initial;

  void switchTrack(Track track, Duration pos) {
    state = AsyncData(
      (state.value ?? _initial).copyWith(
        currentTrack: track,
        queue: [track],
        position: pos,
      ),
    );
  }
}

class _TestLyricsController extends LyricsController {
  _TestLyricsController(this._initial);
  final LyricsState _initial;

  @override
  LyricsState build() => _initial;

  void setLyricsState(LyricsState next) {
    state = next;
  }
}

void main() {
  group('Sanzo Wada 10 Curated 4-Color Theme System', () {
    test('provides exactly 10 Sanzo Wada 4-color palettes with plate numbers and bespoke fonts', () {
      expect(SoneaThemePalette.all.length, 10);
      expect(
        SoneaThemePalette.all.map((p) => p.id).toList(),
        [
          'wada_255',
          'wada_340',
          'wada_303',
          'wada_288',
          'wada_331',
          'wada_271',
          'wada_329',
          'wada_263',
          'wada_348',
          'wada_343',
        ],
      );

      final trStrings = const AppStrings(AppLanguage.tr);
      final enStrings = const AppStrings(AppLanguage.en);

      for (final palette in SoneaThemePalette.all) {
        expect(palette.paletteSwatches.length, 4, reason: '${palette.id} swatches');
        expect(palette.wadaNumber, startsWith('No. '), reason: '${palette.id} plate number');
        expect(palette.displayFontFamily, isNotEmpty, reason: '${palette.id} display font');
        expect(palette.bodyFontFamily, isNotEmpty, reason: '${palette.id} body font');
        expect(palette.dark.isLight, isFalse, reason: '${palette.id} dark');
        expect(palette.light.isLight, isTrue, reason: '${palette.id} light');
        expect(trStrings.themeName(palette.id), isNotEmpty);
        expect(enStrings.themeName(palette.id), isNotEmpty);
        expect(trStrings.themeMood(palette.id), isNotEmpty);
        expect(enStrings.themeMood(palette.id), isNotEmpty);
      }
    });

    test('all 10 Sanzo Wada palettes pass WCAG AA contrast (>= 4.5:1) in BOTH Dark and Light modes', () {
      for (final palette in SoneaThemePalette.all) {
        for (final mode in [palette.dark, palette.light]) {
          final label = '${palette.id}/${mode.isLight ? "light" : "dark"} (${palette.wadaNumber})';

          final textOnBg = _contrastRatio(mode.textColor, mode.backgroundColor);
          final textOnSurface = _contrastRatio(mode.textColor, mode.surfaceColor);
          final subOnSurface = _contrastRatio(mode.subtextColor, mode.surfaceColor);
          final onAccentContrast = _contrastRatio(mode.onAccentColor, mode.accentColor);

          expect(textOnBg, greaterThanOrEqualTo(7.0), reason: '$label text/bg');
          expect(textOnSurface, greaterThanOrEqualTo(7.0), reason: '$label text/surface');
          expect(subOnSurface, greaterThanOrEqualTo(4.5), reason: '$label subtext/surface');
          expect(onAccentContrast, greaterThanOrEqualTo(4.5), reason: '$label onAccent/accent');
        }
      }
    });

    test('migrates removed legacy theme IDs safely to wada_255 and preserves ThemeMode', () async {
      for (final legacyId in ['glacier', 'obsidian', 'vinylAmber', 'midnight_oled']) {
        SharedPreferences.setMockInitialValues({
          'theme_pack_id': legacyId,
          'theme_appearance_mode': 'light',
        });
        final container = ProviderContainer();
        addTearDown(container.dispose);

        container.read(themeControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final resolved = container.read(themeControllerProvider);
        expect(resolved.packId, 'wada_255', reason: 'Legacy $legacyId must migrate');
        expect(resolved.themeMode, ThemeMode.light);
        expect(resolved.isLight, isTrue);
        expect(resolved.accentColor, SoneaThemePalette.wada255.light.accentColor);
      }
    });

    test('persists paletteId and independent ThemeMode across restarts', () async {
      SharedPreferences.setMockInitialValues({});
      final c1 = ProviderContainer();
      addTearDown(c1.dispose);

      c1.read(themeControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await c1.read(themeControllerProvider.notifier).selectPack('wada_340');
      await c1.read(themeControllerProvider.notifier).setThemeMode(ThemeMode.light);

      final c2 = ProviderContainer();
      addTearDown(c2.dispose);
      c2.read(themeControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final restored = c2.read(themeControllerProvider);
      expect(restored.packId, 'wada_340');
      expect(restored.themeMode, ThemeMode.light);
      expect(restored.isLight, isTrue);
      expect(restored.accentColor, const Color(0xFF137A5B));
    });
  });

  group('Real Font Assets & Bespoke Per-Theme Typography', () {
    test('all 5 Inter and Plus Jakarta Sans TTF files exist on disk with valid headers', () {
      const files = [
        'assets/fonts/Inter-Regular.ttf',
        'assets/fonts/Inter-Medium.ttf',
        'assets/fonts/Inter-SemiBold.ttf',
        'assets/fonts/PlusJakartaSans-SemiBold.ttf',
        'assets/fonts/PlusJakartaSans-Bold.ttf',
      ];
      for (final path in files) {
        final f = File(path);
        expect(f.existsSync(), isTrue, reason: 'Missing font file $path');
        final bytes = f.readAsBytesSync();
        expect(bytes.length, greaterThan(10000), reason: 'Truncated font $path');
        expect(bytes.sublist(0, 4), [0x00, 0x01, 0x00, 0x00], reason: 'Invalid TTF header $path');
      }
    });

    test('ThemeData wires each theme display and body font with Turkish/CJK fallback', () {
      final wada255Theme = SoneaThemePalette.wada255.tokens.toThemeData();
      expect(wada255Theme.textTheme.displayLarge?.fontFamily, 'Plus Jakarta Sans');
      expect(wada255Theme.textTheme.bodyMedium?.fontFamily, 'Plus Jakarta Sans');
      expect(wada255Theme.textTheme.labelSmall?.fontFeatures, contains(const FontFeature.tabularFigures()));

      final wada343Theme = SoneaThemePalette.wada343.tokens.toThemeData();
      expect(wada343Theme.textTheme.displayLarge?.fontFamily, 'Lora');
      expect(wada343Theme.textTheme.bodyMedium?.fontFamily, 'IBM Plex Sans');
      expect(wada343Theme.textTheme.bodyMedium?.fontFamilyFallback, contains('Inter'));
      expect(wada343Theme.textTheme.bodyMedium?.fontFamilyFallback, contains('Noto Sans CJK JP'));

      final wada329Theme = SoneaThemePalette.wada329.tokens.toThemeData();
      expect(wada329Theme.textTheme.headlineLarge?.fontFamily, 'Fraunces');
      expect(wada329Theme.textTheme.bodyMedium?.fontFamily, 'Inter');
    });
  });

  group('Turkish & English Count Formatting', () {
    test('formats track and album counts without Turkish plural-after-number bug', () {
      const tr = AppStrings(AppLanguage.tr);
      const en = AppStrings(AppLanguage.en);

      expect(tr.trackCountLabel(0), '0 şarkı');
      expect(tr.trackCountLabel(1), '1 şarkı');
      expect(tr.trackCountLabel(188), '188 şarkı');
      expect(tr.trackCountLabel(188), isNot(contains('şarkılar')));

      expect(en.trackCountLabel(0), '0 tracks');
      expect(en.trackCountLabel(1), '1 track');
      expect(en.trackCountLabel(188), '188 tracks');

      expect(tr.albumCountLabel(3), '3 albüm');
      expect(en.albumCountLabel(1), '1 album');
      expect(en.albumCountLabel(3), '3 albums');
    });
  });

  group('Lifecycle & _dependents.isEmpty Regression Tests', () {
    testWidgets(
      'rapidly switching Wada palettes, tracks, and routes triggers zero framework assertions',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final track1 = Track(
          id: 1,
          path: '/music/one.flac',
          title: 'Track One',
          artist: 'Artist A',
          fileModified: 1,
          addedAt: 1,
          playCount: 0,
        );
        final track2 = Track(
          id: 2,
          path: '/music/two.flac',
          title: 'Track Two',
          artist: 'Artist B',
          fileModified: 1,
          addedAt: 1,
          playCount: 0,
        );
        final lines1 = List.generate(
          25,
          (i) => LyricLine(timeMs: (i + 1) * 4000, text: 'Song 1 Line $i'),
        );
        final lines2 = List.generate(
          20,
          (i) => LyricLine(timeMs: (i + 1) * 4000, text: 'Song 2 Line $i'),
        );

        final fakePlayback = _TestPlaybackController(
          PlaybackStateData(
            currentTrack: track1,
            queue: [track1, track2],
            isPlaying: true,
            position: const Duration(seconds: 40),
            duration: const Duration(minutes: 3),
          ),
        );
        final fakeLyrics = _TestLyricsController(
          LyricsState(
            trackId: 1,
            lyrics: LyricsResult(
              trackId: 1,
              isSynced: true,
              isInstrumental: false,
              lines: lines1,
              source: 'cache',
            ),
          ),
        );

        final container = ProviderContainer(
          overrides: [
            playbackControllerProvider.overrideWith(() => fakePlayback),
            lyricsControllerProvider.overrideWith(() => fakeLyrics),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: Consumer(
              builder: (context, ref, _) {
                final tokens = ref.watch(themeControllerProvider);
                final theme = tokens.toThemeData();
                return MaterialApp(
                  theme: theme,
                  darkTheme: theme,
                  themeMode: tokens.themeMode,
                  home: const Scaffold(
                    body: Column(
                      children: [
                        SoneaLogoMark(size: 40),
                        Expanded(child: SyncedLyricsView()),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );

        await tester.pumpAndSettle();

        final themeCtrl = container.read(themeControllerProvider.notifier);
        await themeCtrl.selectPack('wada_343');
        await tester.pump();
        await themeCtrl.selectPack('wada_331');
        await tester.pump();

        fakePlayback.switchTrack(track2, const Duration(seconds: 32));
        fakeLyrics.setLyricsState(
          LyricsState(
            trackId: 2,
            lyrics: LyricsResult(
              trackId: 2,
              isSynced: true,
              isInstrumental: false,
              lines: lines2,
              source: 'cache',
            ),
          ),
        );
        await themeCtrl.selectPack('wada_303');
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Song 2 Line 7'), findsOneWidget);
      },
    );
  });
}
