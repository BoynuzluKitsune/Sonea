import 'package:flutter_test/flutter_test.dart';
import 'package:sonea/playback/playback_backend.dart';
import 'package:sonea/playback/widget_payload.dart';
import 'package:sonea/src/rust/api/library.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';

Track _track(int id, {String? format, int? sampleRate}) {
  return Track(
    id: id,
    path: '/music/t$id.flac',
    title: 'Song $id',
    artist: 'Artist $id',
    album: 'Album $id',
    format: format,
    sampleRate: sampleRate,
    fileModified: 1,
    addedAt: 1,
    playCount: 0,
  );
}

void main() {
  group('WidgetSyncPayload serialization & fingerprint', () {
    test('builds real format badge, upNext 3 items, playlists 3 items, and theme colors', () {
      final queue = [
        _track(1, format: 'flac', sampleRate: 96000),
        _track(2),
        _track(3),
        _track(4),
        _track(5),
      ];
      final playback = PlaybackStateData(
        currentTrack: queue[0],
        queue: queue,
        currentIndex: 0,
        isPlaying: true,
        isShuffleEnabled: true,
      );
      final playlists = const [
        WidgetPlaylistShortcut(id: 10, name: 'Focus', trackCount: 12),
        WidgetPlaylistShortcut(id: 11, name: 'Night Drive', trackCount: 24),
        WidgetPlaylistShortcut(id: 12, name: 'Vinyl', trackCount: 8),
        WidgetPlaylistShortcut(id: 13, name: 'Extra', trackCount: 3),
      ];

      final payload = WidgetSyncPayload.fromState(
        playback: playback,
        theme: SoneaThemePalette.wada255.tokens,
        playlists: playlists,
      );

      expect(payload.title, 'Song 1');
      expect(payload.format, 'FLAC • 96.0kHz');
      expect(payload.upNext.length, 3);
      expect(payload.upNext.map((e) => e.queueIndex).toList(), [1, 2, 3]);
      expect(payload.playlists.length, 3);

      final map = payload.toMethodChannelMap();
      expect(map['accentColor'], SoneaThemePalette.wada255.tokens.accentColor.toARGB32());
      expect(map['onAccentColor'], SoneaThemePalette.wada255.tokens.onAccentColor.toARGB32());
      expect(map['isShuffleEnabled'], isTrue);
      expect((map['upNext'] as List).length, 3);
      expect((map['playlists'] as List).length, 3);
    });

    test('never emits fake format text when track format is missing', () {
      final playback = PlaybackStateData(
        currentTrack: _track(1, format: null, sampleRate: null),
        queue: [_track(1)],
      );
      final payload = WidgetSyncPayload.fromState(
        playback: playback,
        theme: SoneaThemePalette.wada343.tokens,
      );
      expect(payload.format, isEmpty);
    });

    test('fingerprint ignores position ticks and reacts to theme/state changes', () {
      final track = _track(1, format: 'mp3', sampleRate: 44100);
      final s1 = PlaybackStateData(
        currentTrack: track,
        queue: [track],
        position: const Duration(seconds: 5),
        isPlaying: true,
      );
      final s2 = s1.copyWith(position: const Duration(seconds: 42));

      final p1 = WidgetSyncPayload.fromState(
        playback: s1,
        theme: SoneaThemePalette.wada255.dark,
      );
      final p2 = WidgetSyncPayload.fromState(
        playback: s2,
        theme: SoneaThemePalette.wada255.dark,
      );
      final pLight = WidgetSyncPayload.fromState(
        playback: s2,
        theme: SoneaThemePalette.wada255.light,
      );

      expect(p1.computeFingerprint(), p2.computeFingerprint());
      expect(p1.computeFingerprint(), isNot(pLight.computeFingerprint()));
    });
  });
}
