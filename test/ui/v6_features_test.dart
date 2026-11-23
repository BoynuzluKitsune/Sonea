import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/library/library_controller.dart';
import 'package:sonea/library/library_filter_controller.dart';
import 'package:sonea/library/playlist_cover_service.dart';
import 'package:sonea/playback/lyrics_controller.dart';
import 'package:sonea/playback/playback_backend.dart';
import 'package:sonea/playback/playback_controller.dart';
import 'package:sonea/playback/replay_gain_controller.dart';
import 'package:sonea/playback/widget_payload.dart';
import 'package:sonea/settings/app_settings_controller.dart';
import 'package:sonea/src/rust/api/library.dart' as rust;
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/theme/theme_controller.dart';
import 'package:sonea/ui/components/artwork_thumbnail.dart';
import 'package:sonea/ui/components/playlist_artwork_collage.dart';
import 'package:sonea/ui/library/library_tab.dart';
import 'package:sonea/ui/onboarding/onboarding_screen.dart';
import 'package:sonea/ui/settings/settings_tab.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubLibraryController extends LibraryController {
  _StubLibraryController(this._initial);
  final LibraryState _initial;

  @override
  Future<LibraryState> build() async => _initial;

  @override
  Future<void> scan() async {}

  @override
  Future<void> requestPermission() async {}
}

class _StubPlaybackController extends PlaybackController {
  @override
  Future<PlaybackStateData> build() async => const PlaybackStateData();
}

class _FakeLyricsController extends LyricsController {
  _FakeLyricsController(this._initial);
  final LyricsState _initial;
  bool started = false;
  bool cancelled = false;
  bool autoCacheCleared = false;

  @override
  LyricsState build() => _initial;

  @override
  Future<int> clearAutoCache() async {
    autoCacheCleared = true;
    return 7;
  }

  @override
  Future<void> startBulkDownload() async {
    started = true;
    state = state.copyWith(
      isBulkDownloading: true,
      bulkProcessed: 24,
      bulkTotal: 180,
      bulkSynced: 15,
      bulkPlain: 4,
      bulkNotFound: 5,
    );
  }

  @override
  Future<void> cancelBulkDownload() async {
    cancelled = true;
    state = state.copyWith(isBulkDownloading: false);
  }
}

rust.Track _makeTrack(
  int id,
  String title, {
  String artist = 'Artist A',
  String album = 'Album A',
  String? coverPath,
}) =>
    rust.Track(
      id: id,
      path: '/music/$title.flac',
      title: title,
      artist: artist,
      album: album,
      durationMs: 200000,
      format: 'FLAC',
      coverPath: coverPath,
      fileModified: 1000,
      addedAt: 1000,
      playCount: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Dynamic Corner Style Tokens', () {
    test('Sharp / Soft / Rounded produce proportional distinct radii', () {
      final base = SoneaThemePalette.wada255.tokens;

      final sharp = base.copyWith(cornerRadius: 4.0);
      expect(sharp.cornerStyle, SoneaCornerStyle.sharp);
      expect(sharp.radiusSm, 2.0);
      expect(sharp.radiusMd, 4.0);
      expect(sharp.radiusLg, 4.0);

      final soft = base.copyWith(cornerRadius: 12.0);
      expect(soft.cornerStyle, SoneaCornerStyle.soft);
      expect(soft.radiusSm, 8.0);
      expect(soft.radiusMd, 12.0);
      expect(soft.radiusLg, 16.0);

      final rounded = base.copyWith(cornerRadius: 20.0);
      expect(rounded.cornerStyle, SoneaCornerStyle.rounded);
      expect(rounded.radiusSm, 14.0);
      expect(rounded.radiusMd, 20.0);
      expect(rounded.radiusLg, 26.0);
    });
  });

  group('Playlist Custom Cover Override & Reset', () {
    test('PlaylistCoversController persists custom cover and resets cleanly', () async {
      SharedPreferences.setMockInitialValues({});
      final tmpDir = Directory.systemTemp.createTempSync('sonea_pl_cover_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final fakeImg = File('${tmpDir.path}/custom.jpg')
        ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF, 0xD9]);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final ctrl = container.read(playlistCoversProvider.notifier);
      await ctrl.setCustomCoverPath(7, fakeImg.path);
      expect(container.read(playlistCoversProvider).coverPathFor(7), fakeImg.path);
      expect(container.read(playlistCoversProvider).revisionFor(7), 1);

      await ctrl.clearCustomCover(7);
      expect(container.read(playlistCoversProvider).coverPathFor(7), isNull);
      expect(container.read(playlistCoversProvider).revisionFor(7), 2);
      expect(fakeImg.existsSync(), isFalse);
    });

    testWidgets(
      'PlaylistArtworkCollage prioritizes customCoverPath over 2x2 collage',
      (tester) async {
        final tmpDir = Directory.systemTemp.createTempSync('sonea_pl_widget_');
        addTearDown(() => tmpDir.deleteSync(recursive: true));

        final fakeImg = File('${tmpDir.path}/custom.jpg')
          ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF, 0xD9]);

        final tokens = SoneaThemePalette.wada255.tokens;
        await tester.pumpWidget(
          MaterialApp(
            theme: tokens.toThemeData(),
            home: Scaffold(
              body: PlaylistArtworkCollage(
                coverPaths: const ['/a.jpg', '/b.jpg', '/c.jpg', '/d.jpg'],
                customCoverPath: fakeImg.path,
                size: 80,
                tokens: tokens,
              ),
            ),
          ),
        );
        // Custom cover renders a single full-bleed Image widget instead of 4 tiles.
        expect(find.byType(Image), findsOneWidget);
      },
    );
  });

  group('Onboarding 4-Step Setup Wizard & Smart Defaults', () {
    testWidgets(
      'verifies smart fresh defaults and walks all 4 steps overflow-free on 360dp',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        bool completedCallbackFired = false;

        final container = ProviderContainer(
          overrides: [
            libraryProvider.overrideWith(
              () => _StubLibraryController(const LibraryState(permission: 'granted')),
            ),
            playbackControllerProvider.overrideWith(_StubPlaybackController.new),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: Consumer(
              builder: (_, ref, _) {
                final tokens = ref.watch(themeControllerProvider);
                return MaterialApp(
                  themeAnimationDuration: Duration.zero,
                  theme: tokens.toThemeDataFor(Brightness.light),
                  darkTheme: tokens.toThemeDataFor(Brightness.dark),
                  themeMode: tokens.themeMode,
                  home: OnboardingScreen(
                    onCompleted: () => completedCallbackFired = true,
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Verify fresh out-of-the-box defaults
        final initialTheme = container.read(themeControllerProvider);
        expect(initialTheme.packId, 'wada_255');
        expect(initialTheme.themeMode, ThemeMode.system);
        expect(initialTheme.progressBarStyle, ProgressBarStyle.thinLine);
        expect(initialTheme.useDynamicCoverGlow, isTrue);
        expect(initialTheme.showAlphabetScroller, isTrue);

        final initialFilter = container.read(libraryFilterProvider);
        expect(initialFilter.minTrackDurationSec, 30);

        final initialRg = container.read(replayGainControllerProvider);
        expect(initialRg.mode, ReplayGainMode.track);
        expect(initialRg.preventClipping, isTrue);
        expect(initialRg.preAmpGainDb, 0.0);

        final initialSettings = container.read(appSettingsProvider);
        expect(initialSettings.gaplessPlayback, isTrue);
        expect(initialSettings.autoFetchLyrics, isTrue);
        expect(initialSettings.japaneseTransliteration, isTrue);

        // Step 1: Welcome, Language & Appearance (Skip visible)
        expect(find.byKey(const Key('onboarding_step_0')), findsOneWidget);
        expect(find.byKey(const Key('onboarding_skip_btn')), findsOneWidget);
        expect(find.byKey(const Key('onboarding_preview_card')), findsOneWidget);
        expect(find.byKey(const Key('theme_mode_selector_bar')), findsOneWidget);

        // Toggle language live to Turkish and back to English
        await tester.tap(find.byKey(const Key('onboarding_lang_tr')));
        await tester.pumpAndSettle();
        expect(container.read(appLanguageProvider), AppLanguage.tr);
        await tester.tap(find.byKey(const Key('onboarding_lang_en')));
        await tester.pumpAndSettle();
        expect(container.read(appLanguageProvider), AppLanguage.en);

        // Step 1 -> Step 2 (Permission & Smart Library Filter; Skip hidden on permission step)
        await tester.tap(find.byKey(const Key('onboarding_next_btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('onboarding_step_1')), findsOneWidget);
        expect(find.byKey(const Key('onboarding_skip_btn')), findsNothing);
        expect(find.byKey(const Key('onboarding_permission_card')), findsOneWidget);
        expect(find.byKey(const Key('onboarding_filter_30')), findsOneWidget);

        // Step 2 -> Step 3 (Audio, Visuals & Synced Lyrics; Skip visible again)
        await tester.tap(find.byKey(const Key('onboarding_next_btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('onboarding_step_2')), findsOneWidget);
        expect(find.byKey(const Key('onboarding_skip_btn')), findsOneWidget);
        expect(find.byKey(const Key('onboarding_seekbar_line')), findsOneWidget);
        expect(find.byKey(const Key('onboarding_gapless_switch')), findsOneWidget);
        expect(find.byKey(const Key('onboarding_rg_track')), findsOneWidget);
        expect(find.byKey(const Key('onboarding_autofetch_lyrics_switch')), findsOneWidget);
        expect(find.byKey(const Key('onboarding_romaji_switch')), findsOneWidget);

        // Step 3 -> Step 4 (Ready to Listen Summary)
        await tester.tap(find.byKey(const Key('onboarding_next_btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('onboarding_step_3')), findsOneWidget);
        expect(find.byKey(const Key('onboarding_summary_card')), findsOneWidget);

        // Finish onboarding
        await tester.tap(find.byKey(const Key('onboarding_finish_btn')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(completedCallbackFired, isTrue);
        expect(container.read(appSettingsProvider).hasCompletedOnboarding, isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('settings_onboarding_completed'), isTrue);
      },
    );
  });

  group('Bulk Lyrics Download UI', () {
    testWidgets('triggers start and cancel bulk download with live progress', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fakeLyrics = _FakeLyricsController(const LyricsState());

      final container = ProviderContainer(
        overrides: [
          lyricsControllerProvider.overrideWith(() => fakeLyrics),
          libraryProvider.overrideWith(
            () => _StubLibraryController(const LibraryState(permission: 'granted')),
          ),
          playbackControllerProvider.overrideWith(_StubPlaybackController.new),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            themeAnimationDuration: Duration.zero,
            theme: SoneaThemePalette.wada255.tokens.toThemeData(),
            home: const SettingsTab(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // Scroll down to Bulk Lyrics Download button
      final startFinder = find.byKey(const Key('bulk_lyrics_start_btn'));
      await tester.scrollUntilVisible(
        startFinder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(startFinder);
      await tester.pump();
      await tester.tap(startFinder);
      await tester.pump();

      expect(fakeLyrics.started, isTrue);
      expect(find.byKey(const Key('bulk_lyrics_cancel_btn')), findsOneWidget);
      expect(find.textContaining('24 / 180'), findsOneWidget);

      await tester.tap(find.byKey(const Key('bulk_lyrics_cancel_btn')));
      await tester.pump();
      expect(fakeLyrics.cancelled, isTrue);

      // Verify Clear Auto-Fetched Lyrics Cache button & confirmation dialog.
      final clearBtn = find.byKey(const Key('clear_auto_lyrics_cache_btn'));
      await tester.ensureVisible(clearBtn);
      await tester.pumpAndSettle();
      await tester.tap(clearBtn);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('clear_auto_lyrics_confirm_btn')));
      await tester.pumpAndSettle();

      expect(fakeLyrics.autoCacheCleared, isTrue);
      expect(find.textContaining('7'), findsAtLeastNWidgets(1));
    });
  });

  group('Widget Background Sync Payload & Cover Reset', () {
    test('detects track advance, clears missing cover, includes playlist custom cover, ignores position ticks', () {
      final t1 = _makeTrack(1, 'Track One', coverPath: '/covers/t1.jpg');
      final t2NoCover = _makeTrack(2, 'Track Two', coverPath: null);

      final s1 = PlaybackStateData(
        currentTrack: t1,
        queue: [t1, t2NoCover],
        currentIndex: 0,
        isPlaying: true,
        position: const Duration(seconds: 5),
      );
      final s1Later = s1.copyWith(position: const Duration(seconds: 42));

      // Position ticks must produce identical fingerprint (no spam).
      expect(
        WidgetSyncPayload.computePlaybackFingerprint(s1),
        WidgetSyncPayload.computePlaybackFingerprint(s1Later),
      );

      // Track advance to coverless track resets coverPath to null cleanly.
      final s2 = s1.copyWith(currentTrack: t2NoCover, currentIndex: 1);
      expect(
        WidgetSyncPayload.computePlaybackFingerprint(s2),
        isNot(WidgetSyncPayload.computePlaybackFingerprint(s1)),
      );
      final map2 = WidgetSyncPayload.buildPlaybackOnlyMap(s2);
      expect(map2['title'], 'Track Two');
      expect(map2['coverPath'], isNull);

      // Full payload includes custom playlist cover path & theme colors.
      final full = WidgetSyncPayload.fromState(
        playback: s2,
        theme: SoneaThemePalette.wada343.light,
        playlists: const [
          WidgetPlaylistShortcut(
            id: 3,
            name: 'Chill Mix',
            trackCount: 12,
            coverPath: '/playlist_covers/playlist_3.jpg',
          ),
        ],
      );
      final fullMap = full.toMethodChannelMap();
      expect(fullMap['isLight'], isTrue);
      expect(fullMap['accentColor'], SoneaThemePalette.wada343.light.accentColor.toARGB32());
      final pls = fullMap['playlists'] as List;
      expect((pls.first as Map)['coverPath'], '/playlist_covers/playlist_3.jpg');
    });
  });

  group('Albums Grid & Artists Visual List', () {
    testWidgets('renders visual Album Grid and Artist cards without errors', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final tracks = [
        _makeTrack(1, 'Song 1', artist: 'Miles', album: 'Kind of Blue'),
        _makeTrack(2, 'Song 2', artist: 'Bill', album: 'Waltz for Debby'),
      ];

      final container = ProviderContainer(
        overrides: [
          libraryProvider.overrideWith(
            () => _StubLibraryController(
              LibraryState(permission: 'granted', tracks: tracks),
            ),
          ),
          playbackControllerProvider.overrideWith(_StubPlaybackController.new),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            themeAnimationDuration: Duration.zero,
            theme: SoneaThemePalette.wada255.tokens.toThemeData(),
            home: const Scaffold(body: LibraryTab()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Switch to Albums tab (index 1)
      await tester.tap(find.byType(Tab).at(1));
      await tester.pumpAndSettle();
      expect(find.byType(GridView), findsOneWidget);
      expect(find.byType(ArtworkThumbnail), findsNWidgets(2));
      expect(find.text('Kind of Blue'), findsOneWidget);

      // Switch to Artists tab (index 2)
      await tester.tap(find.byType(Tab).at(2));
      await tester.pumpAndSettle();
      expect(find.text('Miles'), findsOneWidget);
      expect(find.text('Bill'), findsOneWidget);
    });
  });
}
