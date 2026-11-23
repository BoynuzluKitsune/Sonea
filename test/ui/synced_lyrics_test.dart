import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/playback/lyrics_controller.dart';
import 'package:sonea/playback/playback_backend.dart';
import 'package:sonea/playback/playback_controller.dart';
import 'package:sonea/src/rust/api/library.dart';
import 'package:sonea/src/rust/api/lyrics.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/ui/now_playing/synced_lyrics_view.dart';

class _FakePlaybackController extends PlaybackController {
  _FakePlaybackController(this._initial);
  final PlaybackStateData _initial;

  @override
  Future<PlaybackStateData> build() async => _initial;

  void emitPosition(Duration pos) {
    final current = state.value ?? _initial;
    state = AsyncData(current.copyWith(position: pos));
  }
}

class _FakeLyricsController extends LyricsController {
  _FakeLyricsController(
    this._initial, {
    this.mockCandidates = const [],
  });
  final LyricsState _initial;
  final List<LyricsCandidateDto> mockCandidates;
  String? appliedSource;
  String? appliedSynced;
  String? appliedPlain;

  @override
  LyricsState build() => _initial;

  @override
  Future<List<LyricsCandidateDto>> searchCandidates({
    required String query,
    String? artist,
    int? durationSecs,
  }) async {
    return mockCandidates;
  }

  @override
  Future<void> applyCustomLyrics({
    required int trackId,
    String? syncedLrc,
    String? plainLyrics,
    required String source,
  }) async {
    appliedSource = source;
    appliedSynced = syncedLrc;
    appliedPlain = plainLyrics;
    state = state.copyWith(
      lyrics: LyricsResult(
        trackId: trackId,
        isSynced: syncedLrc != null,
        isInstrumental: false,
        lines: syncedLrc != null
            ? [const LyricLine(timeMs: 1000, text: 'Picked synced line')]
            : const [],
        plainText: plainLyrics,
        source: source,
      ),
    );
  }
}

List<LyricLine> _sampleLines(int count) {
  return List.generate(
    count,
    (i) => LyricLine(
      timeMs: (i + 1) * 5000,
      text: 'Lyric line #$i',
    ),
  );
}

void main() {
  group('findActiveLyricIndex', () {
    test('returns -1 for empty lines', () {
      expect(findActiveLyricIndex(const [], 0), -1);
    });

    test('highlights opening line (0) immediately at 0ms before first timestamp', () {
      final lines = _sampleLines(10); // starts at 5000ms
      expect(findActiveLyricIndex(lines, 0), 0);
      expect(findActiveLyricIndex(lines, 2000), 0);
    });

    test('applies lookahead and tracks mid-song and end-of-song lines', () {
      final lines = _sampleLines(10); // 5000, 10000, 15000, ...
      expect(findActiveLyricIndex(lines, 9900), 1); // 9900 + 120 >= 10000
      expect(findActiveLyricIndex(lines, 25000), 4);
      expect(findActiveLyricIndex(lines, 999999), 9);
    });

    test('stripEnhancedLrcTags removes inline word timestamps cleanly', () {
      expect(
        stripEnhancedLrcTags(
          '<00:12.00>We <00:12.40>are <00:12.80>fighting <00:13.20>dreamers',
        ),
        'We are fighting dreamers',
      );
      expect(
        stripEnhancedLrcTags('Plain line without tags'),
        'Plain line without tags',
      );
    });
  });

  group('SyncedLyricsView initial auto-highlight, auto-scroll & manual picker', () {
    testWidgets(
      'highlights and auto-scrolls to active mid-song line on initial open without tap',
      (tester) async {
        final lines = _sampleLines(40); // line 25 is at 130_000ms
        final track = Track(
          id: 7,
          path: '/music/test.flac',
          title: 'Test Song',
          artist: 'Tester',
          fileModified: 1,
          addedAt: 1,
          playCount: 0,
        );

        final fakePlayback = _FakePlaybackController(
          PlaybackStateData(
            currentTrack: track,
            queue: [track],
            isPlaying: true,
            position: const Duration(milliseconds: 130000),
            duration: const Duration(milliseconds: 220000),
          ),
        );
        final fakeLyrics = _FakeLyricsController(
          LyricsState(
            trackId: 7,
            lyrics: LyricsResult(
              trackId: 7,
              isSynced: true,
              isInstrumental: false,
              lines: lines,
              source: 'cache',
            ),
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackControllerProvider.overrideWith(() => fakePlayback),
              lyricsControllerProvider.overrideWith(() => fakeLyrics),
            ],
            child: MaterialApp(
              theme: SoneaThemePalette.wada255.tokens.toThemeData(),
              home: const Scaffold(
                body: SizedBox(
                  height: 320,
                  width: 360,
                  child: SyncedLyricsView(),
                ),
              ),
            ),
          ),
        );

        // Allow async build + post-frame auto-scroll animation to complete.
        await tester.pumpAndSettle();

        // Search & Retry buttons must be accessible in the synced lyrics header.
        expect(find.byKey(const Key('lyrics_search_header_btn')), findsOneWidget);
        expect(find.byKey(const Key('lyrics_retry_header_btn')), findsOneWidget);

        // Active line #25 must be highlighted in accent color without any user tap.
        final activeText = tester.widget<Text>(find.text('Lyric line #25'));
        expect(activeText.style?.color, SoneaThemePalette.wada255.tokens.accentColor);
        expect(activeText.style?.fontWeight, FontWeight.w700);

        // The scroll view must have automatically scrolled down from 0.0.
        final scrollView = tester.widget<SingleChildScrollView>(
          find.byType(SingleChildScrollView),
        );
        expect(scrollView.controller!.offset, greaterThan(100.0));
      },
    );

    testWidgets(
      'opens manual lyrics search sheet from empty state and applies NetEase synced candidate',
      (tester) async {
        final track = Track(
          id: 42,
          path: '/music/idol.flac',
          title: 'アイドル',
          artist: 'YOASOBI',
          durationMs: 213000,
          fileModified: 1,
          addedAt: 1,
          playCount: 0,
        );

        final fakePlayback = _FakePlaybackController(
          PlaybackStateData(
            currentTrack: track,
            queue: [track],
            isPlaying: true,
            position: const Duration(seconds: 2),
            duration: const Duration(seconds: 213),
          ),
        );
        final fakeLyrics = _FakeLyricsController(
          const LyricsState(trackId: 42, lyrics: null),
          mockCandidates: const [
            LyricsCandidateDto(
              source: 'kugou',
              title: 'アイドル',
              artist: 'YOASOBI',
              durationSecs: 213,
              isSynced: true,
              preview: '無敵の笑顔で荒らすメディア / 知りたいその秘密ミステリアス',
              syncedLrc: '[00:01.00]Picked synced line',
              plainLyrics: null,
            ),
            LyricsCandidateDto(
              source: 'musixmatch',
              title: 'Idol',
              artist: 'YOASOBI',
              durationSecs: 214,
              isSynced: false,
              preview: 'Muteki no egao de arasu media',
              syncedLrc: null,
              plainLyrics: 'Muteki no egao de arasu media',
            ),
          ],
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackControllerProvider.overrideWith(() => fakePlayback),
              lyricsControllerProvider.overrideWith(() => fakeLyrics),
            ],
            child: MaterialApp(
              theme: SoneaThemePalette.wada255.dark.toThemeData(),
              home: const Scaffold(
                body: SizedBox(
                  height: 600,
                  width: 360,
                  child: SyncedLyricsView(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('lyrics_retry_empty_btn')), findsOneWidget);
        expect(find.byKey(const Key('lyrics_search_empty_btn')), findsOneWidget);
        expect(find.byKey(const Key('lyrics_paste_empty_btn')), findsOneWidget);
        await tester.tap(find.byKey(const Key('lyrics_search_empty_btn')));
        await tester.pumpAndSettle();

        // Both candidates with KuGou/Musixmatch source badges and duration must render cleanly.
        expect(find.text('KuGou'), findsOneWidget);
        expect(find.text('Musixmatch'), findsOneWidget);
        expect(find.text('3:33'), findsOneWidget);

        // Select KuGou candidate and verify it persists and updates view.
        await tester.tap(find.byKey(const Key('lyrics_candidate_0')));
        await tester.pumpAndSettle();

        expect(fakeLyrics.appliedSource, 'kugou');
        expect(fakeLyrics.appliedSynced, '[00:01.00]Picked synced line');
        expect(find.text('Picked synced line'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'supports manual LRC paste and save via Paste / Edit Lyrics tab',
      (tester) async {
        final track = Track(
          id: 99,
          path: '/music/custom.flac',
          title: 'Custom Song',
          artist: 'Custom Artist',
          fileModified: 1,
          addedAt: 1,
          playCount: 0,
        );

        final fakePlayback = _FakePlaybackController(
          PlaybackStateData(
            currentTrack: track,
            queue: [track],
            isPlaying: true,
            position: const Duration(seconds: 2),
            duration: const Duration(minutes: 3),
          ),
        );
        final fakeLyrics = _FakeLyricsController(
          const LyricsState(trackId: 99, lyrics: null),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackControllerProvider.overrideWith(() => fakePlayback),
              lyricsControllerProvider.overrideWith(() => fakeLyrics),
            ],
            child: MaterialApp(
              theme: SoneaThemePalette.wada255.dark.toThemeData(),
              home: const Scaffold(
                body: SizedBox(
                  height: 600,
                  width: 360,
                  child: SyncedLyricsView(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('lyrics_paste_empty_btn')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('lyrics_paste_input_field')),
          '[00:01.00]Manual pasted line',
        );
        await tester.tap(find.byKey(const Key('lyrics_paste_save_btn')));
        await tester.pumpAndSettle();

        expect(fakeLyrics.appliedSource, 'manual');
        expect(fakeLyrics.appliedSynced, '[00:01.00]Manual pasted line');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'renders dedicated Instrumental Track UI with Search Anyway and Paste actions',
      (tester) async {
        final track = Track(
          id: 108,
          path: '/music/beethoven_sonata.flac',
          title: 'Piano Sonata No. 14 (Moonlight)',
          artist: 'Ludwig van Beethoven',
          durationMs: 340000,
          fileModified: 1,
          addedAt: 1,
          playCount: 0,
        );

        final fakePlayback = _FakePlaybackController(
          PlaybackStateData(
            currentTrack: track,
            queue: [track],
            isPlaying: true,
            position: const Duration(seconds: 12),
            duration: const Duration(seconds: 340),
          ),
        );
        final fakeLyrics = _FakeLyricsController(
          const LyricsState(
            trackId: 108,
            lyrics: LyricsResult(
              trackId: 108,
              isSynced: false,
              isInstrumental: true,
              lines: [],
              source: 'heuristic',
            ),
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackControllerProvider.overrideWith(() => fakePlayback),
              lyricsControllerProvider.overrideWith(() => fakeLyrics),
            ],
            child: MaterialApp(
              theme: SoneaThemePalette.wada255.dark.toThemeData(),
              home: const Scaffold(
                body: SizedBox(
                  height: 600,
                  width: 360,
                  child: SyncedLyricsView(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('lyrics_instrumental_view')), findsOneWidget);
        expect(find.byIcon(Icons.piano_rounded), findsOneWidget);
        expect(
          find.byKey(const Key('lyrics_instrumental_search_btn')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('lyrics_instrumental_paste_btn')),
          findsOneWidget,
        );
        // Should NOT render the generic empty-state retry button
        expect(find.byKey(const Key('lyrics_retry_empty_btn')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
