import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:sonea/playback/playback_backend.dart';
import 'package:sonea/playback/queue_manager.dart';
import 'package:sonea/src/rust/api/library.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';

Track _makeTrack(int id, {String title = 'Track', String path = '/music/a.flac'}) {
  return Track(
    id: id,
    path: path,
    title: '$title $id',
    artist: 'Artist $id',
    album: 'Album $id',
    fileModified: 1,
    addedAt: 1,
    playCount: 0,
  );
}

void main() {
  group('PlaybackStateData', () {
    test('defaults to unmuted full volume without errors', () {
      const state = PlaybackStateData();
      expect(state.volume, 1.0);
      expect(state.isMuted, isFalse);
      expect(state.isLoading, isFalse);
      expect(state.errorMessage, isNull);
    });

    test('copyWith updates mute, error and clears error cleanly', () {
      final track = _makeTrack(1);
      final s1 = PlaybackStateData(
        currentTrack: track,
        queue: [track],
        volume: 0.65,
        isMuted: true,
        isLoading: true,
        errorMessage: 'Audio file not found',
      );

      final s2 = s1.copyWith(clearError: true, isLoading: false, isMuted: false);
      expect(s2.errorMessage, isNull);
      expect(s2.isLoading, isFalse);
      expect(s2.isMuted, isFalse);
      expect(s2.volume, 0.65);
      expect(s2.currentTrack?.id, 1);

      final s3 = s2.copyWith(clearCurrentTrack: true);
      expect(s3.currentTrack, isNull);
    });
  });

  group('QueueManager edge cases', () {
    test('removeFromQueue on last remaining track clears queue safely', () {
      final qm = QueueManager(tracks: [_makeTrack(1)]);
      qm.removeFromQueue(0);
      expect(qm.effectiveQueue, isEmpty);
      expect(qm.currentTrack, isNull);
      expect(qm.currentIndex, 0);
    });

    test('playNext on empty queue starts queue at index 0', () {
      final qm = QueueManager();
      qm.playNext(_makeTrack(42));
      expect(qm.effectiveQueue.length, 1);
      expect(qm.currentTrack?.id, 42);
      expect(qm.currentIndex, 0);
    });

    test('reorderQueue updates currentIndex accurately', () {
      final qm = QueueManager(
        tracks: [_makeTrack(1), _makeTrack(2), _makeTrack(3)],
        initialIndex: 1,
      );
      qm.reorderQueue(1, 2);
      expect(qm.currentIndex, 2);
      expect(qm.currentTrack?.id, 2);
    });
  });

  group('SoneaThemeTokens contrast', () {
    test('every Sanzo Wada palette provides high-contrast onAccentColor in dark and light', () {
      for (final palette in SoneaThemePalette.all) {
        for (final pack in [palette.dark, palette.light]) {
          final la = pack.accentColor.computeLuminance();
          final lb = pack.onAccentColor.computeLuminance();
          final ratio = (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason:
                'Theme ${palette.id}/${pack.isLight ? "light" : "dark"} failed WCAG AA onAccent',
          );
        }
      }
    });
  });
}
