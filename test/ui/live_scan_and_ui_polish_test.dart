import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonea/library/library_controller.dart';
import 'package:sonea/playback/playback_backend.dart';
import 'package:sonea/playback/playback_controller.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/theme/theme_controller.dart';
import 'package:sonea/ui/library/library_tab.dart';
import 'package:sonea/ui/onboarding/onboarding_screen.dart';
import 'package:sonea/ui/playlists/playlists_tab.dart';

class _StubLibraryController extends LibraryController {
  _StubLibraryController(this._state);
  final LibraryState _state;

  @override
  Future<LibraryState> build() async => _state;

  @override
  Future<void> scan() async {}

  @override
  Future<void> requestPermission() async {}
}

class _StubPlaybackController extends PlaybackController {
  @override
  Future<PlaybackStateData> build() async => const PlaybackStateData();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Live Scan Counter UI (LibraryTab & OnboardingScreen)', () {
    testWidgets(
      'LibraryTab shows live scanning counter instead of 0 şarkı while scanning',
      (tester) async {
        SharedPreferences.setMockInitialValues({'app_language_code': 'tr'});
        final container = ProviderContainer(
          overrides: [
            libraryProvider.overrideWith(
              () => _StubLibraryController(
                const LibraryState(
                  permission: 'granted',
                  scanning: true,
                  processed: 148,
                  total: 420,
                  found: 145,
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
            child: MaterialApp(
              themeAnimationDuration: Duration.zero,
              theme: SoneaThemePalette.wada255.tokens.toThemeData(),
              home: const Scaffold(body: LibraryTab()),
            ),
          ),
        );
        await tester.pump();

        expect(find.byKey(const Key('library_live_scan_banner')), findsOneWidget);
        expect(find.text('Taranıyor: 148 / 420 şarkı'), findsAtLeastNWidgets(2));
        expect(find.text('0 şarkı'), findsNothing);
        expect(find.text('35%'), findsOneWidget);
      },
    );

    testWidgets(
      'OnboardingScreen shows interactive preview in Step 1 and live scan progress in Step 2',
      (tester) async {
        SharedPreferences.setMockInitialValues({'app_language_code': 'tr'});
        final container = ProviderContainer(
          overrides: [
            libraryProvider.overrideWith(
              () => _StubLibraryController(
                const LibraryState(
                  permission: 'granted',
                  scanning: true,
                  processed: 148,
                  total: 420,
                  found: 148,
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
                  home: const OnboardingScreen(),
                );
              },
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        // Step 1 shows live interactive preview immediately
        expect(find.byKey(const Key('onboarding_preview_card')), findsOneWidget);

        // Step 1 -> Step 2 shows live scan progress
        await tester.tap(find.byKey(const Key('onboarding_next_btn')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(const Key('onboarding_live_scan_card')),
          findsOneWidget,
        );
        expect(find.text('Taranıyor: 148 / 420 şarkı'), findsOneWidget);
        expect(find.text('35%'), findsOneWidget);
      },
    );
  });

  group('PlaylistsTab Modern UI', () {
    testWidgets('renders smart cards and opens validated New Playlist dialog', (
      tester,
    ) async {
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
          child: MaterialApp(
            themeAnimationDuration: Duration.zero,
            theme: SoneaThemePalette.wada255.tokens.toThemeData(),
            home: const PlaylistsTab(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));

      expect(find.byKey(const Key('playlists_new_btn')), findsOneWidget);
      await tester.tap(find.byKey(const Key('playlists_new_btn')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });
  });
}
