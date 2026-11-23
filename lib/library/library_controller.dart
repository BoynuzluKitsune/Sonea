import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sonea/core/app_logger.dart';
import 'package:sonea/core/app_paths.dart';
import 'package:sonea/src/rust/api/library.dart' as rust;

const _nativeLibraryChannel = MethodChannel('com.sonea.app/library');

class LibraryState {
  const LibraryState({
    this.permission = 'checking',
    this.tab = 0,
    this.query = '',
    this.tracks = const [],
    this.groups = const [],
    this.albums = const [],
    this.artists = const [],
    this.processed = 0,
    this.total = 0,
    this.found = 0,
    this.indexed = 0,
    this.skipped = 0,
    this.unreadable = 0,
    this.scanDurationMs = 0,
    this.scanning = false,
    this.error,
  });

  final String permission;
  final int tab;
  final String query;
  final List<rust.Track> tracks;
  final List<String> groups;
  final List<String> albums;
  final List<String> artists;
  final int processed;
  final int total;
  final int found;
  final int indexed;
  final int skipped;
  final int unreadable;
  final int scanDurationMs;
  final bool scanning;
  final String? error;

  LibraryState copyWith({
    String? permission,
    int? tab,
    String? query,
    List<rust.Track>? tracks,
    List<String>? groups,
    List<String>? albums,
    List<String>? artists,
    int? processed,
    int? total,
    int? found,
    int? indexed,
    int? skipped,
    int? unreadable,
    int? scanDurationMs,
    bool? scanning,
    String? error,
    bool clearError = false,
  }) =>
      LibraryState(
        permission: permission ?? this.permission,
        tab: tab ?? this.tab,
        query: query ?? this.query,
        tracks: tracks ?? this.tracks,
        groups: groups ?? this.groups,
        albums: albums ?? this.albums,
        artists: artists ?? this.artists,
        processed: processed ?? this.processed,
        total: total ?? this.total,
        found: found ?? this.found,
        indexed: indexed ?? this.indexed,
        skipped: skipped ?? this.skipped,
        unreadable: unreadable ?? this.unreadable,
        scanDurationMs: scanDurationMs ?? this.scanDurationMs,
        scanning: scanning ?? this.scanning,
        error: clearError ? null : error ?? this.error,
      );
}

final libraryProvider =
    AsyncNotifierProvider<LibraryController, LibraryState>(
  LibraryController.new,
);

class LibraryController extends AsyncNotifier<LibraryState> {
  String? _dbPath;
  String? _cacheDir;
  bool _scanInFlight = false;

  @visibleForTesting
  bool get isScanInFlight => _scanInFlight;

  @protected
  Future<void> ensureDatabase() async {
    if (_dbPath != null && _cacheDir != null) return;
    _dbPath = await AppPaths.databasePath();
    _cacheDir = await AppPaths.cacheDir();
    await rust.initializeDatabase(dbPath: _dbPath!);
  }

  @protected
  Future<String> fetchPermissionStatus() async {
    try {
      return await _nativeLibraryChannel
              .invokeMethod<String>('permissionStatus') ??
          'denied';
    } on MissingPluginException {
      return 'denied';
    }
  }

  @protected
  Future<String> invokeRequestAudioPermission() async {
    return await _nativeLibraryChannel
            .invokeMethod<String>('requestAudioPermission') ??
        'denied';
  }

  @protected
  Future<List<Object?>> invokeQueryAudio() async {
    return await _nativeLibraryChannel.invokeListMethod<Object?>('queryAudio') ??
        const [];
  }

  @protected
  Stream<String> invokeScanPaths({
    required String dbPath,
    required String cacheDir,
    required List<rust.MediaPath> paths,
  }) {
    return rust.scanPaths(
      dbPath: dbPath,
      cacheDir: cacheDir,
      paths: paths,
    );
  }

  @protected
  Future<LibraryState> loadFromDatabase(LibraryState current) async {
    await ensureDatabase();
    final db = _dbPath!;
    final results = await Future.wait([
      rust.searchTracks(dbPath: db, query: current.query),
      rust.listAlbums(dbPath: db, query: current.query),
      rust.listArtists(dbPath: db, query: current.query),
    ]);
    return current.copyWith(
      tracks: results[0] as List<rust.Track>,
      albums: results[1] as List<String>,
      artists: results[2] as List<String>,
      clearError: true,
    );
  }

  @override
  Future<LibraryState> build() async {
    try {
      await ensureDatabase();
    } catch (e, st) {
      appLog('LibraryController', 'database init failed', e, st);
      return LibraryState(permission: 'denied', error: 'Database error: $e');
    }

    String permission = 'denied';
    try {
      permission = await fetchPermissionStatus();
    } on PlatformException catch (e) {
      appLog('LibraryController', 'permissionStatus failed', e.code);
      return LibraryState(permission: 'denied', error: e.message ?? e.code);
    }

    final initial = LibraryState(permission: permission);
    if (permission == 'granted') {
      try {
        return await loadFromDatabase(initial);
      } catch (e, st) {
        appLog('LibraryController', 'initial load failed', e, st);
        return initial.copyWith(error: e.toString());
      }
    }
    return initial;
  }

  Future<void> setTab(int tab) async {
    final current = state.value ?? const LibraryState();
    if (current.tab == tab) return;
    state = AsyncData(current.copyWith(tab: tab));
  }

  void clearError() {
    final current = state.value;
    if (current != null && current.error != null) {
      state = AsyncData(current.copyWith(clearError: true));
    }
  }

  Future<void> search(String query) async {
    final current = state.value ?? const LibraryState();
    if (current.query == query) return;
    try {
      state = AsyncData(await loadFromDatabase(current.copyWith(query: query)));
    } catch (e, st) {
      appLog('LibraryController', 'search failed', e, st);
      state = AsyncData(current.copyWith(query: query, error: e.toString()));
    }
  }

  /// Re-checks Android audio permission (e.g. when returning from App Settings).
  Future<void> refreshPermission() async {
    final current = state.value ?? const LibraryState();
    try {
      final latest = await fetchPermissionStatus();
      if (latest == current.permission) return;
      if (latest == 'granted') {
        state = AsyncData(
          await loadFromDatabase(
            current.copyWith(permission: latest, clearError: true),
          ),
        );
        await scan();
      } else {
        state = AsyncData(current.copyWith(permission: latest));
      }
    } catch (e, st) {
      appLog('LibraryController', 'refreshPermission failed', e, st);
    }
  }

  Future<void> requestPermission() async {
    final current = state.value ?? const LibraryState();
    try {
      final permission = await invokeRequestAudioPermission();
      if (permission == 'granted') {
        state = AsyncData(
          await loadFromDatabase(
            current.copyWith(permission: permission, clearError: true),
          ),
        );
        await scan();
      } else {
        state = AsyncData(current.copyWith(permission: permission));
      }
    } on PlatformException catch (e) {
      appLog('LibraryController', 'requestPermission failed', e.code);
      state = AsyncData(current.copyWith(error: e.message ?? e.code));
    }
  }

  Future<void> openSettings() async {
    try {
      await _nativeLibraryChannel.invokeMethod<void>('openAppSettings');
    } on PlatformException catch (e) {
      appLog('LibraryController', 'openSettings failed', e.code);
    }
  }

  Future<void> scan() async {
    if (_scanInFlight) return;
    _scanInFlight = true;

    final stopwatch = Stopwatch()..start();
    final current = state.value ?? const LibraryState();
    var baseline = current;

    try {
      if (current.permission != 'granted') {
        final refreshed = await fetchPermissionStatus();
        if (refreshed != 'granted') {
          _scanInFlight = false;
          await requestPermission();
          return;
        }
        baseline = current.copyWith(permission: 'granted');
        state = AsyncData(baseline);
      }

      state = AsyncData(baseline.copyWith(
        scanning: true,
        processed: 0,
        total: 0,
        found: 0,
        indexed: 0,
        skipped: 0,
        unreadable: 0,
        scanDurationMs: 0,
        clearError: true,
      ));
      await ensureDatabase();
      final rows = await invokeQueryAudio();
      final paths = <rust.MediaPath>[];
      for (final row in rows) {
        if (row is! Map) continue;
        final item = Map<Object?, Object?>.from(row);
        final path = item['path'];
        final modified = item['fileModified'];
        if (path is String && path.trim().isNotEmpty && modified is num) {
          paths.add(rust.MediaPath(
            path: path,
            fileModified: modified.toInt(),
          ));
        }
      }

      if (paths.isEmpty) {
        stopwatch.stop();
        final reloaded = await loadFromDatabase(
          (state.value ?? baseline).copyWith(
            scanning: false,
            scanDurationMs: stopwatch.elapsedMilliseconds,
          ),
        );
        state = AsyncData(reloaded.copyWith(
          error: reloaded.tracks.isEmpty
              ? 'No audio files found on device storage.'
              : null,
        ));
        return;
      }

      // Immediately reflect discovered total count so UI never sits at "0 / 0".
      state = AsyncData((state.value ?? baseline).copyWith(
        scanning: true,
        processed: 0,
        total: paths.length,
        found: 0,
      ));

      await for (final raw in invokeScanPaths(
        dbPath: _dbPath ?? '',
        cacheDir: _cacheDir ?? '',
        paths: paths,
      )) {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final now = state.value ?? baseline;
        final nextTotal = (decoded['total_count'] as num?)?.toInt() ??
            (decoded['total'] as num?)?.toInt() ??
            now.total;
        final nextProcessed = (decoded['scanned_count'] as num?)?.toInt() ??
            (decoded['processed'] as num?)?.toInt() ??
            now.processed;
        final nextIndexed = (decoded['indexed'] as num?)?.toInt() ?? now.indexed;
        final nextSkipped = (decoded['skipped'] as num?)?.toInt() ?? now.skipped;
        final nextUnreadable =
            (decoded['unreadable'] as num?)?.toInt() ?? now.unreadable;
        final nextFound = (decoded['found_count'] as num?)?.toInt() ??
            (nextIndexed + nextSkipped - nextUnreadable).clamp(0, nextTotal);
        final finished = decoded['finished'] as bool? ?? false;

        state = AsyncData(now.copyWith(
          processed: nextProcessed,
          total: nextTotal,
          found: nextFound,
          indexed: nextIndexed,
          skipped: nextSkipped,
          unreadable: nextUnreadable,
          scanning: !finished,
        ));
      }

      stopwatch.stop();
      final latest = state.value ?? baseline;
      final durationMs = stopwatch.elapsedMilliseconds;
      state = AsyncData(await loadFromDatabase(
        latest.copyWith(scanning: false, scanDurationMs: durationMs),
      ));
      appLog(
        'LibraryController',
        'scan complete: ${latest.indexed} indexed, ${latest.skipped} skipped, '
            '${latest.unreadable} unreadable in ${durationMs}ms (${latest.total} files)',
      );
    } on PlatformException catch (e) {
      appLog('LibraryController', 'scan platform error', e.code);
      final isPermError =
          e.code == 'permission_denied' || e.code == 'permission_revoked';
      state = AsyncData(
        (state.value ?? baseline).copyWith(
          scanning: false,
          permission: isPermError ? 'denied' : null,
          error: e.message ?? e.code,
        ),
      );
    } catch (e, st) {
      appLog('LibraryController', 'scan error', e, st);
      state = AsyncData(
        (state.value ?? baseline).copyWith(
          scanning: false,
          error: e.toString(),
        ),
      );
    } finally {
      _scanInFlight = false;
    }
  }
}
