import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonea/library/library_controller.dart';
import 'package:sonea/src/rust/api/library.dart' as rust;

class _FakeLibraryController extends LibraryController {
  _FakeLibraryController({
    this.permissionToReturn = 'granted',
    this.queryAudioHandler,
    this.scanPathsHandler,
  });

  String permissionToReturn;
  Future<List<Object?>> Function()? queryAudioHandler;
  Stream<String> Function(List<rust.MediaPath> paths)? scanPathsHandler;

  @override
  Future<void> ensureDatabase() async {}

  @override
  Future<String> fetchPermissionStatus() async => permissionToReturn;

  @override
  Future<String> invokeRequestAudioPermission() async => permissionToReturn;

  @override
  Future<List<Object?>> invokeQueryAudio() async {
    if (queryAudioHandler != null) return queryAudioHandler!();
    return const [];
  }

  @override
  Stream<String> invokeScanPaths({
    required String dbPath,
    required String cacheDir,
    required List<rust.MediaPath> paths,
  }) {
    if (scanPathsHandler != null) return scanPathsHandler!(paths);
    return const Stream.empty();
  }

  @override
  Future<LibraryState> loadFromDatabase(LibraryState current) async => current;
}

void main() {
  group('LibraryController scan error visibility & lock reset', () {
    test('resets _scanInFlight and exposes error on PlatformException(permission_denied)', () async {
      final fake = _FakeLibraryController(
        permissionToReturn: 'granted',
        queryAudioHandler: () async => throw PlatformException(
          code: 'permission_denied',
          message: 'READ_MEDIA_AUDIO is not granted',
        ),
      );
      final container = ProviderContainer(
        overrides: [libraryProvider.overrideWith(() => fake)],
      );
      addTearDown(container.dispose);

      await container.read(libraryProvider.future);
      await container.read(libraryProvider.notifier).scan();

      final state = container.read(libraryProvider).value!;
      expect(fake.isScanInFlight, isFalse);
      expect(state.scanning, isFalse);
      expect(state.permission, 'denied');
      expect(state.error, contains('READ_MEDIA_AUDIO'));

      container.read(libraryProvider.notifier).clearError();
      expect(container.read(libraryProvider).value!.error, isNull);
    });

    test('resets _scanInFlight and surfaces Rust stream errors cleanly', () async {
      final fake = _FakeLibraryController(
        permissionToReturn: 'granted',
        queryAudioHandler: () async => [
          {'path': '/storage/emulated/0/Music/a.flac', 'fileModified': 100},
        ],
        scanPathsHandler: (_) => Stream.error(StateError('SQLite disk I/O error')),
      );
      final container = ProviderContainer(
        overrides: [libraryProvider.overrideWith(() => fake)],
      );
      addTearDown(container.dispose);

      await container.read(libraryProvider.future);
      await container.read(libraryProvider.notifier).scan();

      final state = container.read(libraryProvider).value!;
      expect(fake.isScanInFlight, isFalse);
      expect(state.scanning, isFalse);
      expect(state.error, contains('SQLite disk I/O error'));
    });

    test('surfaces helpful message when device returns zero audio files', () async {
      final fake = _FakeLibraryController(
        permissionToReturn: 'granted',
        queryAudioHandler: () async => const [],
      );
      final container = ProviderContainer(
        overrides: [libraryProvider.overrideWith(() => fake)],
      );
      addTearDown(container.dispose);

      await container.read(libraryProvider.future);
      await container.read(libraryProvider.notifier).scan();

      final state = container.read(libraryProvider).value!;
      expect(fake.isScanInFlight, isFalse);
      expect(state.scanning, isFalse);
      expect(state.error, isNotNull);
    });

    test('streams live scanned_count / total_count / found_count progress before finish', () async {
      final progressStream = StreamController<String>();
      final fake = _FakeLibraryController(
        permissionToReturn: 'granted',
        queryAudioHandler: () async => List.generate(
          420,
          (i) => {'path': '/storage/emulated/0/Music/track_$i.flac', 'fileModified': 1000 + i},
        ),
        scanPathsHandler: (_) => progressStream.stream,
      );

      final container = ProviderContainer(
        overrides: [libraryProvider.overrideWith(() => fake)],
      );
      addTearDown(container.dispose);

      await container.read(libraryProvider.future);
      final observed = <(bool, int, int, int)>[];
      container.listen(libraryProvider, (_, next) {
        final v = next.value;
        if (v != null) {
          observed.add((v.scanning, v.processed, v.total, v.found));
        }
      });

      final scanFuture = container.read(libraryProvider.notifier).scan();
      await Future<void>.delayed(Duration.zero);

      // Immediately after queryAudio resolves, total must already be 420 (not stuck at 0).
      expect(container.read(libraryProvider).value!.scanning, isTrue);
      expect(container.read(libraryProvider).value!.total, 420);

      progressStream.add(jsonEncode({
        'processed': 148,
        'total': 420,
        'scanned_count': 148,
        'total_count': 420,
        'found_count': 145,
        'indexed': 148,
        'skipped': 0,
        'unreadable': 3,
        'finished': false,
      }));
      await Future<void>.delayed(Duration.zero);

      final mid = container.read(libraryProvider).value!;
      expect(mid.scanning, isTrue);
      expect(mid.processed, 148);
      expect(mid.total, 420);
      expect(mid.found, 145);

      progressStream.add(jsonEncode({
        'processed': 420,
        'total': 420,
        'scanned_count': 420,
        'total_count': 420,
        'found_count': 417,
        'indexed': 420,
        'skipped': 0,
        'unreadable': 3,
        'finished': true,
      }));
      await progressStream.close();
      await scanFuture;

      final done = container.read(libraryProvider).value!;
      expect(done.scanning, isFalse);
      expect(done.processed, 420);
      expect(done.total, 420);
      expect(done.found, 417);
      expect(observed.any((e) => e.$1 && e.$2 == 148 && e.$3 == 420), isTrue);
    });
  });
}
