import 'dart:convert';
import 'dart:io';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sonea/core/app_logger.dart';
import 'package:sonea/core/app_paths.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const _nativeChannel = MethodChannel('com.sonea.app/library');

class PlaylistCoversState {
  const PlaylistCoversState({
    this.customCovers = const {},
    this.revisions = const {},
  });

  /// Maps playlistId -> local file path inside app storage.
  final Map<int, String> customCovers;

  /// Per-playlist revision counter used to bust widget/image cache cleanly.
  final Map<int, int> revisions;

  String? coverPathFor(int playlistId) {
    final path = customCovers[playlistId];
    if (path == null || path.trim().isEmpty) return null;
    try {
      final file = File(path);
      if (file.existsSync() && file.lengthSync() > 0) return path;
    } catch (e) {
      appLog('PlaylistCoversState', 'coverPathFor stat failed', e);
      return null;
    }
    return null;
  }

  int revisionFor(int playlistId) => revisions[playlistId] ?? 0;

  PlaylistCoversState copyWith({
    Map<int, String>? customCovers,
    Map<int, int>? revisions,
  }) {
    return PlaylistCoversState(
      customCovers: customCovers ?? this.customCovers,
      revisions: revisions ?? this.revisions,
    );
  }
}

final playlistCoversProvider =
    NotifierProvider<PlaylistCoversController, PlaylistCoversState>(
  PlaylistCoversController.new,
);

class PlaylistCoversController extends Notifier<PlaylistCoversState> {
  static const _kPrefsKey = 'playlist_custom_covers_v1';
  SharedPreferences? _prefs;

  @override
  PlaylistCoversState build() {
    _load();
    return const PlaylistCoversState();
  }

  Future<SharedPreferences> _ensurePrefs() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  Future<void> _load() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_kPrefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final map = <int, String>{};
      for (final entry in decoded.entries) {
        final id = int.tryParse(entry.key);
        final val = entry.value;
        if (id != null && val is String && val.trim().isNotEmpty) {
          map[id] = val;
        }
      }
      state = state.copyWith(customCovers: map);
    } catch (e) {
      appLog('PlaylistCoversController', 'Corrupt playlist covers entry ignored', e);
    }
  }

  Future<void> _persist(Map<int, String> map) async {
    final prefs = await _ensurePrefs();
    final encoded = jsonEncode(
      map.map((k, v) => MapEntry(k.toString(), v)),
    );
    await prefs.setString(_kPrefsKey, encoded);
  }

  /// Opens the native Android Photo Picker (API 33+) / system image picker and
  /// saves a compressed <= 512x512 JPEG into `playlist_covers/playlist_<id>.jpg`.
  Future<String?> pickAndSetCover(int playlistId) async {
    final dir = await AppPaths.playlistCoversDir();
    final targetPath = p.join(dir, 'playlist_$playlistId.jpg');

    final savedPath = await _nativeChannel.invokeMethod<String>(
      'pickPlaylistCoverImage',
      {'outputPath': targetPath},
    );
    if (savedPath == null || savedPath.trim().isEmpty) return null;

    await setCustomCoverPath(playlistId, savedPath);
    return savedPath;
  }

  Future<void> setCustomCoverPath(int playlistId, String path) async {
    try {
      await FileImage(File(path)).evict();
    } catch (e) {
      appLog('PlaylistCoversController', 'evict cache skipped', e);
    }

    final nextCovers = Map<int, String>.from(state.customCovers)
      ..[playlistId] = path;
    final nextRevs = Map<int, int>.from(state.revisions)
      ..[playlistId] = (state.revisions[playlistId] ?? 0) + 1;
    state = PlaylistCoversState(
      customCovers: nextCovers,
      revisions: nextRevs,
    );
    await _persist(nextCovers);
  }

  Future<void> clearCustomCover(int playlistId) async {
    final existing = state.customCovers[playlistId];
    if (existing != null) {
      try {
        final file = File(existing);
        await FileImage(file).evict();
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        appLog('PlaylistCoversController', 'clearCustomCover file cleanup failed', e);
      }
    }

    final nextCovers = Map<int, String>.from(state.customCovers)
      ..remove(playlistId);
    final nextRevs = Map<int, int>.from(state.revisions)
      ..[playlistId] = (state.revisions[playlistId] ?? 0) + 1;
    state = PlaylistCoversState(
      customCovers: nextCovers,
      revisions: nextRevs,
    );
    await _persist(nextCovers);
  }
}
