import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sonea/core/app_logger.dart';
import 'package:sonea/core/app_paths.dart';
import 'package:sonea/playback/playback_controller.dart';
import 'package:sonea/settings/app_settings_controller.dart';
import 'package:sonea/src/rust/api/lyrics.dart' as rust_lyrics;

enum TransliterationMode { off, under, latin }

class LyricsState {
  const LyricsState({
    this.trackId,
    this.lyrics,
    this.mode = TransliterationMode.off,
    this.isLoading = false,
    this.error,
    this.isBulkDownloading = false,
    this.bulkProcessed = 0,
    this.bulkTotal = 0,
    this.bulkSynced = 0,
    this.bulkPlain = 0,
    this.bulkInstrumental = 0,
    this.bulkNotFound = 0,
    this.coverage,
  });

  final int? trackId;
  final rust_lyrics.LyricsResult? lyrics;
  final TransliterationMode mode;
  final bool isLoading;
  final String? error;
  final bool isBulkDownloading;
  final int bulkProcessed;
  final int bulkTotal;
  final int bulkSynced;
  final int bulkPlain;
  final int bulkInstrumental;
  final int bulkNotFound;
  final rust_lyrics.LyricsCoverageStats? coverage;

  LyricsState copyWith({
    int? trackId,
    rust_lyrics.LyricsResult? lyrics,
    bool clearLyrics = false,
    TransliterationMode? mode,
    bool? isLoading,
    String? error,
    bool clearError = false,
    bool? isBulkDownloading,
    int? bulkProcessed,
    int? bulkTotal,
    int? bulkSynced,
    int? bulkPlain,
    int? bulkInstrumental,
    int? bulkNotFound,
    rust_lyrics.LyricsCoverageStats? coverage,
  }) {
    return LyricsState(
      trackId: trackId ?? this.trackId,
      lyrics: clearLyrics ? null : lyrics ?? this.lyrics,
      mode: mode ?? this.mode,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : error ?? this.error,
      isBulkDownloading: isBulkDownloading ?? this.isBulkDownloading,
      bulkProcessed: bulkProcessed ?? this.bulkProcessed,
      bulkTotal: bulkTotal ?? this.bulkTotal,
      bulkSynced: bulkSynced ?? this.bulkSynced,
      bulkPlain: bulkPlain ?? this.bulkPlain,
      bulkInstrumental: bulkInstrumental ?? this.bulkInstrumental,
      bulkNotFound: bulkNotFound ?? this.bulkNotFound,
      coverage: coverage ?? this.coverage,
    );
  }
}

final lyricsControllerProvider =
    NotifierProvider<LyricsController, LyricsState>(LyricsController.new);

class LyricsController extends Notifier<LyricsState> {
  String? _dbPath;
  StreamSubscription? _bulkSub;

  Future<void> _ensureDb() async {
    if (_dbPath != null) return;
    _dbPath = await AppPaths.databasePath();
  }

  @override
  LyricsState build() {
    ref.onDispose(() {
      _bulkSub?.cancel();
    });
    final initialTranslit = ref.read(appSettingsProvider).japaneseTransliteration;
    _initListener();
    Future.microtask(() {
      final currentTrackId =
          ref.read(playbackControllerProvider).value?.currentTrack?.id;
      if (currentTrackId != null) {
        loadLyrics(currentTrackId.toInt());
      }
      refreshCoverage();
    });
    return LyricsState(
      mode: initialTranslit ? TransliterationMode.under : TransliterationMode.off,
    );
  }

  void _initListener() {
    ref.listen(
      playbackControllerProvider.select((s) => s.value?.currentTrack?.id),
      (prev, next) {
        if (next != null && next != prev) {
          loadLyrics(next.toInt());
        }
      },
    );
    ref.listen(
      appSettingsProvider.select((s) => s.japaneseTransliteration),
      (prev, next) {
        if (prev != next) {
          state = state.copyWith(
            mode: next ? TransliterationMode.under : TransliterationMode.off,
          );
        }
      },
    );
  }

  Future<void> loadLyrics(
    int trackId, {
    bool? allowNetwork,
    bool forceRefresh = false,
  }) async {
    await _ensureDb();
    final effectiveAllowNetwork =
        allowNetwork ?? ref.read(appSettingsProvider).autoFetchLyrics;
    state = state.copyWith(
      trackId: trackId,
      isLoading: true,
      clearError: true,
    );

    try {
      final res = await rust_lyrics.getLyrics(
        dbPath: _dbPath!,
        trackId: trackId,
        allowNetwork: effectiveAllowNetwork,
        forceRefresh: forceRefresh,
      );
      if (state.trackId == trackId) {
        state = state.copyWith(
          lyrics: res,
          clearLyrics: res == null,
          isLoading: false,
        );
      }
    } catch (e, st) {
      appLog('LyricsController', 'Error loading lyrics for track #$trackId', e, st);
      if (state.trackId == trackId) {
        state = state.copyWith(
          isLoading: false,
          error: e.toString(),
        );
      }
    }
  }

  Future<void> refreshLyrics() async {
    final currentTrackId = state.trackId ??
        ref.read(playbackControllerProvider).value?.currentTrack?.id.toInt();
    if (currentTrackId == null) return;
    await _ensureDb();
    state = state.copyWith(
      trackId: currentTrackId,
      isLoading: true,
      clearError: true,
    );
    try {
      final res = await rust_lyrics.refetchTrackLyrics(
        dbPath: _dbPath!,
        trackId: currentTrackId,
      );
      if (state.trackId == currentTrackId) {
        state = state.copyWith(
          lyrics: res,
          clearLyrics: res == null,
          isLoading: false,
        );
      }
    } catch (e, st) {
      appLog('LyricsController', 'refetchTrackLyrics failed for #$currentTrackId', e, st);
      if (state.trackId == currentTrackId) {
        state = state.copyWith(
          isLoading: false,
          error: e.toString(),
        );
      }
    }
    unawaited(refreshCoverage());
  }

  void setMode(TransliterationMode mode) {
    state = state.copyWith(mode: mode);
  }

  Future<List<rust_lyrics.LyricsCandidateDto>> searchCandidates({
    required String query,
    String? artist,
    int? durationSecs,
  }) async {
    return rust_lyrics.searchLyricsCandidates(
      query: query,
      artist: artist,
      durationSecs: durationSecs,
    );
  }

  Future<void> applyCustomLyrics({
    required int trackId,
    String? syncedLrc,
    String? plainLyrics,
    required String source,
  }) async {
    await _ensureDb();
    if (_dbPath == null) return;
    await rust_lyrics.saveCustomLyrics(
      dbPath: _dbPath!,
      trackId: trackId,
      syncedLrc: syncedLrc,
      plainLyrics: plainLyrics,
      source: source,
    );
    await loadLyrics(trackId, allowNetwork: false, forceRefresh: false);
    unawaited(refreshCoverage());
  }

  Future<rust_lyrics.LyricsCoverageStats?> getCoverageStats() async {
    await _ensureDb();
    if (_dbPath == null) return null;
    try {
      return await rust_lyrics.getLyricsCoverage(dbPath: _dbPath!);
    } catch (e) {
      appLog('LyricsController', 'Coverage error', e);
      return null;
    }
  }

  Future<void> refreshCoverage() async {
    final stats = await getCoverageStats();
    if (stats != null) {
      state = state.copyWith(coverage: stats);
    }
  }

  Future<void> startBulkDownload() async {
    await _ensureDb();
    if (_dbPath == null || state.isBulkDownloading) return;

    state = state.copyWith(
      isBulkDownloading: true,
      bulkProcessed: 0,
      bulkTotal: 0,
      bulkSynced: 0,
      bulkPlain: 0,
      bulkInstrumental: 0,
      bulkNotFound: 0,
    );

    _bulkSub?.cancel();
    final stream = rust_lyrics.bulkDownloadLyrics(dbPath: _dbPath!);
    _bulkSub = stream.listen(
      (raw) {
        try {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          final total = map['total'] as int? ?? 0;
          final processed = map['processed'] as int? ?? 0;
          final synced = map['success_synced'] as int? ?? 0;
          final plain = map['success_plain'] as int? ?? 0;
          final instrumental = map['instrumental_count'] as int? ?? 0;
          final notFound = map['not_found'] as int? ?? 0;
          final finished = map['finished'] as bool? ?? false;

          state = state.copyWith(
            isBulkDownloading: !finished,
            bulkTotal: total,
            bulkProcessed: processed,
            bulkSynced: synced,
            bulkPlain: plain,
            bulkInstrumental: instrumental,
            bulkNotFound: notFound,
          );

          if (finished) {
            refreshCoverage();
            if (state.trackId != null) {
              loadLyrics(state.trackId!, allowNetwork: false);
            }
          }
        } catch (e) {
          appLog('LyricsController', 'Bulk progress parse error', e);
        }
      },
      onError: (e) {
        state = state.copyWith(isBulkDownloading: false);
        refreshCoverage();
      },
      onDone: () {
        state = state.copyWith(isBulkDownloading: false);
        refreshCoverage();
      },
    );
  }

  Future<void> cancelBulkDownload() async {
    await rust_lyrics.cancelBulkDownload();
    _bulkSub?.cancel();
    state = state.copyWith(isBulkDownloading: false);
    refreshCoverage();
  }

  Future<void> clearAll() async {
    await _ensureDb();
    if (_dbPath == null) return;
    await rust_lyrics.clearAllLyrics(dbPath: _dbPath!);
    refreshCoverage();
    if (state.trackId != null) {
      loadLyrics(state.trackId!, allowNetwork: false);
    }
  }

  /// Clears auto-fetched cached lyrics while preserving manually saved/custom lyrics.
  /// Returns the number of cleared entries.
  Future<int> clearAutoCache() async {
    await _ensureDb();
    if (_dbPath == null) return 0;
    final cleared = await rust_lyrics.clearAutoLyricsCache(dbPath: _dbPath!);
    unawaited(refreshCoverage());
    if (state.trackId != null) {
      unawaited(loadLyrics(state.trackId!, allowNetwork: false));
    }
    return cleared;
  }
}
