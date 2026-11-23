import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonea/playback/queue_manager.dart';
import 'package:sonea/src/rust/api/library.dart';

List<Track> _buildTracks(int count) {
  return List.generate(
    count,
    (i) => Track(
      id: i + 1,
      path: '/music/track_$i.flac',
      title: 'Track $i',
      artist: 'Artist $i',
      album: 'Album $i',
      fileModified: 1,
      addedAt: 1,
      playCount: 0,
    ),
  );
}

void main() {
  group('Shuffle initial start behavior', () {
    test('pickRandomStart does not pin index 0 and starts from varied tracks', () {
      final tracks = _buildTracks(20);
      final firstTrackIds = <int>{};

      for (int seed = 1; seed <= 15; seed++) {
        final qm = QueueManager(random: Random(seed));
        qm.setQueue(tracks, shuffle: true, pickRandomStart: true);

        expect(qm.isShuffleEnabled, isTrue);
        expect(qm.currentIndex, 0);
        expect(qm.effectiveQueue.length, tracks.length);
        // Every track appears exactly once in the shuffled queue.
        expect(
          qm.effectiveQueue.map((t) => t.id.toInt()).toSet(),
          tracks.map((t) => t.id.toInt()).toSet(),
        );
        firstTrackIds.add(qm.currentTrack!.id.toInt());
      }

      // Across 15 distinct seeds on 20 tracks, start track must vary and not stay stuck on track #1.
      expect(firstTrackIds.length, greaterThan(1));
      expect(firstTrackIds.any((id) => id != 1), isTrue);
    });

    test('pickRandomStart false preserves explicit tapped track at index 0', () {
      final tracks = _buildTracks(10);
      final qm = QueueManager(random: Random(42));
      qm.setQueue(tracks, initialIndex: 4, shuffle: true, pickRandomStart: false);

      expect(qm.currentIndex, 0);
      expect(qm.currentTrack?.id, 5);
      expect(qm.effectiveQueue.length, 10);
    });
  });
}
