import 'package:sonea/playback/playback_backend.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';

class WidgetQueueEntry {
  const WidgetQueueEntry({
    required this.queueIndex,
    required this.title,
    required this.artist,
  });

  final int queueIndex;
  final String title;
  final String artist;

  Map<String, Object> toMap() => {
        'index': queueIndex,
        'title': title,
        'artist': artist,
      };
}

class WidgetPlaylistShortcut {
  const WidgetPlaylistShortcut({
    required this.id,
    required this.name,
    required this.trackCount,
    this.coverPath,
  });

  final int id;
  final String name;
  final int trackCount;
  final String? coverPath;

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'trackCount': trackCount,
        'coverPath': coverPath,
      };
}

/// Immutable, fingerprintable data snapshot pushed to Android home-screen widgets
/// strictly on track, queue, playback-state, playlist, cover, or theme changes.
class WidgetSyncPayload {
  const WidgetSyncPayload({
    required this.title,
    required this.artist,
    required this.album,
    required this.format,
    required this.coverPath,
    required this.isPlaying,
    required this.isShuffleEnabled,
    required this.upNext,
    required this.playlists,
    required this.bgColor,
    required this.surfaceColor,
    required this.elevatedColor,
    required this.accentColor,
    required this.onAccentColor,
    required this.textColor,
    required this.subtextColor,
    required this.borderColor,
    required this.isLight,
  });

  final String title;
  final String artist;
  final String album;
  final String format;
  final String? coverPath;
  final bool isPlaying;
  final bool isShuffleEnabled;
  final List<WidgetQueueEntry> upNext;
  final List<WidgetPlaylistShortcut> playlists;

  final int bgColor;
  final int surfaceColor;
  final int elevatedColor;
  final int accentColor;
  final int onAccentColor;
  final int textColor;
  final int subtextColor;
  final int borderColor;
  final bool isLight;

  static Map<String, Object?> buildPlaybackOnlyMap(PlaybackStateData playback) {
    final track = playback.currentTrack;
    final title = (track != null && track.title.trim().isNotEmpty)
        ? track.title.trim()
        : 'Sonea';
    final artist = (track?.artist != null && track!.artist!.trim().isNotEmpty)
        ? track.artist!.trim()
        : 'Unknown Artist';
    final album = (track?.album != null && track!.album!.trim().isNotEmpty)
        ? track.album!.trim()
        : '';

    final rawFormat = track?.format?.trim() ?? '';
    final sampleRate = track?.sampleRate;
    final formatParts = <String>[
      if (rawFormat.isNotEmpty) rawFormat.toUpperCase(),
      if (sampleRate != null && sampleRate > 0)
        '${(sampleRate / 1000).toStringAsFixed(1)}kHz',
    ];

    final upNext = <WidgetQueueEntry>[];
    if (playback.queue.isNotEmpty) {
      final start = playback.currentIndex + 1;
      for (int i = start; i < playback.queue.length && upNext.length < 3; i++) {
        final item = playback.queue[i];
        upNext.add(WidgetQueueEntry(
          queueIndex: i,
          title: item.title.trim().isNotEmpty ? item.title.trim() : 'Track',
          artist: (item.artist != null && item.artist!.trim().isNotEmpty)
              ? item.artist!.trim()
              : 'Unknown Artist',
        ));
      }
    }

    final cleanCover = track?.coverPath?.trim();
    return {
      'title': title,
      'artist': artist,
      'album': album,
      'format': formatParts.join(' • '),
      'coverPath': (cleanCover != null && cleanCover.isNotEmpty)
          ? cleanCover
          : null,
      'isPlaying': playback.isPlaying,
      'isShuffleEnabled': playback.isShuffleEnabled,
      'upNext': upNext.map((e) => e.toMap()).toList(growable: false),
    };
  }

  static String computePlaybackFingerprint(PlaybackStateData playback) {
    final map = buildPlaybackOnlyMap(playback);
    return '${map['title']}|${map['artist']}|${map['format']}|'
        '${map['coverPath']}|${map['isPlaying']}|${map['isShuffleEnabled']}|'
        '${map['upNext']}';
  }

  factory WidgetSyncPayload.fromState({
    required PlaybackStateData playback,
    required SoneaThemeTokens theme,
    List<WidgetPlaylistShortcut> playlists = const [],
  }) {
    final track = playback.currentTrack;
    final title = (track != null && track.title.trim().isNotEmpty)
        ? track.title.trim()
        : 'Sonea';
    final artist = (track?.artist != null && track!.artist!.trim().isNotEmpty)
        ? track.artist!.trim()
        : 'Unknown Artist';
    final album = (track?.album != null && track!.album!.trim().isNotEmpty)
        ? track.album!.trim()
        : '';

    final rawFormat = track?.format?.trim() ?? '';
    final sampleRate = track?.sampleRate;
    final formatParts = <String>[
      if (rawFormat.isNotEmpty) rawFormat.toUpperCase(),
      if (sampleRate != null && sampleRate > 0)
        '${(sampleRate / 1000).toStringAsFixed(1)}kHz',
    ];

    final upNext = <WidgetQueueEntry>[];
    if (playback.queue.isNotEmpty) {
      final start = playback.currentIndex + 1;
      for (int i = start; i < playback.queue.length && upNext.length < 3; i++) {
        final item = playback.queue[i];
        upNext.add(WidgetQueueEntry(
          queueIndex: i,
          title: item.title.trim().isNotEmpty ? item.title.trim() : 'Track',
          artist: (item.artist != null && item.artist!.trim().isNotEmpty)
              ? item.artist!.trim()
              : 'Unknown Artist',
        ));
      }
    }

    final cleanCover = track?.coverPath?.trim();
    return WidgetSyncPayload(
      title: title,
      artist: artist,
      album: album,
      format: formatParts.join(' • '),
      coverPath: (cleanCover != null && cleanCover.isNotEmpty)
          ? cleanCover
          : null,
      isPlaying: playback.isPlaying,
      isShuffleEnabled: playback.isShuffleEnabled,
      upNext: upNext,
      playlists: playlists.take(3).toList(growable: false),
      bgColor: theme.backgroundColor.toARGB32(),
      surfaceColor: theme.surfaceColor.toARGB32(),
      elevatedColor: theme.elevatedSurfaceColor.toARGB32(),
      accentColor: theme.accentColor.toARGB32(),
      onAccentColor: theme.onAccentColor.toARGB32(),
      textColor: theme.textColor.toARGB32(),
      subtextColor: theme.subtextColor.toARGB32(),
      borderColor: theme.borderColor.toARGB32(),
      isLight: theme.isLight,
    );
  }

  /// Deterministic change fingerprint excluding position ticks.
  String computeFingerprint() {
    final upNextKey = upNext
        .map((e) => '${e.queueIndex}:${e.title}:${e.artist}')
        .join(';');
    final playlistKey = playlists
        .map((p) => '${p.id}:${p.name}:${p.trackCount}:${p.coverPath ?? ''}')
        .join(';');
    return '$title|$artist|$album|$format|$coverPath|$isPlaying|$isShuffleEnabled|'
        '$upNextKey|$playlistKey|$bgColor|$surfaceColor|$elevatedColor|'
        '$accentColor|$onAccentColor|$textColor|$subtextColor|$borderColor|$isLight';
  }

  Map<String, Object?> toMethodChannelMap() => {
        'title': title,
        'artist': artist,
        'album': album,
        'format': format,
        'coverPath': coverPath,
        'isPlaying': isPlaying,
        'isShuffleEnabled': isShuffleEnabled,
        'upNext': upNext.map((e) => e.toMap()).toList(growable: false),
        'playlists': playlists.map((p) => p.toMap()).toList(growable: false),
        'bgColor': bgColor,
        'surfaceColor': surfaceColor,
        'elevatedColor': elevatedColor,
        'accentColor': accentColor,
        'onAccentColor': onAccentColor,
        'textColor': textColor,
        'subtextColor': subtextColor,
        'borderColor': borderColor,
        'isLight': isLight,
      };
}
