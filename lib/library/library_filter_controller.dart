import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sonea/src/rust/api/library.dart' as rust;
import 'package:shared_preferences/shared_preferences.dart';

class LibraryFilterState {
  static const int defaultMinTrackDurationSec = 30;

  const LibraryFilterState({
    this.minTrackDurationSec = defaultMinTrackDurationSec,
    this.excludedFolders = const [],
  });

  final int minTrackDurationSec; // 0 (Off), 15, 30, 60
  final List<String> excludedFolders;

  LibraryFilterState copyWith({
    int? minTrackDurationSec,
    List<String>? excludedFolders,
  }) {
    return LibraryFilterState(
      minTrackDurationSec: minTrackDurationSec ?? this.minTrackDurationSec,
      excludedFolders: excludedFolders ?? this.excludedFolders,
    );
  }

  bool isTrackAllowed(rust.Track track) {
    if (minTrackDurationSec > 0) {
      final durSec = (track.durationMs ?? 0) / 1000;
      if (durSec < minTrackDurationSec) return false;
    }

    if (excludedFolders.isNotEmpty) {
      final parent = File(track.path).parent.path;
      if (excludedFolders.contains(parent)) return false;
    }

    return true;
  }
}

final libraryFilterProvider =
    NotifierProvider<LibraryFilterController, LibraryFilterState>(
        LibraryFilterController.new);

class LibraryFilterController extends Notifier<LibraryFilterState> {
  static const _kMinDurKey = 'filter_min_duration_sec';
  static const _kExcludedFoldersKey = 'filter_excluded_folders';

  @override
  LibraryFilterState build() {
    _loadFromPrefs();
    return const LibraryFilterState();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final minDur =
        prefs.getInt(_kMinDurKey) ?? LibraryFilterState.defaultMinTrackDurationSec;
    final excluded = prefs.getStringList(_kExcludedFoldersKey) ?? [];

    state = LibraryFilterState(
      minTrackDurationSec: minDur,
      excludedFolders: excluded,
    );
  }

  Future<void> resetToDefaults() async {
    state = const LibraryFilterState();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kMinDurKey);
    await prefs.remove(_kExcludedFoldersKey);
  }

  Future<void> setMinDurationSec(int seconds) async {
    state = state.copyWith(minTrackDurationSec: seconds);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kMinDurKey, seconds);
  }

  Future<void> toggleExcludedFolder(String folderPath) async {
    final list = List<String>.from(state.excludedFolders);
    if (list.contains(folderPath)) {
      list.remove(folderPath);
    } else {
      list.add(folderPath);
    }
    state = state.copyWith(excludedFolders: list);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kExcludedFoldersKey, list);
  }

  Future<void> addExcludedFolder(String folderPath) async {
    if (!state.excludedFolders.contains(folderPath)) {
      final list = List<String>.from(state.excludedFolders)..add(folderPath);
      state = state.copyWith(excludedFolders: list);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kExcludedFoldersKey, list);
    }
  }

  Future<void> removeExcludedFolder(String folderPath) async {
    if (state.excludedFolders.contains(folderPath)) {
      final list = List<String>.from(state.excludedFolders)..remove(folderPath);
      state = state.copyWith(excludedFolders: list);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kExcludedFoldersKey, list);
    }
  }
}
