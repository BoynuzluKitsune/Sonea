import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/ui/components/playlist_artwork_collage.dart';
import 'package:sonea/ui/playlists/playlists_tab.dart'
    show formatPlaylistTotalDuration;

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: SoneaThemePalette.wada255.tokens.toThemeData(),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('extractUniqueCovers', () {
    test('deduplicates, strips blanks, and caps at maxCount', () {
      final result = extractUniqueCovers([
        null,
        '',
        '   ',
        '/covers/a.jpg',
        '/covers/a.jpg',
        '/covers/b.jpg',
        '/covers/c.jpg',
        '/covers/d.jpg',
        '/covers/e.jpg',
      ]);

      expect(result, [
        '/covers/a.jpg',
        '/covers/b.jpg',
        '/covers/c.jpg',
        '/covers/d.jpg',
      ]);
    });
  });

  group('PlaylistArtworkCollage widget fallbacks', () {
    final tokens = SoneaThemePalette.wada255.tokens;

    testWidgets('0 covers renders fallback icon and 0 Image widgets', (tester) async {
      await tester.pumpWidget(
        _wrap(PlaylistArtworkCollage(
          coverPaths: const [],
          size: 64,
          tokens: tokens,
        )),
      );

      expect(find.byIcon(Icons.queue_music_rounded), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('1 cover renders single full-bleed Image', (tester) async {
      await tester.pumpWidget(
        _wrap(PlaylistArtworkCollage(
          coverPaths: const ['/tmp/cover1.jpg', '/tmp/cover1.jpg'],
          size: 64,
          tokens: tokens,
        )),
      );

      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('2 covers renders 2 balanced Image tiles', (tester) async {
      await tester.pumpWidget(
        _wrap(PlaylistArtworkCollage(
          coverPaths: const ['/tmp/c1.jpg', '/tmp/c2.jpg'],
          size: 64,
          tokens: tokens,
        )),
      );

      expect(find.byType(Image), findsNWidgets(2));
    });

    testWidgets('3 covers renders 3 balanced Image tiles', (tester) async {
      await tester.pumpWidget(
        _wrap(PlaylistArtworkCollage(
          coverPaths: const ['/tmp/c1.jpg', '/tmp/c2.jpg', '/tmp/c3.jpg'],
          size: 64,
          tokens: tokens,
        )),
      );

      expect(find.byType(Image), findsNWidgets(3));
    });

    testWidgets('4+ covers renders 2x2 grid capped at 4 Image tiles', (tester) async {
      await tester.pumpWidget(
        _wrap(PlaylistArtworkCollage(
          coverPaths: const [
            '/tmp/c1.jpg',
            '/tmp/c2.jpg',
            '/tmp/c3.jpg',
            '/tmp/c4.jpg',
            '/tmp/c5.jpg',
          ],
          size: 64,
          tokens: tokens,
        )),
      );

      expect(find.byType(Image), findsNWidgets(4));
    });
  });

  group('formatPlaylistTotalDuration', () {
    test('formats seconds, minutes, and hours cleanly in TR and EN', () {
      expect(formatPlaylistTotalDuration(0, isTurkish: true), '');
      expect(formatPlaylistTotalDuration(45000, isTurkish: true), '45 sn');
      expect(formatPlaylistTotalDuration(45000, isTurkish: false), '45s');
      expect(formatPlaylistTotalDuration(15 * 60000, isTurkish: true), '15 dk');
      expect(formatPlaylistTotalDuration(15 * 60000, isTurkish: false), '15 min');
      expect(formatPlaylistTotalDuration(95 * 60000, isTurkish: true), '1sa 35dk');
      expect(formatPlaylistTotalDuration(95 * 60000, isTurkish: false), '1h 35m');
    });
  });
}
