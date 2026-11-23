import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonea/playback/queue_manager.dart';
import 'package:sonea/src/rust/api/library.dart';

Track _makeTrack(int id, String title) => Track(
      id: id,
      path: '/music/track_$id.mp3',
      title: title,
      fileModified: 100,
      addedAt: 100,
      playCount: 0,
    );

void main() {
  final t1 = _makeTrack(1, 'Track 1');
  final t2 = _makeTrack(2, 'Track 2');
  final t3 = _makeTrack(3, 'Track 3');
  final t4 = _makeTrack(4, 'Track 4');

  group('QueueManager tests', () {
    test('initial queue setup and navigation in normal mode', () {
      final qm = QueueManager(tracks: [t1, t2, t3], initialIndex: 0);

      expect(qm.effectiveQueue.length, 3);
      expect(qm.currentTrack?.title, 'Track 1');
      expect(qm.currentIndex, 0);

      expect(qm.next(), 1);
      expect(qm.currentTrack?.title, 'Track 2');

      expect(qm.next(), 2);
      expect(qm.currentTrack?.title, 'Track 3');

      expect(qm.next(), null); // end of queue in repeat off mode
      expect(qm.currentTrack?.title, 'Track 3');

      expect(qm.previous(), 1);
      expect(qm.currentTrack?.title, 'Track 2');
    });

    test('repeat modes (off, all, one)', () {
      final qm = QueueManager(tracks: [t1, t2]);

      // Repeat OFF
      expect(qm.next(), 1);
      expect(qm.next(), null);

      // Repeat ALL
      qm.setRepeatMode(RepeatMode.all);
      expect(qm.next(), 0);
      expect(qm.currentTrack?.title, 'Track 1');

      qm.jumpToIndex(0);
      expect(qm.previous(), 1);
      expect(qm.currentTrack?.title, 'Track 2');

      // Repeat ONE
      qm.setRepeatMode(RepeatMode.one);
      expect(qm.next(), 1);
      expect(qm.currentTrack?.title, 'Track 2');
      expect(qm.next(), 1);
      expect(qm.currentTrack?.title, 'Track 2');
    });

    test('shuffle keeps currently playing track at index 0', () {
      final rng = Random(42);
      final qm = QueueManager(
        tracks: [t1, t2, t3, t4],
        initialIndex: 1, // start on t2
        isShuffleEnabled: false,
        random: rng,
      );

      expect(qm.currentTrack?.title, 'Track 2');

      // Turn shuffle on
      qm.setShuffleMode(true);

      expect(qm.effectiveQueue.first.title, 'Track 2');
      expect(qm.currentIndex, 0);
      expect(qm.currentTrack?.title, 'Track 2');

      // Turn shuffle off -> reverts to original queue order with t2 selected
      qm.setShuffleMode(false);
      expect(qm.effectiveQueue, [t1, t2, t3, t4]);
      expect(qm.currentIndex, 1);
      expect(qm.currentTrack?.title, 'Track 2');
    });

    test('jump to index bounds checking', () {
      final qm = QueueManager(tracks: [t1, t2, t3]);

      expect(qm.jumpToIndex(2), isTrue);
      expect(qm.currentIndex, 2);

      expect(qm.jumpToIndex(-1), isFalse);
      expect(qm.jumpToIndex(5), isFalse);
      expect(qm.currentIndex, 2);
    });

    test('playNext inserts track immediately after current track', () {
      final qm = QueueManager(tracks: [t1, t3]);
      expect(qm.currentTrack?.title, 'Track 1');

      qm.playNext(t2);
      expect(qm.effectiveQueue.map((t) => t.title).toList(), ['Track 1', 'Track 2', 'Track 3']);
      expect(qm.currentTrack?.title, 'Track 1');
    });

    test('addToQueue appends track to end of queue', () {
      final qm = QueueManager(tracks: [t1, t2]);
      qm.addToQueue(t3);
      expect(qm.effectiveQueue.map((t) => t.title).toList(), ['Track 1', 'Track 2', 'Track 3']);
    });

    test('reorderQueue moves items and keeps current track index synced', () {
      final qm = QueueManager(tracks: [t1, t2, t3, t4], initialIndex: 0);
      qm.reorderQueue(2, 0); // Move Track 3 to front
      expect(qm.effectiveQueue.map((t) => t.title).toList(), ['Track 3', 'Track 1', 'Track 2', 'Track 4']);
      expect(qm.currentIndex, 1); // Track 1 moved to index 1
      expect(qm.currentTrack?.title, 'Track 1');
    });

    test('removeFromQueue removes item and updates index', () {
      final qm = QueueManager(tracks: [t1, t2, t3], initialIndex: 1); // Track 2
      qm.removeFromQueue(0); // Remove Track 1 before current
      expect(qm.effectiveQueue.map((t) => t.title).toList(), ['Track 2', 'Track 3']);
      expect(qm.currentIndex, 0); // Index shifted from 1 to 0
      expect(qm.currentTrack?.title, 'Track 2');
    });
  });
}
