import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:sonea/core/app_logger.dart';
import 'package:sonea/core/app_paths.dart';
import 'package:sonea/library/playlist_cover_service.dart';
import 'package:sonea/playback/just_audio_backend.dart';
import 'package:sonea/playback/playback_backend.dart';
import 'package:sonea/playback/queue_manager.dart';
import 'package:sonea/playback/replay_gain_controller.dart';
import 'package:sonea/playback/widget_payload.dart';
import 'package:sonea/settings/app_settings_controller.dart';
import 'package:sonea/src/rust/api/library.dart' as rust;
import 'package:sonea/src/rust/api/playlists.dart' as rust_pl;
import 'package:sonea/theme/theme_controller.dart';
import 'package:sonea/ui/playlists/playlists_tab.dart'
    show playlistsRefreshProvider;

const _nativeLibraryChannel = MethodChannel('com.sonea.app/library');
const _nativeWidgetChannel = MethodChannel('com.sonea.app/widgets');

/// Bumped whenever the Cover Tile Android widget requests opening Now Playing.
final widgetOpenNowPlayingProvider =
    NotifierProvider<WidgetOpenNowPlayingNotifier, int>(
  WidgetOpenNowPlayingNotifier.new,
);

class WidgetOpenNowPlayingNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void requestOpen() => state++;
}

final playbackControllerProvider =
    AsyncNotifierProvider<PlaybackController, PlaybackStateData>(
  PlaybackController.new,
);

class PlaybackController extends AsyncNotifier<PlaybackStateData> {
  PlaybackBackend? _backend;
  String? _dbPath;
  StreamSubscription<PlaybackStateData>? _subscription;
  DateTime _lastSaveTime = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _trailingSaveTimer;
  Timer? _widgetThemeDebounceTimer;

  String? _lastWidgetFingerprint;
  List<WidgetPlaylistShortcut> _cachedWidgetPlaylists = const [];

  @override
  Future<PlaybackStateData> build() async {
    _dbPath = await AppPaths.databasePath();

    if (_backend == null) {
      _backend = await JustAudioBackend.init(dbPath: _dbPath!);
      _subscription = _backend!.playbackStateStream.listen(_onStateChanged);
      _initWidgetChannel();
      _initReplayGainListener();
      _initWidgetSyncListeners();
      _initSettingsListener();
    }

    await _refreshWidgetPlaylists();

    try {
      final saved = await rust.loadPlaybackState(dbPath: _dbPath!);
      if (saved != null && saved.queueTrackIds.isNotEmpty) {
        final tracks = await rust.getTracksByIds(
          dbPath: _dbPath!,
          ids: saved.queueTrackIds,
        );
        if (tracks.isNotEmpty) {
          final safeIndex = saved.currentIndex.clamp(0, tracks.length - 1);
          final safePosMs = saved.positionMs.toInt().clamp(0, 86400000);
          await _backend!.setQueue(
            tracks,
            initialIndex: safeIndex,
            initialPosition: Duration(milliseconds: safePosMs),
            playImmediately: false,
          );
        }
      }
    } catch (e, st) {
      appLog('PlaybackController', 'Failed to restore playback state: $e\n$st');
    }

    ref.onDispose(() {
      _trailingSaveTimer?.cancel();
      _widgetThemeDebounceTimer?.cancel();
      _subscription?.cancel();
    });

    final current = _backend!.currentState;
    _updateWidgetDataIfNeeded(current);
    unawaited(_consumePendingWidgetAction());
    return current;
  }

  Future<void> _consumePendingWidgetAction() async {
    if (!Platform.isAndroid) return;
    try {
      final raw = await _nativeWidgetChannel
          .invokeMethod<Object?>('getPendingWidgetAction');
      if (raw != null) {
        await _handleWidgetActionArguments(raw);
      }
    } on MissingPluginException {
      // Ignored in tests or non-Android platforms.
    } catch (e) {
      appLog('PlaybackController', 'getPendingWidgetAction failed: $e');
    }
  }

  void _initSettingsListener() {
    void apply(AppSettings s) {
      _backend?.setAudioBehavior(
        pauseOnNoisy: s.pauseOnNoisy,
        duckOnInterruption:
            s.interruptionBehavior == AudioInterruptionBehavior.duck,
      );
      unawaited(_backend?.setPlaybackSpeed(s.playbackSpeed));
    }

    apply(ref.read(appSettingsProvider));
    ref.listen(appSettingsProvider, (_, next) => apply(next));
  }

  void _initWidgetSyncListeners() {
    ref.listen(themeControllerProvider, (_, _) {
      // Debounce theme-driven widget updates by 300ms so rapid theme switching
      // stays instant at 60 FPS without spamming MethodChannel or disk I/O.
      _widgetThemeDebounceTimer?.cancel();
      _widgetThemeDebounceTimer = Timer(const Duration(milliseconds: 300), () {
        final current = state.value ?? _backend?.currentState;
        if (current != null) {
          _updateWidgetDataIfNeeded(current);
        }
      });
    });

    ref.listen(playlistsRefreshProvider, (_, _) {
      unawaited(_refreshWidgetPlaylists().then((_) {
        final current = state.value ?? _backend?.currentState;
        if (current != null) {
          _updateWidgetDataIfNeeded(current);
        }
      }));
    });

    ref.listen(playlistCoversProvider, (_, _) {
      unawaited(_refreshWidgetPlaylists().then((_) {
        final current = state.value ?? _backend?.currentState;
        if (current != null) {
          _updateWidgetDataIfNeeded(current);
        }
      }));
    });
  }

  Future<void> _refreshWidgetPlaylists() async {
    if (_dbPath == null) return;
    try {
      final list = await rust_pl.listPlaylists(dbPath: _dbPath!);
      final covers = ref.read(playlistCoversProvider);
      // Sort most recently updated first for Quick Mix Dock shortcuts.
      final sorted = List<rust_pl.Playlist>.from(list)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _cachedWidgetPlaylists = sorted
          .take(3)
          .map(
            (p) => WidgetPlaylistShortcut(
              id: p.id.toInt(),
              name: p.name,
              trackCount: p.trackCount,
              coverPath: covers.coverPathFor(p.id.toInt()),
            ),
          )
          .toList(growable: false);
    } catch (e) {
      appLog('PlaybackController', '_refreshWidgetPlaylists failed: $e');
    }
  }

  void _onStateChanged(PlaybackStateData data) {
    final prev = state.value;
    final trackChanged = data.currentTrack?.id != prev?.currentTrack?.id;
    final playingChanged = data.isPlaying != prev?.isPlaying;
    final queueChanged = data.queue.length != prev?.queue.length ||
        data.currentIndex != prev?.currentIndex ||
        data.isShuffleEnabled != prev?.isShuffleEnabled;

    state = AsyncData(data);

    if (trackChanged) {
      _applyReplayGain();
    }

    if (trackChanged || playingChanged || queueChanged) {
      _scheduleSaveState(data, immediate: true);
    } else {
      _scheduleSaveState(data, immediate: false);
    }

    _updateWidgetDataIfNeeded(data);
  }

  void _initReplayGainListener() {
    ref.listen(replayGainControllerProvider, (prev, next) {
      _applyReplayGain();
    });
  }

  void _applyReplayGain() {
    if (_backend == null) return;
    final track = state.value?.currentTrack;
    if (track == null) return;

    final rgState = ref.read(replayGainControllerProvider);
    final multiplier = rgState.computeVolumeMultiplier(
      trackGainDb: track.replaygainTrackGain,
      albumGainDb: track.replaygainAlbumGain,
      trackPeak: track.replaygainTrackPeak,
    );

    unawaited(_backend!.setReplayGainMultiplier(multiplier));
  }

  void _initWidgetChannel() {
    _nativeWidgetChannel.setMethodCallHandler((call) async {
      if (call.method != 'onWidgetAction') return;
      await _handleWidgetActionArguments(call.arguments);
    });
  }

  Future<void> _handleWidgetActionArguments(Object? rawArgs) async {
    String? action;
    int? queueIndex;
    int? playlistId;

    if (rawArgs is String) {
      action = rawArgs;
    } else if (rawArgs is Map) {
      final args = Map<Object?, Object?>.from(rawArgs);
      action = args['action'] as String?;
      queueIndex = (args['queueIndex'] as num?)?.toInt();
      playlistId = (args['playlistId'] as num?)?.toInt();
    }

    switch (action) {
      case 'com.sonea.app.WIDGET_PREVIOUS':
        await previous();
        break;
      case 'com.sonea.app.WIDGET_PLAY_PAUSE':
        await togglePlayPause();
        break;
      case 'com.sonea.app.WIDGET_NEXT':
        await next();
        break;
      case 'com.sonea.app.WIDGET_TOGGLE_SHUFFLE':
        await toggleShuffle();
        break;
      case 'com.sonea.app.WIDGET_JUMP_QUEUE':
        if (queueIndex != null) {
          await jumpToIndex(queueIndex);
        }
        break;
      case 'com.sonea.app.WIDGET_PLAY_SHUFFLED_ALL':
        await _playAllLibraryShuffled();
        break;
      case 'com.sonea.app.WIDGET_PLAY_PLAYLIST':
        if (playlistId != null) {
          await _playPlaylistById(playlistId);
        }
        break;
      case 'com.sonea.app.WIDGET_OPEN_NOW_PLAYING':
        ref.read(widgetOpenNowPlayingProvider.notifier).requestOpen();
        break;
    }
  }

  Future<void> _playAllLibraryShuffled() async {
    if (_dbPath == null) return;
    try {
      final tracks = await rust.searchTracks(dbPath: _dbPath!, query: '');
      if (tracks.isNotEmpty) {
        await playShuffled(tracks);
      }
    } catch (e, st) {
      appLog('PlaybackController', '_playAllLibraryShuffled failed: $e\n$st');
    }
  }

  Future<void> _playPlaylistById(int playlistId) async {
    if (_dbPath == null) return;
    try {
      final tracks = await rust_pl.getPlaylistTracks(
        dbPath: _dbPath!,
        playlistId: playlistId,
      );
      if (tracks.isNotEmpty) {
        await playTrackList(tracks, 0);
      }
    } catch (e, st) {
      appLog('PlaybackController', '_playPlaylistById failed: $e\n$st');
    }
  }

  void _updateWidgetDataIfNeeded(PlaybackStateData data) {
    if (!Platform.isAndroid) return;
    final platformBrightness =
        PlatformDispatcher.instance.platformBrightness;
    final theme = ref
        .read(themeControllerProvider)
        .resolveForPlatform(platformBrightness);
    final payload = WidgetSyncPayload.fromState(
      playback: data,
      theme: theme,
      playlists: _cachedWidgetPlaylists,
    );
    final fingerprint = payload.computeFingerprint();
    if (fingerprint == _lastWidgetFingerprint) return;
    _lastWidgetFingerprint = fingerprint;

    unawaited(
      _nativeWidgetChannel
          .invokeMethod<void>(
            'syncFullWidgetState',
            payload.toMethodChannelMap(),
          )
          .catchError((Object e) {
        appLog('PlaybackController', 'syncFullWidgetState failed: $e');
      }),
    );
  }

  void _scheduleSaveState(PlaybackStateData data, {required bool immediate}) {
    if (_dbPath == null || data.queue.isEmpty) return;

    final now = DateTime.now();
    if (immediate ||
        now.difference(_lastSaveTime) >= const Duration(seconds: 5)) {
      _trailingSaveTimer?.cancel();
      _lastSaveTime = now;
      unawaited(_saveState(data));
      return;
    }

    _trailingSaveTimer?.cancel();
    _trailingSaveTimer = Timer(const Duration(seconds: 5), () {
      _lastSaveTime = DateTime.now();
      final latest = state.value;
      if (latest != null) {
        unawaited(_saveState(latest));
      }
    });
  }

  Future<void> _saveState(PlaybackStateData data) async {
    if (_dbPath == null || data.queue.isEmpty) return;
    try {
      final ids = data.queue.map((t) => t.id).toList(growable: false);
      await rust.savePlaybackState(
        dbPath: _dbPath!,
        queueTrackIds: Int64List.fromList(ids),
        currentIndex: data.currentIndex.clamp(0, ids.length - 1),
        positionMs: data.position.inMilliseconds,
      );
    } catch (e) {
      appLog('PlaybackController', '_saveState failed: $e');
    }
  }

  Future<void> requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeLibraryChannel
          .invokeMethod<String>('requestNotificationPermission');
    } on MissingPluginException {
      // Ignore on unsupported platforms/tests.
    } catch (e) {
      appLog('PlaybackController', 'requestNotificationPermission failed: $e');
    }
  }

  Future<void> skipTo(int index) async {
    await _backend?.jumpToIndex(index);
  }

  Future<void> playTrackList(List<rust.Track> tracks, int index) async {
    if (_backend == null || tracks.isEmpty) return;
    unawaited(requestNotificationPermission());
    await _backend!.setQueue(
      tracks,
      initialIndex: index,
      playImmediately: true,
    );
  }

  /// Starts playback of [tracks] in shuffle mode from a truly random track.
  Future<void> playShuffled(List<rust.Track> tracks) async {
    if (_backend == null || tracks.isEmpty) return;
    unawaited(requestNotificationPermission());
    await _backend!.setQueue(
      tracks,
      initialIndex: 0,
      playImmediately: true,
      shuffle: true,
      pickRandomStart: true,
    );
  }

  Future<void> togglePlayPause() async {
    if (_backend == null) return;
    final current = state.value;
    if (current == null || current.queue.isEmpty) return;
    if (current.isPlaying) {
      await _backend!.pause();
    } else {
      unawaited(requestNotificationPermission());
      await _backend!.play();
    }
  }

  Future<void> play() async {
    if (_backend == null) return;
    unawaited(requestNotificationPermission());
    await _backend!.play();
  }

  Future<void> pause() async {
    if (_backend == null) return;
    await _backend!.pause();
  }

  Future<void> seek(Duration position) async {
    if (_backend == null) return;
    await _backend!.seek(position);
  }

  Future<void> next() async {
    if (_backend == null) return;
    unawaited(requestNotificationPermission());
    await _backend!.next();
  }

  Future<void> previous() async {
    if (_backend == null) return;
    unawaited(requestNotificationPermission());
    await _backend!.previous();
  }

  Future<void> jumpToIndex(int index) async {
    if (_backend == null) return;
    unawaited(requestNotificationPermission());
    await _backend!.jumpToIndex(index);
  }

  Future<void> setShuffleMode(bool enabled) async {
    if (_backend == null) return;
    await _backend!.setShuffleMode(enabled);
  }

  Future<void> toggleShuffle() async {
    if (_backend == null) return;
    final current = state.value;
    if (current == null) return;
    await _backend!.setShuffleMode(!current.isShuffleEnabled);
  }

  Future<void> toggleRepeat() async {
    if (_backend == null) return;
    final current = state.value;
    if (current == null) return;
    final nextMode = switch (current.repeatMode) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    await _backend!.setRepeatMode(nextMode);
  }

  Future<void> setVolume(double volume) async {
    if (_backend == null) return;
    await _backend!.setVolume(volume);
  }

  Future<void> setMuted(bool muted) async {
    if (_backend == null) return;
    await _backend!.setMuted(muted);
  }

  Future<void> toggleMute() async {
    if (_backend == null) return;
    final current = state.value;
    await _backend!.setMuted(!(current?.isMuted ?? false));
  }

  void clearError() {
    _backend?.clearError();
  }

  Future<void> playNext(rust.Track track) async {
    if (_backend == null) return;
    unawaited(requestNotificationPermission());
    await _backend!.playNext(track);
  }

  Future<void> addToQueue(rust.Track track) async {
    if (_backend == null) return;
    unawaited(requestNotificationPermission());
    await _backend!.addToQueue(track);
  }

  Future<void> addAllToQueue(List<rust.Track> tracks) async {
    if (_backend == null) return;
    unawaited(requestNotificationPermission());
    await _backend!.addAllToQueue(tracks);
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (_backend == null) return;
    await _backend!.reorderQueue(oldIndex, newIndex);
  }

  Future<void> removeFromQueue(int index) async {
    if (_backend == null) return;
    await _backend!.removeFromQueue(index);
  }
}
