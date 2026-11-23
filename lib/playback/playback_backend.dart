import 'package:sonea/playback/queue_manager.dart';
import 'package:sonea/src/rust/api/library.dart';

class PlaybackStateData {
  const PlaybackStateData({
    this.currentTrack,
    this.queue = const [],
    this.currentIndex = 0,
    this.isPlaying = false,
    this.isLoading = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.isShuffleEnabled = false,
    this.repeatMode = RepeatMode.off,
    this.volume = 1.0,
    this.isMuted = false,
    this.errorMessage,
  });

  final Track? currentTrack;
  final List<Track> queue;
  final int currentIndex;
  final bool isPlaying;
  final bool isLoading;
  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;
  final bool isShuffleEnabled;
  final RepeatMode repeatMode;

  /// User-facing volume in [0.0, 1.0], independent of ReplayGain and ducking.
  final double volume;
  final bool isMuted;
  final String? errorMessage;

  PlaybackStateData copyWith({
    Track? currentTrack,
    bool clearCurrentTrack = false,
    List<Track>? queue,
    int? currentIndex,
    bool? isPlaying,
    bool? isLoading,
    Duration? position,
    Duration? duration,
    Duration? bufferedPosition,
    bool? isShuffleEnabled,
    RepeatMode? repeatMode,
    double? volume,
    bool? isMuted,
    String? errorMessage,
    bool clearError = false,
  }) =>
      PlaybackStateData(
        currentTrack:
            clearCurrentTrack ? null : currentTrack ?? this.currentTrack,
        queue: queue ?? this.queue,
        currentIndex: currentIndex ?? this.currentIndex,
        isPlaying: isPlaying ?? this.isPlaying,
        isLoading: isLoading ?? this.isLoading,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        bufferedPosition: bufferedPosition ?? this.bufferedPosition,
        isShuffleEnabled: isShuffleEnabled ?? this.isShuffleEnabled,
        repeatMode: repeatMode ?? this.repeatMode,
        volume: volume ?? this.volume,
        isMuted: isMuted ?? this.isMuted,
        errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      );
}

abstract class PlaybackBackend {
  Stream<PlaybackStateData> get playbackStateStream;
  PlaybackStateData get currentState;

  Future<void> setQueue(
    List<Track> tracks, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool playImmediately = true,
    bool? shuffle,
    bool pickRandomStart = false,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> next();
  Future<void> previous();
  Future<void> jumpToIndex(int index);
  Future<void> playNext(Track track);
  Future<void> addToQueue(Track track);
  Future<void> addAllToQueue(List<Track> tracks);
  Future<void> reorderQueue(int oldIndex, int newIndex);
  Future<void> removeFromQueue(int index);
  Future<void> setShuffleMode(bool enabled);
  Future<void> setRepeatMode(RepeatMode mode);
  Future<void> setVolume(double volume);
  Future<void> setMuted(bool muted);
  Future<void> setReplayGainMultiplier(double multiplier);
  Future<void> setPlaybackSpeed(double speed);
  void setAudioBehavior({bool? pauseOnNoisy, bool? duckOnInterruption});
  void clearError();
  Future<void> dispose();
}
