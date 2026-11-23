import 'package:flutter_test/flutter_test.dart';
import 'package:sonea/library/library_filter_controller.dart';
import 'package:sonea/src/rust/api/library.dart';

Track _makeTrack(int id, String path, int durationMs) => Track(
      id: id,
      path: path,
      title: 'Track $id',
      durationMs: durationMs,
      fileModified: 100,
      addedAt: 100,
      playCount: 0,
    );

void main() {
  final shortTrack = _makeTrack(1, '/music/short.mp3', 10000); // 10s
  final longTrack = _makeTrack(2, '/music/long.mp3', 45000); // 45s
  final whatsappTrack = _makeTrack(3, '/sdcard/WhatsApp Audio/voice.opus', 5000);

  group('LibraryFilterState unit tests', () {
    test('defaults to 30s short-audio filter out of the box', () {
      const state = LibraryFilterState();
      expect(state.minTrackDurationSec, 30);
      expect(state.isTrackAllowed(shortTrack), isFalse);
      expect(state.isTrackAllowed(longTrack), isTrue);
    });

    test('Filter Off allows all tracks', () {
      const state = LibraryFilterState(minTrackDurationSec: 0);
      expect(state.isTrackAllowed(shortTrack), isTrue);
      expect(state.isTrackAllowed(longTrack), isTrue);
    });

    test('minTrackDurationSec filters short audio', () {
      const state = LibraryFilterState(minTrackDurationSec: 30);
      expect(state.isTrackAllowed(shortTrack), isFalse); // 10s < 30s
      expect(state.isTrackAllowed(longTrack), isTrue); // 45s >= 30s
    });

    test('excludedFolders filters tracks in excluded directory', () {
      const state = LibraryFilterState(
        minTrackDurationSec: 0,
        excludedFolders: ['/sdcard/WhatsApp Audio'],
      );

      expect(state.isTrackAllowed(longTrack), isTrue);
      expect(state.isTrackAllowed(whatsappTrack), isFalse);
    });
  });
}
