import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:sonea/core/app_logger.dart';
import 'package:sonea/playback/playback_backend.dart';
import 'package:sonea/playback/queue_manager.dart';
import 'package:sonea/playback/widget_payload.dart';
import 'package:sonea/src/rust/api/library.dart' as rust;

const _widgetBridgeChannel = MethodChannel('com.sonea.app/widgets');

class SoneaAudioHandler extends BaseAudioHandler with SeekHandler {
  SoneaAudioHandler() {
    _init();
  }

  final AudioPlayer _player = AudioPlayer();
  final QueueManager _queueManager = QueueManager();
  final _stateController = StreamController<PlaybackStateData>.broadcast();

  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _noisySubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _bufferedSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<int?>? _currentIndexSubscription;
  StreamSubscription<PlaybackEvent>? _playbackEventSubscription;

  double _userVolume = 1.0;
  double _replayGainMultiplier = 1.0;
  bool _isMuted = false;
  bool _ducked = false;
  bool _pauseOnNoisy = true;
  bool _duckOnInterruption = true;
  bool _playOnInterruptionEnd = false;
  bool _recordedPlayForCurrentTrack = false;
  bool _isSyncingQueue = false;
  String? _dbPath;
  String? _lastBackgroundWidgetFingerprint;

  PlaybackStateData _currentState = const PlaybackStateData();

  PlaybackStateData get currentState => _currentState;
  Stream<PlaybackStateData> get stateStream => _stateController.stream;

  void setDbPath(String dbPath) {
    _dbPath = dbPath;
  }

  void setAudioBehavior({bool? pauseOnNoisy, bool? duckOnInterruption}) {
    if (pauseOnNoisy != null) _pauseOnNoisy = pauseOnNoisy;
    if (duckOnInterruption != null) _duckOnInterruption = duckOnInterruption;
  }

  Future<void> setPlaybackSpeed(double speed) async {
    try {
      await _player.setSpeed(speed.clamp(0.75, 2.0));
    } catch (e) {
      appLog('SoneaAudioHandler', 'setPlaybackSpeed failed: $e');
    }
  }

  Future<void> _init() async {
    await _initAudioSession();

    _playerStateSubscription = _player.playerStateStream.listen((playerState) {
      final loading = playerState.processingState == ProcessingState.loading ||
          playerState.processingState == ProcessingState.buffering;
      _updateState(isLoading: loading);
      _updateAudioServicePlaybackState();
    });

    _positionSubscription = _player.positionStream.listen((position) {
      _updateState(position: position);
      _checkPlayStats(position);
    });

    _bufferedSubscription = _player.bufferedPositionStream.listen((buffered) {
      _updateState(bufferedPosition: buffered);
    });

    _durationSubscription = _player.durationStream.listen((duration) {
      if (duration != null) {
        _updateState(duration: duration);
      }
    });

    _currentIndexSubscription = _player.currentIndexStream.listen((index) {
      if (_isSyncingQueue) return;
      if (index != null &&
          index >= 0 &&
          index < _queueManager.effectiveQueue.length) {
        _queueManager.jumpToIndex(index);
        _recordedPlayForCurrentTrack = false;
        final track = _queueManager.currentTrack;
        if (track != null) {
          mediaItem.add(_trackToMediaItem(track));
        }
        _updateState(
          currentTrack: track,
          currentIndex: index,
          duration: track?.durationMs != null
              ? Duration(milliseconds: track!.durationMs!.toInt())
              : Duration.zero,
          clearError: true,
        );
      }
    });

    _playbackEventSubscription = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object error, StackTrace st) {
        appLog('SoneaAudioHandler', 'Playback stream error: $error\n$st');
        _reportError(_formatPlayerError(error));
      },
    );
  }

  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      _interruptionSubscription =
          session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              if (_duckOnInterruption) {
                _ducked = true;
                unawaited(_applyEffectiveVolume());
              } else if (_player.playing) {
                _playOnInterruptionEnd = true;
                unawaited(pause());
              }
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              if (_player.playing) {
                _playOnInterruptionEnd = true;
                unawaited(pause());
              }
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              if (_ducked) {
                _ducked = false;
                unawaited(_applyEffectiveVolume());
              }
              if (_playOnInterruptionEnd) {
                _playOnInterruptionEnd = false;
                unawaited(play());
              }
              break;
            case AudioInterruptionType.pause:
              if (_playOnInterruptionEnd) {
                _playOnInterruptionEnd = false;
                unawaited(play());
              }
              break;
            case AudioInterruptionType.unknown:
              _playOnInterruptionEnd = false;
              break;
          }
        }
      });

      _noisySubscription = session.becomingNoisyEventStream.listen((_) {
        if (_pauseOnNoisy) {
          unawaited(pause());
        }
      });
    } catch (e, st) {
      appLog('SoneaAudioHandler', 'AudioSession init failed: $e\n$st');
    }
  }

  Future<void> _applyEffectiveVolume() async {
    final duckFactor = _ducked ? 0.25 : 1.0;
    final effective = _isMuted
        ? 0.0
        : (_userVolume * _replayGainMultiplier * duckFactor).clamp(0.0, 1.0);
    try {
      await _player.setVolume(effective);
    } catch (e) {
      appLog('SoneaAudioHandler', 'setVolume failed: $e');
    }
  }

  void _checkPlayStats(Duration position) {
    final track = _queueManager.currentTrack;
    if (track == null || _recordedPlayForCurrentTrack || _dbPath == null) {
      return;
    }

    final durationMs = track.durationMs?.toInt() ?? 0;
    final posMs = position.inMilliseconds;
    final thresholdMs = durationMs > 0
        ? (30000 < (durationMs ~/ 2) ? 30000 : (durationMs ~/ 2))
        : 30000;

    if (posMs >= thresholdMs) {
      _recordedPlayForCurrentTrack = true;
      unawaited(
        rust.recordPlay(dbPath: _dbPath!, trackId: track.id).catchError((e) {
          appLog('SoneaAudioHandler', 'recordPlay failed: $e');
        }),
      );
    }
  }

  String _formatPlayerError(Object error) {
    if (error is PlayerException) {
      return 'Playback error (${error.code}): ${error.message ?? 'Unable to decode audio file'}';
    }
    if (error is PlayerInterruptedException) {
      return 'Playback interrupted: ${error.message ?? 'connection aborted'}';
    }
    return 'Playback error: $error';
  }

  void _reportError(String message) {
    _updateState(errorMessage: message, isLoading: false);
  }

  void clearError() {
    if (_currentState.errorMessage != null) {
      _updateState(clearError: true);
    }
  }

  void _updateState({
    rust.Track? currentTrack,
    bool clearCurrentTrack = false,
    Duration? position,
    Duration? duration,
    Duration? bufferedPosition,
    int? currentIndex,
    bool? isLoading,
    String? errorMessage,
    bool clearError = false,
  }) {
    if (_stateController.isClosed) return;
    _currentState = _currentState.copyWith(
      currentTrack: clearCurrentTrack
          ? null
          : (currentTrack ?? _queueManager.currentTrack),
      clearCurrentTrack: clearCurrentTrack,
      queue: _queueManager.effectiveQueue,
      currentIndex: currentIndex ?? _queueManager.currentIndex,
      isPlaying: _player.playing,
      isLoading: isLoading ?? _currentState.isLoading,
      position: position ?? _player.position,
      duration: duration ?? _player.duration ?? _currentState.duration,
      bufferedPosition: bufferedPosition ?? _player.bufferedPosition,
      isShuffleEnabled: _queueManager.isShuffleEnabled,
      repeatMode: _queueManager.repeatMode,
      volume: _userVolume,
      isMuted: _isMuted,
      errorMessage: errorMessage,
      clearError: clearError,
    );
    _stateController.add(_currentState);
    _pushBackgroundWidgetUpdateIfNeeded(_currentState);
  }

  /// Pushes track/play/pause/shuffle/queue updates directly from the background
  /// AudioService lifecycle so Android home-screen widgets always stay live
  /// even when MainActivity is destroyed or the screen is turned off.
  void _pushBackgroundWidgetUpdateIfNeeded(PlaybackStateData snapshot) {
    if (!Platform.isAndroid) return;
    final fp = WidgetSyncPayload.computePlaybackFingerprint(snapshot);
    if (fp == _lastBackgroundWidgetFingerprint) return;
    _lastBackgroundWidgetFingerprint = fp;
    unawaited(
      _widgetBridgeChannel
          .invokeMethod<void>(
            'syncPlaybackState',
            WidgetSyncPayload.buildPlaybackOnlyMap(snapshot),
          )
          .catchError((Object _) {
        // Ignored in unit tests or before widget bridge attaches.
      }),
    );
  }

  void _updateAudioServicePlaybackState() {
    final playing = _player.playing;
    final processingState = _player.processingState;

    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: const {
              ProcessingState.idle: AudioProcessingState.idle,
              ProcessingState.loading: AudioProcessingState.loading,
              ProcessingState.buffering: AudioProcessingState.buffering,
              ProcessingState.ready: AudioProcessingState.ready,
              ProcessingState.completed: AudioProcessingState.completed,
            }[processingState] ??
            AudioProcessingState.idle,
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _queueManager.currentIndex,
        shuffleMode: _queueManager.isShuffleEnabled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        repeatMode: switch (_queueManager.repeatMode) {
          RepeatMode.off => AudioServiceRepeatMode.none,
          RepeatMode.all => AudioServiceRepeatMode.all,
          RepeatMode.one => AudioServiceRepeatMode.one,
        },
      ),
    );
  }

  MediaItem _trackToMediaItem(rust.Track track) {
    Uri? artUri;
    final rawCover = track.coverPath?.trim();
    if (rawCover != null && rawCover.isNotEmpty) {
      try {
        final f = File(rawCover);
        if (f.existsSync() && f.lengthSync() > 0) {
          artUri = Uri.file(f.path);
        }
      } catch (e) {
        appLog('SoneaAudioHandler', 'cover file stat failed', e);
      }
    }
    return MediaItem(
      id: track.id.toString(),
      title: track.title.trim().isNotEmpty ? track.title : 'Unknown Track',
      artist: (track.artist != null && track.artist!.trim().isNotEmpty)
          ? track.artist
          : 'Unknown Artist',
      album: (track.album != null && track.album!.trim().isNotEmpty)
          ? track.album
          : 'Unknown Album',
      duration: track.durationMs != null
          ? Duration(milliseconds: track.durationMs!.toInt())
          : null,
      artUri: artUri,
    );
  }

  AudioSource _trackToAudioSource(rust.Track track) {
    return AudioSource.uri(
      Uri.file(track.path),
      tag: _trackToMediaItem(track),
    );
  }

  Future<bool> _validateTrackFile(rust.Track track) async {
    final trimmed = track.path.trim();
    if (trimmed.isEmpty) return false;
    try {
      return await File(trimmed).exists();
    } catch (_) {
      return false;
    }
  }

  Future<void> setQueue(
    List<rust.Track> tracks, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool playImmediately = true,
    bool? shuffle,
    bool pickRandomStart = false,
  }) async {
    final validTracks =
        tracks.where((t) => t.path.trim().isNotEmpty).toList(growable: false);

    _recordedPlayForCurrentTrack = false;
    _queueManager.setQueue(
      validTracks,
      initialIndex: initialIndex,
      shuffle: shuffle,
      pickRandomStart: pickRandomStart,
    );

    final effective = _queueManager.effectiveQueue;
    if (effective.isEmpty) {
      await _player.stop();
      queue.add(const []);
      _updateState(
        clearCurrentTrack: true,
        currentIndex: 0,
        position: Duration.zero,
        duration: Duration.zero,
        isLoading: false,
      );
      return;
    }

    final targetTrack = _queueManager.currentTrack;
    if (targetTrack != null && !await _validateTrackFile(targetTrack)) {
      _reportError('Audio file not found: ${targetTrack.title}');
    }

    final audioSources =
        effective.map(_trackToAudioSource).toList(growable: false);
    queue.add(effective.map(_trackToMediaItem).toList(growable: false));

    _isSyncingQueue = true;
    try {
      _updateState(isLoading: true, clearError: true);
      await _player.setAudioSources(
        audioSources,
        initialIndex: _queueManager.currentIndex,
        initialPosition: initialPosition,
      );
      await _applyEffectiveVolume();

      final current = _queueManager.currentTrack;
      if (current != null) {
        mediaItem.add(_trackToMediaItem(current));
      }

      if (playImmediately) {
        await play();
      } else {
        await pause();
      }
      _updateAudioServicePlaybackState();
      _updateState(isLoading: false);
    } catch (e, st) {
      appLog('SoneaAudioHandler', 'setQueue failed: $e\n$st');
      _reportError(_formatPlayerError(e));
    } finally {
      _isSyncingQueue = false;
    }
  }

  @override
  Future<void> play() async {
    _playOnInterruptionEnd = false;
    try {
      await _applyEffectiveVolume();
      await _player.play();
    } catch (e, st) {
      appLog('SoneaAudioHandler', 'play failed: $e\n$st');
      _reportError(_formatPlayerError(e));
    }
  }

  @override
  Future<void> pause() async {
    _playOnInterruptionEnd = false;
    try {
      await _player.pause();
    } catch (e, st) {
      appLog('SoneaAudioHandler', 'pause failed: $e\n$st');
    }
  }

  @override
  Future<void> seek(Duration position) async {
    final total = _player.duration ?? _currentState.duration;
    final clamped = position < Duration.zero
        ? Duration.zero
        : (total > Duration.zero && position > total ? total : position);
    try {
      await _player.seek(clamped);
    } catch (e, st) {
      appLog('SoneaAudioHandler', 'seek failed: $e\n$st');
      _reportError(_formatPlayerError(e));
    }
  }

  Future<void> playNextTrack(rust.Track track) async {
    if (track.path.trim().isEmpty) return;
    if (_queueManager.effectiveQueue.isEmpty) {
      await setQueue([track], initialIndex: 0, playImmediately: true);
      return;
    }

    final insertIdx = (_queueManager.currentIndex + 1)
        .clamp(0, _queueManager.effectiveQueue.length);
    _queueManager.playNext(track);
    try {
      await _player.insertAudioSource(insertIdx, _trackToAudioSource(track));
    } catch (e, st) {
      appLog('SoneaAudioHandler', 'insertAudioSource failed: $e\n$st');
      await _resyncPlayerPreservingPlayback();
    }
    queue.add(_queueManager.effectiveQueue.map(_trackToMediaItem).toList());
    _updateAudioServicePlaybackState();
    _updateState();
  }

  Future<void> addToQueueTrack(rust.Track track) async {
    if (track.path.trim().isEmpty) return;
    if (_queueManager.effectiveQueue.isEmpty) {
      await setQueue([track], initialIndex: 0, playImmediately: true);
      return;
    }

    _queueManager.addToQueue(track);
    try {
      await _player.addAudioSource(_trackToAudioSource(track));
    } catch (e, st) {
      appLog('SoneaAudioHandler', 'addAudioSource failed: $e\n$st');
      await _resyncPlayerPreservingPlayback();
    }
    queue.add(_queueManager.effectiveQueue.map(_trackToMediaItem).toList());
    _updateAudioServicePlaybackState();
    _updateState();
  }

  Future<void> addAllToQueue(List<rust.Track> tracks) async {
    final valid =
        tracks.where((t) => t.path.trim().isNotEmpty).toList(growable: false);
    if (valid.isEmpty) return;
    if (_queueManager.effectiveQueue.isEmpty) {
      await setQueue(valid, initialIndex: 0, playImmediately: true);
      return;
    }

    _queueManager.addAllToQueue(valid);
    try {
      await _player.addAudioSources(
        valid.map(_trackToAudioSource).toList(growable: false),
      );
    } catch (e, st) {
      appLog('SoneaAudioHandler', 'addAudioSources failed: $e\n$st');
      await _resyncPlayerPreservingPlayback();
    }
    queue.add(_queueManager.effectiveQueue.map(_trackToMediaItem).toList());
    _updateAudioServicePlaybackState();
    _updateState();
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    final length = _queueManager.effectiveQueue.length;
    if (oldIndex < 0 || oldIndex >= length || newIndex < 0 || newIndex >= length) {
      return;
    }
    if (oldIndex == newIndex) return;

    _queueManager.reorderQueue(oldIndex, newIndex);
    _isSyncingQueue = true;
    try {
      await _player.moveAudioSource(oldIndex, newIndex);
    } catch (e, st) {
      appLog('SoneaAudioHandler', 'moveAudioSource failed: $e\n$st');
      await _resyncPlayerPreservingPlayback();
    } finally {
      _isSyncingQueue = false;
    }
    queue.add(_queueManager.effectiveQueue.map(_trackToMediaItem).toList());
    _updateAudioServicePlaybackState();
    _updateState();
  }

  Future<void> removeFromQueue(int index) async {
    final length = _queueManager.effectiveQueue.length;
    if (index < 0 || index >= length) return;

    final wasRemovingCurrent = index == _queueManager.currentIndex;
    _queueManager.removeFromQueue(index);

    if (_queueManager.effectiveQueue.isEmpty) {
      await _player.stop();
      queue.add(const []);
      _updateAudioServicePlaybackState();
      _updateState(
        clearCurrentTrack: true,
        currentIndex: 0,
        position: Duration.zero,
        duration: Duration.zero,
      );
      return;
    }

    _isSyncingQueue = true;
    try {
      await _player.removeAudioSourceAt(index);
      if (wasRemovingCurrent) {
        _recordedPlayForCurrentTrack = false;
        final nextTrack = _queueManager.currentTrack;
        if (nextTrack != null) {
          mediaItem.add(_trackToMediaItem(nextTrack));
        }
      }
    } catch (e, st) {
      appLog('SoneaAudioHandler', 'removeAudioSourceAt failed: $e\n$st');
      await _resyncPlayerPreservingPlayback();
    } finally {
      _isSyncingQueue = false;
    }

    queue.add(_queueManager.effectiveQueue.map(_trackToMediaItem).toList());
    _updateAudioServicePlaybackState();
    _updateState();
  }

  Future<void> _resyncPlayerPreservingPlayback() async {
    final effective = _queueManager.effectiveQueue;
    if (effective.isEmpty) return;

    final wasPlaying = _player.playing;
    final currentPos = _player.position;
    final targetIdx = _queueManager.currentIndex;
    final sources = effective.map(_trackToAudioSource).toList(growable: false);

    _isSyncingQueue = true;
    try {
      await _player.setAudioSources(
        sources,
        initialIndex: targetIdx,
        initialPosition: currentPos,
      );
      await _applyEffectiveVolume();
      if (wasPlaying) {
        await _player.play();
      }
    } catch (e, st) {
      appLog('SoneaAudioHandler', 'resync failed: $e\n$st');
      _reportError(_formatPlayerError(e));
    } finally {
      _isSyncingQueue = false;
    }
  }

  @override
  Future<void> skipToNext() async {
    await next();
  }

  @override
  Future<void> skipToPrevious() async {
    await previous();
  }

  Future<void> next() async {
    final nextIdx = _queueManager.getNextIndex();
    if (nextIdx == null) return;
    _recordedPlayForCurrentTrack = false;
    _queueManager.jumpToIndex(nextIdx);
    try {
      await _player.seek(Duration.zero, index: nextIdx);
      if (!_player.playing) {
        await _player.play();
      }
    } catch (e, st) {
      appLog('SoneaAudioHandler', 'next failed: $e\n$st');
      _reportError(_formatPlayerError(e));
    }
  }

  Future<void> previous() async {
    if (_player.position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }
    final prevIdx = _queueManager.getPreviousIndex();
    if (prevIdx == null) {
      await seek(Duration.zero);
      return;
    }
    _recordedPlayForCurrentTrack = false;
    _queueManager.jumpToIndex(prevIdx);
    try {
      await _player.seek(Duration.zero, index: prevIdx);
      if (!_player.playing) {
        await _player.play();
      }
    } catch (e, st) {
      appLog('SoneaAudioHandler', 'previous failed: $e\n$st');
      _reportError(_formatPlayerError(e));
    }
  }

  Future<void> jumpToIndex(int index) async {
    if (!_queueManager.jumpToIndex(index)) return;
    _recordedPlayForCurrentTrack = false;
    try {
      await _player.seek(Duration.zero, index: index);
      if (!_player.playing) {
        await _player.play();
      }
    } catch (e, st) {
      appLog('SoneaAudioHandler', 'jumpToIndex failed: $e\n$st');
      _reportError(_formatPlayerError(e));
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode == AudioServiceShuffleMode.all ||
        shuffleMode == AudioServiceShuffleMode.group;
    await setQueueShuffleMode(enabled);
  }

  Future<void> setQueueShuffleMode(bool enabled) async {
    if (_queueManager.isShuffleEnabled == enabled) return;
    _queueManager.setShuffleMode(enabled);

    final effective = _queueManager.effectiveQueue;
    if (effective.isEmpty) {
      _updateState();
      return;
    }

    await _resyncPlayerPreservingPlayback();
    queue.add(effective.map(_trackToMediaItem).toList());
    _updateAudioServicePlaybackState();
    _updateState();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    final mode = switch (repeatMode) {
      AudioServiceRepeatMode.none => RepeatMode.off,
      AudioServiceRepeatMode.one => RepeatMode.one,
      AudioServiceRepeatMode.all => RepeatMode.all,
      AudioServiceRepeatMode.group => RepeatMode.all,
    };
    await setQueueRepeatMode(mode);
  }

  Future<void> setQueueRepeatMode(RepeatMode mode) async {
    _queueManager.setRepeatMode(mode);
    final loopMode = switch (mode) {
      RepeatMode.off => LoopMode.off,
      RepeatMode.all => LoopMode.all,
      RepeatMode.one => LoopMode.one,
    };
    try {
      await _player.setLoopMode(loopMode);
    } catch (e) {
      appLog('SoneaAudioHandler', 'setLoopMode failed: $e');
    }
    _updateAudioServicePlaybackState();
    _updateState();
  }

  Future<void> setVolume(double volume) async {
    _userVolume = volume.clamp(0.0, 1.0);
    if (_userVolume > 0 && _isMuted) {
      _isMuted = false;
    }
    await _applyEffectiveVolume();
    _updateState();
  }

  Future<void> setMuted(bool muted) async {
    if (_isMuted == muted) return;
    _isMuted = muted;
    await _applyEffectiveVolume();
    _updateState();
  }

  Future<void> setReplayGainMultiplier(double multiplier) async {
    _replayGainMultiplier = multiplier.clamp(0.05, 2.0);
    await _applyEffectiveVolume();
  }

  Future<void> dispose() async {
    await _interruptionSubscription?.cancel();
    await _noisySubscription?.cancel();
    await _playerStateSubscription?.cancel();
    await _positionSubscription?.cancel();
    await _bufferedSubscription?.cancel();
    await _durationSubscription?.cancel();
    await _currentIndexSubscription?.cancel();
    await _playbackEventSubscription?.cancel();
    await _player.dispose();
    await _stateController.close();
  }
}
