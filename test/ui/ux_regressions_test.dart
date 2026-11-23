import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/library/library_controller.dart';
import 'package:sonea/library/library_filter_controller.dart';
import 'package:sonea/playback/playback_backend.dart';
import 'package:sonea/playback/playback_controller.dart';
import 'package:sonea/playback/replay_gain_controller.dart';
import 'package:sonea/settings/app_settings_controller.dart';
import 'package:sonea/src/rust/api/library.dart' as rust;
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/theme/theme_controller.dart';
import 'package:sonea/ui/components/sonea_logo_mark.dart';
import 'package:sonea/ui/library/library_tab.dart';
import 'package:sonea/ui/navigation/main_navigation_shell.dart';
import 'package:sonea/ui/onboarding/onboarding_screen.dart';
import 'package:sonea/ui/playlists/playlists_tab.dart';
import 'package:sonea/ui/settings/settings_tab.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubLibraryController extends LibraryController {
  _StubLibraryController(this._initial);
  final LibraryState _initial;

  @override
  Future<LibraryState> build() async => _initial;

  @override
  Future<void> scan() async {}
}

class _StubPlaybackController extends PlaybackController {
  @override
  Future<PlaybackStateData> build() async => const PlaybackStateData();
}

rust.Track _track(int id, String title) => rust.Track(
      id: id,
      path: '/music/$title.flac',
      title: title,
      artist: 'Artist $id',
      album: 'Album $id',
      durationMs: 180000,
      format: 'FLAC',
      fileModified: 1000,
      addedAt: 1000,
      playCount: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'A-Z alphabet scroller does not overlap track list and toggles cleanly',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final tracks = [
        _track(1, 'Alpha Song'),
        _track(2, 'Beta Track'),
        _track(3, 'Zeta Finale'),
      ];

      final container = ProviderContainer(
        overrides: [
          libraryProvider.overrideWith(
            () => _StubLibraryController(
              LibraryState(
                permission: 'granted',
                tracks: tracks,
              ),
            ),
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
                home: const Scaffold(body: LibraryTab()),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final listFinder = find.byKey(const Key('library_tracks_listview'));
      final stripFinder = find.byKey(const Key('alphabet_scroller_strip'));
      expect(listFinder, findsOneWidget);
      expect(stripFinder, findsOneWidget);

      final listRect = tester.getRect(listFinder);
      final stripRect = tester.getRect(stripFinder);
      // Verify zero horizontal overlap between track list (duration / ... menu) and A-Z strip.
      expect(listRect.right, lessThanOrEqualTo(stripRect.left + 0.5));

      // Disable A-Z scroller and verify list expands to full width.
      await container
          .read(themeControllerProvider.notifier)
          .setShowAlphabetScroller(false);
      await tester.pumpAndSettle();

      expect(stripFinder, findsNothing);
      final expandedListRect = tester.getRect(listFinder);
      expect(expandedListRect.width, greaterThan(listRect.width));
    },
  );

  testWidgets(
    'PlaylistsTab dialog open/cancel and rapid theme switching triggers zero _dependents.isEmpty errors',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
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
                home: const PlaylistsTab(),
              );
            },
          ),
        ),
      );
      await tester.pump();

      // Open New Playlist dialog
      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsOneWidget);

      // Switch theme while dialog is open, then cancel dialog cleanly
      await container
          .read(themeControllerProvider.notifier)
          .selectPack(SoneaThemePalette.wada343.id);
      await tester.pump();

      await tester.tap(find.byType(TextButton).first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'SettingsTab stays compact with brightness mode bar and opens ThemeGalleryScreen with all 10 dual-mode Wada themes',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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
                home: const SettingsTab(),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // SettingsTab is compact: no inline 10-theme grid, shows brightness bar & active theme card.
      expect(find.byKey(const Key('wada_theme_gallery_grid')), findsNothing);
      expect(find.byKey(const Key('theme_mode_selector_bar')), findsOneWidget);
      expect(find.byKey(const Key('settings_open_theme_gallery_card')), findsOneWidget);

      // Independent Light toggle updates active wada_255 palette to Light mode.
      await tester.tap(find.byKey(const Key('theme_mode_btn_light')));
      await tester.pumpAndSettle();
      expect(container.read(themeControllerProvider).packId, 'wada_255');
      expect(container.read(themeControllerProvider).themeMode, ThemeMode.light);
      expect(container.read(themeControllerProvider).isLight, isTrue);

      // Navigate to dedicated ThemeGalleryScreen
      await tester.tap(find.byKey(const Key('settings_open_theme_gallery_card')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('wada_theme_gallery_grid')), findsOneWidget);
      expect(find.byKey(const Key('wada_theme_card_wada_255')), findsOneWidget);

      // Select Shiracha Editorial (wada_343) while staying in Light mode, then flip to Dark mode.
      final card343 = find.byKey(const Key('wada_theme_card_wada_343'));
      await tester.scrollUntilVisible(
        card343,
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.ensureVisible(card343);
      await tester.pumpAndSettle();
      await tester.tap(card343);
      await tester.pumpAndSettle();
      expect(container.read(themeControllerProvider).packId, 'wada_343');
      expect(container.read(themeControllerProvider).isLight, isTrue);

      final darkBtn = find.byKey(const Key('theme_mode_btn_dark'));
      await tester.tap(darkBtn);
      await tester.pumpAndSettle();
      expect(container.read(themeControllerProvider).packId, 'wada_343');
      expect(container.read(themeControllerProvider).themeMode, ThemeMode.dark);
      expect(container.read(themeControllerProvider).isLight, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'SettingsTab Reset to Recommended Defaults restores all smart defaults and Re-run Setup Wizard opens OnboardingScreen',
    (tester) async {
      SharedPreferences.setMockInitialValues({'settings_onboarding_completed': true});
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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
                home: const SettingsTab(),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Mutate preferences away from recommended defaults.
      await container.read(themeControllerProvider.notifier).selectPack('wada_343');
      await container.read(themeControllerProvider.notifier).setThemeMode(ThemeMode.light);
      await container
          .read(themeControllerProvider.notifier)
          .setProgressBarStyle(ProgressBarStyle.waveform);
      await container.read(libraryFilterProvider.notifier).setMinDurationSec(0);
      await container.read(replayGainControllerProvider.notifier).setMode(ReplayGainMode.off);
      await container.read(appSettingsProvider.notifier).setGaplessPlayback(false);
      await container.read(appSettingsProvider.notifier).setAutoFetchLyrics(false);
      await container.read(appSettingsProvider.notifier).setJapaneseTransliteration(false);
      await tester.pumpAndSettle();

      // Scroll to bottom and trigger Reset to Recommended Defaults.
      final resetTile = find.byKey(const Key('settings_reset_defaults_tile'));
      await tester.scrollUntilVisible(
        resetTile,
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(resetTile);
      await tester.pumpAndSettle();
      await tester.tap(resetTile);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('settings_reset_confirm_btn')));
      await tester.pumpAndSettle();

      final theme = container.read(themeControllerProvider);
      expect(theme.packId, 'wada_255');
      expect(theme.themeMode, ThemeMode.system);
      expect(theme.progressBarStyle, ProgressBarStyle.thinLine);
      expect(theme.useDynamicCoverGlow, isTrue);
      expect(theme.showAlphabetScroller, isTrue);
      expect(container.read(libraryFilterProvider).minTrackDurationSec, 30);
      expect(container.read(replayGainControllerProvider).mode, ReplayGainMode.track);
      expect(container.read(appSettingsProvider).gaplessPlayback, isTrue);
      expect(container.read(appSettingsProvider).autoFetchLyrics, isTrue);
      expect(container.read(appSettingsProvider).japaneseTransliteration, isTrue);

      // Tap Re-run Setup Wizard and confirm OnboardingScreen opens cleanly.
      final rerunTile = find.byKey(const Key('settings_rerun_wizard_tile'));
      await tester.ensureVisible(rerunTile);
      await tester.pumpAndSettle();
      await tester.tap(rerunTile);
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Library header logo is unboxed and bottom nav bar never truncates Turkish labels on 360dp',
    (tester) async {
      SharedPreferences.setMockInitialValues({'app_language_code': 'tr'});
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer(
        overrides: [
          libraryProvider.overrideWith(
            () => _StubLibraryController(
              LibraryState(
                permission: 'granted',
                tracks: [_track(1, 'Alpha Song')],
              ),
            ),
          ),
          playbackControllerProvider.overrideWith(_StubPlaybackController.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appLanguageProvider.notifier).setLanguage(AppLanguage.tr);
      await container.read(libraryProvider.future);
      await container.read(playbackControllerProvider.future);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: SoneaThemePalette.wada288.dark.toThemeData(),
            home: const MainNavigationShell(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // Ensure Library tab is active (startup tab switches in post-frame callback).
      await tester.tap(find.byKey(const Key('nav_tab_0')));
      await tester.pump(const Duration(milliseconds: 250));

      // 1. Header SoneaLogoMark is unboxed, tight-fitted, and properly sized.
      final logoFinder = find.byKey(const Key('library_header_logo'));
      expect(logoFinder, findsOneWidget);
      final logoWidget = tester.widget<SoneaLogoMark>(logoFinder);
      expect(logoWidget.tight, isTrue);
      expect(logoWidget.size, greaterThanOrEqualTo(34));

      // 2. Minimalist icon-only bottom nav dock switches cleanly with accessible tooltips
      // and zero text truncation across all 3 tabs on a narrow 360dp viewport.
      final dockFinder = find.byKey(const Key('floating_nav_dock'));
      expect(dockFinder, findsOneWidget);
      expect(
        find.descendant(of: dockFinder, matching: find.byType(Text)),
        findsNothing,
      );
      expect(find.byTooltip('Kütüphane'), findsOneWidget);
      expect(find.byTooltip('Çalma Listeleri'), findsOneWidget);
      expect(find.byTooltip('Ayarlar'), findsOneWidget);

      await tester.tap(find.byKey(const Key('nav_tab_1')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.descendant(
          of: find.byKey(const Key('nav_tab_1')),
          matching: find.byIcon(Icons.queue_music_rounded),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('nav_tab_2')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.descendant(
          of: find.byKey(const Key('nav_tab_2')),
          matching: find.byIcon(Icons.settings_rounded),
        ),
        findsOneWidget,
      );

      expect(tester.takeException(), isNull);
    },
  );
}
