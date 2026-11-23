import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:sonea/playback/sonea_audio_handler.dart';
import 'package:sonea/playback/playback_backend.dart';
import 'package:sonea/playback/queue_manager.dart';
import 'package:sonea/src/rust/api/library.dart' as rust;

class JustAudioBackend implements PlaybackBackend {
  JustAudioBackend._(this._handler);

  final SoneaAudioHandler _handler;

  static Future<JustAudioBackend> init({required String dbPath}) async {
    final handler = await AudioService.init(
      builder: () => SoneaAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.sonea.app.playback',
        androidNotificationChannelName: 'Sonea Playback Controls',
        androidNotificationIcon: 'drawable/ic_stat_sonea',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
    handler.setDbPath(dbPath);
    return JustAudioBackend._(handler);
  }

  @override
  Stream<PlaybackStateData> get playbackStateStream => _handler.stateStream;

  @override
  PlaybackStateData get currentState => _handler.currentState;

  @override
  Future<void> setQueue(
    List<rust.Track> tracks, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool playImmediately = true,
    bool? shuffle,
    bool pickRandomStart = false,
  }) async {
    await _handler.setQueue(
      tracks,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
      playImmediately: playImmediately,
      shuffle: shuffle,
      pickRandomStart: pickRandomStart,
    );
  }

  @override
  Future<void> play() => _handler.play();

  @override
  Future<void> pause() => _handler.pause();

  @override
  Future<void> seek(Duration position) => _handler.seek(position);

  @override
  Future<void> next() => _handler.next();

  @override
  Future<void> previous() => _handler.previous();

  @override
  Future<void> jumpToIndex(int index) => _handler.jumpToIndex(index);

  @override
  Future<void> playNext(rust.Track track) => _handler.playNextTrack(track);

  @override
  Future<void> addToQueue(rust.Track track) => _handler.addToQueueTrack(track);

  @override
  Future<void> addAllToQueue(List<rust.Track> tracks) =>
      _handler.addAllToQueue(tracks);

  @override
  Future<void> reorderQueue(int oldIndex, int newIndex) =>
      _handler.reorderQueue(oldIndex, newIndex);

  @override
  Future<void> removeFromQueue(int index) => _handler.removeFromQueue(index);

  @override
  Future<void> setShuffleMode(bool enabled) =>
      _handler.setQueueShuffleMode(enabled);

  @override
  Future<void> setRepeatMode(RepeatMode mode) =>
      _handler.setQueueRepeatMode(mode);

  @override
  Future<void> setVolume(double volume) => _handler.setVolume(volume);

  @override
  Future<void> setMuted(bool muted) => _handler.setMuted(muted);

  @override
  Future<void> setReplayGainMultiplier(double multiplier) =>
      _handler.setReplayGainMultiplier(multiplier);

  @override
  Future<void> setPlaybackSpeed(double speed) =>
      _handler.setPlaybackSpeed(speed);

  @override
  void setAudioBehavior({bool? pauseOnNoisy, bool? duckOnInterruption}) =>
      _handler.setAudioBehavior(
        pauseOnNoisy: pauseOnNoisy,
        duckOnInterruption: duckOnInterruption,
      );

  @override
  void clearError() => _handler.clearError();

  @override
  Future<void> dispose() => _handler.dispose();
}
