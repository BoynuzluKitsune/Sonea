import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' hide RepeatMode;
import 'package:sonea/core/app_logger.dart';
import 'package:sonea/core/app_paths.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/library/library_controller.dart' show libraryProvider;
import 'package:sonea/playback/playback_controller.dart';
import 'package:sonea/playback/queue_manager.dart';
import 'package:sonea/playback/sleep_timer_controller.dart';
import 'package:sonea/src/rust/api/library.dart' as rust_lib;
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/ui/components/artwork_thumbnail.dart';
import 'package:sonea/ui/components/equalizer_dialog.dart';
import 'package:sonea/ui/components/waveform_seekbar.dart';
import 'package:sonea/ui/library/metadata_editor_dialog.dart';
import 'package:sonea/ui/now_playing/synced_lyrics_view.dart';

class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

const int _kMaxGlowCacheEntries = 32;
final Map<String, Color> _glowColorCache = {};

Future<Color?> _extractDominantColor(String path) async {
  if (_glowColorCache.containsKey(path)) {
    return _glowColorCache[path];
  }
  ui.Codec? codec;
  ui.Image? image;
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 24,
      targetHeight: 24,
    );
    final frame = await codec.getNextFrame();
    image = frame.image;
    final byteData =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return null;

    Color bestColor = Colors.transparent;
    double maxSat = -1.0;

    for (int i = 0; i < byteData.lengthInBytes; i += 4) {
      final r = byteData.getUint8(i);
      final g = byteData.getUint8(i + 1);
      final b = byteData.getUint8(i + 2);

      final hsv = HSVColor.fromColor(Color.fromARGB(255, r, g, b));
      if (hsv.value > 0.20 && hsv.saturation > maxSat) {
        maxSat = hsv.saturation;
        final boostedSat = hsv.saturation.clamp(0.45, 0.85);
        final boostedVal = hsv.value.clamp(0.45, 0.78);
        bestColor =
            HSVColor.fromAHSV(1.0, hsv.hue, boostedSat, boostedVal).toColor();
      }
    }

    if (maxSat <= 0.05) {
      bestColor = Colors.transparent;
    }

    if (_glowColorCache.length >= _kMaxGlowCacheEntries) {
      _glowColorCache.remove(_glowColorCache.keys.first);
    }
    _glowColorCache[path] = bestColor;
    return bestColor;
  } catch (e) {
    appLog('NowPlaying', 'dominant color extraction failed', e);
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  int _topTab = 0; // 0 = Cover, 1 = Lyrics
  bool _isFavorite = false;
  int? _lastCheckedTrackId;
  String? _lastCoverPath;
  Color? _dynamicGlowColor;

  Future<void> _checkFavorite(int trackId) async {
    if (_lastCheckedTrackId == trackId) return;
    _lastCheckedTrackId = trackId;
    try {
      final dbPath = await AppPaths.databasePath();
      final isFav = await rust_lib.isFavorite(dbPath: dbPath, trackId: trackId);
      if (mounted && _lastCheckedTrackId == trackId) {
        setState(() => _isFavorite = isFav);
      }
    } catch (e) {
      appLog('NowPlaying', '_checkFavorite failed', e);
    }
  }

  Future<void> _toggleFavorite(int trackId) async {
    try {
      final dbPath = await AppPaths.databasePath();
      final isFav =
          await rust_lib.toggleFavorite(dbPath: dbPath, trackId: trackId);
      if (mounted) setState(() => _isFavorite = isFav);
    } catch (e) {
      appLog('NowPlaying', '_toggleFavorite failed', e);
    }
  }

  void _showSleepTimerDialog(BuildContext context, AppStrings strings) {
    final timerController = ref.read(sleepTimerControllerProvider.notifier);
    final timerState = ref.read(sleepTimerControllerProvider);

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.sleepTimerTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mins in const [15, 30, 45, 60])
              ListTile(
                title: Text(strings.sleepMinutes(mins)),
                onTap: () {
                  timerController.startTimer(mins);
                  Navigator.pop(context);
                },
              ),
            ListTile(
              title: Text(strings.sleepEndOfTrack),
              onTap: () {
                timerController.setEndOfTrack();
                Navigator.pop(context);
              },
            ),
            if (timerState.isActive)
              ListTile(
                title: Text(
                  strings.cancelTimer,
                  style: const TextStyle(color: Colors.redAccent),
                ),
                onTap: () {
                  timerController.cancelTimer();
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showTrackInfoDialog(
    BuildContext context,
    rust_lib.Track track,
    AppStrings strings,
    SoneaThemeTokens tokens,
  ) {
    final durationStr = track.durationMs != null && track.durationMs! > 0
        ? '${track.durationMs! ~/ 60000}:${((track.durationMs! ~/ 1000) % 60).toString().padLeft(2, '0')}'
        : '-';
    final rows = <(String, String)>[
      (strings.fieldTitle, track.title),
      (
        strings.fieldArtist,
        track.artist?.isNotEmpty == true ? track.artist! : strings.unknownArtist,
      ),
      (
        strings.fieldAlbum,
        track.album?.isNotEmpty == true ? track.album! : strings.unknownAlbum,
      ),
      if (track.year != null) (strings.infoYear, '${track.year}'),
      (strings.infoDuration, durationStr),
      if (track.format != null && track.format!.isNotEmpty)
        (strings.infoFormat, track.format!),
      if (track.sampleRate != null && track.sampleRate! > 0)
        (
          strings.infoSampleRate,
          '${(track.sampleRate! / 1000).toStringAsFixed(1)} kHz',
        ),
      if (track.bitDepth != null && track.bitDepth! > 0)
        (strings.infoBitDepth, '${track.bitDepth}-bit'),
      if (track.bitrate != null && track.bitrate! > 0)
        (strings.infoBitrate, '${track.bitrate} kbps'),
      if (track.replaygainTrackGain != null)
        (
          strings.infoReplayGain,
          '${track.replaygainTrackGain!.toStringAsFixed(2)} dB',
        ),
      (strings.infoPath, track.path),
    ];

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.menuTrackInfo),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: tokens.subtextColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        value,
                        style: TextStyle(
                          fontSize: 13,
                          color: tokens.textColor,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(strings.close),
          ),
        ],
      ),
    );
  }

  void _showQueueSheet(BuildContext parentContext, AppStrings strings) {
    if (!parentContext.mounted) return;
    final tokens = SoneaThemeTokens.of(parentContext);

    showModalBottomSheet<void>(
      context: parentContext,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Consumer(
          builder: (context, sheetRef, _) {
            final queue = sheetRef.watch(
              playbackControllerProvider
                  .select((s) => s.value?.queue ?? const <rust_lib.Track>[]),
            );
            final currentIdx = sheetRef.watch(
              playbackControllerProvider
                  .select((s) => s.value?.currentIndex ?? 0),
            );
            final controller = sheetRef.read(playbackControllerProvider.notifier);

            return SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            '${strings.menuQueue} (${queue.length})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.displayStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: tokens.textColor,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 20),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (queue.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text(
                            strings.noTrackSelected,
                            style: TextStyle(color: tokens.subtextColor),
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        height: 360,
                        child: ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          itemCount: queue.length,
                          onReorderItem: (oldIndex, newIndex) {
                            final target =
                                newIndex > oldIndex ? newIndex - 1 : newIndex;
                            controller.reorderQueue(oldIndex, target);
                          },
                          itemBuilder: (context, index) {
                            final item = queue[index];
                            final isCurrent = index == currentIdx;

                            return Container(
                              key: ValueKey('queue_item_${item.id}_$index'),
                              margin: const EdgeInsets.only(bottom: 4),
                              decoration: BoxDecoration(
                                color: isCurrent
                                    ? tokens.accentColor.withValues(alpha: 0.12)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: ListTile(
                                dense: true,
                                contentPadding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                onTap: () => controller.skipTo(index),
                                leading: Icon(
                                  isCurrent
                                      ? Icons.play_arrow_rounded
                                      : Icons.music_note_rounded,
                                  color: isCurrent
                                      ? tokens.accentColor
                                      : tokens.subtextColor,
                                ),
                                title: Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isCurrent
                                        ? tokens.accentColor
                                        : tokens.textColor,
                                    fontWeight: isCurrent
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                    fontSize: 14,
                                  ),
                                ),
                                subtitle: Text(
                                  item.artist?.isNotEmpty == true
                                      ? item.artist!
                                      : strings.unknownArtist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: tokens.subtextColor,
                                    fontSize: 12,
                                  ),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: Icon(
                                        Icons.close_rounded,
                                        size: 18,
                                        color: tokens.subtextColor,
                                      ),
                                      onPressed: () =>
                                          controller.removeFromQueue(index),
                                    ),
                                    ReorderableDragStartListener(
                                      index: index,
                                      child: Padding(
                                        padding: const EdgeInsets.all(6),
                                        child: Icon(
                                          Icons.drag_handle_rounded,
                                          size: 20,
                                          color: tokens.subtextColor,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showMoreMenu(
    BuildContext parentContext,
    AppStrings strings,
    SoneaThemeTokens tokens,
  ) {
    if (!parentContext.mounted) return;
    final timerState = ref.read(sleepTimerControllerProvider);

    showModalBottomSheet<void>(
      context: parentContext,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(tokens.radiusLg),
        ),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.queue_music_rounded),
                  title: Text(strings.menuQueue),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (mounted) _showQueueSheet(context, strings);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.graphic_eq_rounded),
                  title: Text(strings.equalizerTitle),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (!mounted) return;
                    showDialog<void>(
                      context: context,
                      builder: (dialogContext) => const EqualizerDialog(),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.access_time_rounded),
                  title: Text(strings.menuSleepTimer),
                  trailing: timerState.isActive
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: tokens.accentColor,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            timerState.isEndOfTrack
                                ? '♪'
                                : '${(timerState.remainingSeconds ?? 0) ~/ 60}m',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              fontFeatures: kTabularFigures,
                              color: tokens.onAccentColor,
                            ),
                          ),
                        )
                      : null,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (mounted) _showSleepTimerDialog(context, strings);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.edit_note_rounded),
                  title: Text(strings.editMetadataTitle),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    if (!mounted) return;
                    final track =
                        ref.read(playbackControllerProvider).value?.currentTrack;
                    if (track != null) {
                      final updated = await showDialog<rust_lib.Track>(
                        context: context,
                        builder: (dialogContext) =>
                            MetadataEditorDialog(track: track),
                      );
                      if (updated != null && mounted) {
                        ref.invalidate(libraryProvider);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(strings.metadataUpdated)),
                        );
                      }
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: Text(strings.menuTrackInfo),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (!mounted) return;
                    final track =
                        ref.read(playbackControllerProvider).value?.currentTrack;
                    if (track != null) {
                      _showTrackInfoDialog(context, track, strings, tokens);
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(
      playbackControllerProvider.select((s) => s.value?.currentTrack),
    );
    final isPlaying = ref.watch(
      playbackControllerProvider.select((s) => s.value?.isPlaying ?? false),
    );
    final isLoading = ref.watch(
      playbackControllerProvider.select((s) => s.value?.isLoading ?? false),
    );
    final isShuffleEnabled = ref.watch(
      playbackControllerProvider
          .select((s) => s.value?.isShuffleEnabled ?? false),
    );
    final repeatMode = ref.watch(
      playbackControllerProvider
          .select((s) => s.value?.repeatMode ?? RepeatMode.off),
    );
    final volume = ref.watch(
      playbackControllerProvider.select((s) => s.value?.volume ?? 1.0),
    );
    final isMuted = ref.watch(
      playbackControllerProvider.select((s) => s.value?.isMuted ?? false),
    );
    final errorMessage = ref.watch(
      playbackControllerProvider.select((s) => s.value?.errorMessage),
    );

    final controller = ref.read(playbackControllerProvider.notifier);
    final strings = ref.watch(stringsProvider);
    final tokens = SoneaThemeTokens.of(context);

    final title = track?.title ?? strings.noTrackSelected;
    final artist = (track?.artist != null && track!.artist!.isNotEmpty)
        ? track.artist!
        : strings.unknownArtist;
    final album = (track?.album != null && track!.album!.isNotEmpty)
        ? track.album!
        : strings.unknownAlbum;
    final coverPath = track?.coverPath;

    if (track != null) {
      unawaited(_checkFavorite(track.id.toInt()));
    }

    if (coverPath != null &&
        coverPath.isNotEmpty &&
        coverPath != _lastCoverPath &&
        tokens.useDynamicCoverGlow) {
      _lastCoverPath = coverPath;
      _extractDominantColor(coverPath).then((color) {
        if (mounted && _lastCoverPath == coverPath) {
          setState(() => _dynamicGlowColor = color);
        }
      });
    } else if ((coverPath == null || coverPath.isEmpty) &&
        _lastCoverPath != null) {
      _lastCoverPath = null;
      _dynamicGlowColor = null;
    }

    final hasGlow = tokens.useDynamicCoverGlow &&
        _dynamicGlowColor != null &&
        _dynamicGlowColor != Colors.transparent;
    final glowColor = hasGlow ? _dynamicGlowColor! : tokens.accentColor;

    final formatInfo = [
      if (track?.format != null && track!.format!.isNotEmpty) track.format,
      if (track?.sampleRate != null && track!.sampleRate! > 0)
        '${(track.sampleRate! / 1000).toStringAsFixed(1)} kHz',
      if (track?.bitDepth != null && track!.bitDepth! > 0)
        '${track.bitDepth}-bit',
    ].join(' • ');

    return Container(
      color: tokens.backgroundColor,
      child: Stack(
        children: [
          if (hasGlow)
            Positioned.fill(
              child: RepaintBoundary(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0.0, -0.35),
                      radius: 1.15,
                      colors: [
                        glowColor.withValues(
                          alpha: tokens.isLight ? 0.18 : 0.28,
                        ),
                        tokens.backgroundColor.withValues(alpha: 0.92),
                        tokens.backgroundColor,
                      ],
                      stops: const [0.0, 0.6, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(
                children: [
                  _buildTopBar(context, strings, tokens),
                  if (errorMessage != null)
                    _buildErrorBanner(errorMessage, controller, tokens),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final isLandscape =
                            constraints.maxWidth > constraints.maxHeight &&
                                constraints.maxWidth >= 560;
                        if (isLandscape) {
                          return _buildLandscapeBody(
                            constraints: constraints,
                            coverPath: coverPath,
                            title: title,
                            artist: artist,
                            album: album,
                            formatInfo: formatInfo,
                            track: track,
                            isPlaying: isPlaying,
                            isLoading: isLoading,
                            isShuffleEnabled: isShuffleEnabled,
                            repeatMode: repeatMode,
                            volume: volume,
                            isMuted: isMuted,
                            controller: controller,
                            strings: strings,
                            tokens: tokens,
                          );
                        }
                        return _buildPortraitBody(
                          constraints: constraints,
                          coverPath: coverPath,
                          title: title,
                          artist: artist,
                          album: album,
                          formatInfo: formatInfo,
                          track: track,
                          isPlaying: isPlaying,
                          isLoading: isLoading,
                          isShuffleEnabled: isShuffleEnabled,
                          repeatMode: repeatMode,
                          volume: volume,
                          isMuted: isMuted,
                          controller: controller,
                          strings: strings,
                          tokens: tokens,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(
    BuildContext context,
    AppStrings strings,
    SoneaThemeTokens tokens,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 28,
              color: tokens.textColor,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Container(
                decoration: BoxDecoration(
                  color: tokens.surfaceColor,
                  borderRadius: BorderRadius.circular(tokens.radiusPill),
                  border: Border.all(
                    color: tokens.borderColor.withValues(alpha: 0.6),
                  ),
                ),
                padding: const EdgeInsets.all(3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTabPill(
                      label: strings.coverTab,
                      selected: _topTab == 0,
                      tokens: tokens,
                      onTap: () => setState(() => _topTab = 0),
                    ),
                    _buildTabPill(
                      label: strings.lyricsTab,
                      selected: _topTab == 1,
                      tokens: tokens,
                      onTap: () => setState(() => _topTab = 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.queue_music_rounded, color: tokens.textColor),
            onPressed: () => _showQueueSheet(context, strings),
            tooltip: strings.menuQueue,
          ),
        ],
      ),
    );
  }

  Widget _buildTabPill({
    required String label,
    required bool selected,
    required SoneaThemeTokens tokens,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? tokens.accentColor : Colors.transparent,
          borderRadius: BorderRadius.circular(tokens.radiusPill),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? tokens.onAccentColor : tokens.subtextColor,
          ),
        ),
      ),
    );
  }

  Widget _buildErrorBanner(
    String message,
    PlaybackController controller,
    SoneaThemeTokens tokens,
  ) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: tokens.textColor),
            ),
          ),
          IconButton(
            constraints: const BoxConstraints(),
            padding: EdgeInsets.zero,
            icon: Icon(Icons.close_rounded, size: 16, color: tokens.subtextColor),
            onPressed: controller.clearError,
          ),
        ],
      ),
    );
  }

  Widget _buildArtworkOrLyrics({
    required double artworkSize,
    required String? coverPath,
    required bool isPlaying,
    required SoneaThemeTokens tokens,
  }) {
    if (_topTab == 1) {
      return const SyncedLyricsView();
    }
    return Center(
      child: AnimatedScale(
        scale: isPlaying ? 1.0 : 0.95,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: ArtworkThumbnail(
          coverPath: coverPath,
          size: artworkSize,
          tokens: tokens,
          radius: tokens.radiusLg,
          cacheWidth: 720,
        ),
      ),
    );
  }

  Widget _buildPortraitBody({
    required BoxConstraints constraints,
    required String? coverPath,
    required String title,
    required String artist,
    required String album,
    required String formatInfo,
    required rust_lib.Track? track,
    required bool isPlaying,
    required bool isLoading,
    required bool isShuffleEnabled,
    required RepeatMode repeatMode,
    required double volume,
    required bool isMuted,
    required PlaybackController controller,
    required AppStrings strings,
    required SoneaThemeTokens tokens,
  }) {
    final artworkSize = math
        .min(constraints.maxWidth - 64, constraints.maxHeight * 0.42)
        .clamp(120.0, 300.0);

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: _buildArtworkOrLyrics(
              artworkSize: artworkSize,
              coverPath: coverPath,
              isPlaying: isPlaying,
              tokens: tokens,
            ),
          ),
        ),
        _buildTrackMetaRow(
          title: title,
          artist: artist,
          album: album,
          track: track,
          strings: strings,
          tokens: tokens,
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          child: RepaintBoundary(child: IsolatedSeekBar()),
        ),
        _buildTransportRow(
          isPlaying: isPlaying,
          isLoading: isLoading,
          isShuffleEnabled: isShuffleEnabled,
          repeatMode: repeatMode,
          controller: controller,
          strings: strings,
          tokens: tokens,
        ),
        _buildVolumeRow(
          volume: volume,
          isMuted: isMuted,
          controller: controller,
          strings: strings,
          tokens: tokens,
        ),
        if (formatInfo.isNotEmpty && tokens.showFormatBadges)
          _buildFormatBadge(formatInfo, tokens),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildLandscapeBody({
    required BoxConstraints constraints,
    required String? coverPath,
    required String title,
    required String artist,
    required String album,
    required String formatInfo,
    required rust_lib.Track? track,
    required bool isPlaying,
    required bool isLoading,
    required bool isShuffleEnabled,
    required RepeatMode repeatMode,
    required double volume,
    required bool isMuted,
    required PlaybackController controller,
    required AppStrings strings,
    required SoneaThemeTokens tokens,
  }) {
    final artworkSize = math
        .min(constraints.maxWidth * 0.36, constraints.maxHeight - 32)
        .clamp(140.0, 260.0);

    return Row(
      children: [
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _buildArtworkOrLyrics(
              artworkSize: artworkSize,
              coverPath: coverPath,
              isPlaying: isPlaying,
              tokens: tokens,
            ),
          ),
        ),
        Expanded(
          flex: 6,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildTrackMetaRow(
                  title: title,
                  artist: artist,
                  album: album,
                  track: track,
                  strings: strings,
                  tokens: tokens,
                ),
                const SizedBox(height: 4),
                const RepaintBoundary(child: IsolatedSeekBar()),
                _buildTransportRow(
                  isPlaying: isPlaying,
                  isLoading: isLoading,
                  isShuffleEnabled: isShuffleEnabled,
                  repeatMode: repeatMode,
                  controller: controller,
                  strings: strings,
                  tokens: tokens,
                ),
                _buildVolumeRow(
                  volume: volume,
                  isMuted: isMuted,
                  controller: controller,
                  strings: strings,
                  tokens: tokens,
                ),
                if (formatInfo.isNotEmpty && tokens.showFormatBadges)
                  _buildFormatBadge(formatInfo, tokens),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTrackMetaRow({
    required String title,
    required String artist,
    required String album,
    required rust_lib.Track? track,
    required AppStrings strings,
    required SoneaThemeTokens tokens,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                MarqueeTitleText(
                  text: title,
                  style: tokens.displayStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: tokens.textColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$artist • $album',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: tokens.subtextColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              _isFavorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              color: _isFavorite ? tokens.accentColor : tokens.subtextColor,
            ),
            onPressed: track != null
                ? () => _toggleFavorite(track.id.toInt())
                : null,
            tooltip: strings.tooltipFavorite,
          ),
          IconButton(
            icon: Icon(Icons.more_vert_rounded, color: tokens.textColor),
            onPressed: () => _showMoreMenu(context, strings, tokens),
            tooltip: strings.tooltipMore,
          ),
        ],
      ),
    );
  }

  Widget _buildTransportRow({
    required bool isPlaying,
    required bool isLoading,
    required bool isShuffleEnabled,
    required RepeatMode repeatMode,
    required PlaybackController controller,
    required AppStrings strings,
    required SoneaThemeTokens tokens,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: Icon(
              Icons.shuffle_rounded,
              color: isShuffleEnabled
                  ? tokens.accentColor
                  : tokens.subtextColor.withValues(alpha: 0.55),
            ),
            onPressed: controller.toggleShuffle,
            tooltip: strings.tooltipShuffle,
          ),
          IconButton(
            icon: Icon(
              Icons.skip_previous_rounded,
              size: 34,
              color: tokens.textColor,
            ),
            onPressed: controller.previous,
            tooltip: strings.tooltipPrevious,
          ),
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tokens.accentColor,
            ),
            child: isLoading
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: tokens.onAccentColor,
                    ),
                  )
                : IconButton(
                    iconSize: 34,
                    icon: Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: tokens.onAccentColor,
                    ),
                    onPressed: controller.togglePlayPause,
                    tooltip:
                        isPlaying ? strings.tooltipPause : strings.tooltipPlay,
                  ),
          ),
          IconButton(
            icon: Icon(
              Icons.skip_next_rounded,
              size: 34,
              color: tokens.textColor,
            ),
            onPressed: controller.next,
            tooltip: strings.tooltipNext,
          ),
          IconButton(
            icon: Icon(
              repeatMode == RepeatMode.one
                  ? Icons.repeat_one_rounded
                  : Icons.repeat_rounded,
              color: repeatMode != RepeatMode.off
                  ? tokens.accentColor
                  : tokens.subtextColor.withValues(alpha: 0.55),
            ),
            onPressed: controller.toggleRepeat,
            tooltip: strings.tooltipRepeat,
          ),
        ],
      ),
    );
  }

  Widget _buildVolumeRow({
    required double volume,
    required bool isMuted,
    required PlaybackController controller,
    required AppStrings strings,
    required SoneaThemeTokens tokens,
  }) {
    final effectiveDisplay = isMuted ? 0.0 : volume;
    final volumeIcon = isMuted || effectiveDisplay == 0
        ? Icons.volume_off_rounded
        : (effectiveDisplay < 0.5
            ? Icons.volume_down_rounded
            : Icons.volume_up_rounded);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
      child: Row(
        children: [
          IconButton(
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              volumeIcon,
              color: isMuted ? tokens.accentColor : tokens.subtextColor,
            ),
            onPressed: controller.toggleMute,
            tooltip: isMuted ? strings.tooltipUnmute : strings.tooltipMute,
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: tokens.accentColor.withValues(alpha: 0.85),
                inactiveTrackColor:
                    tokens.subtextColor.withValues(alpha: 0.22),
                thumbColor: tokens.accentColor,
              ),
              child: Slider(
                value: effectiveDisplay.clamp(0.0, 1.0),
                min: 0.0,
                max: 1.0,
                onChanged: controller.setVolume,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormatBadge(String formatInfo, SoneaThemeTokens tokens) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: tokens.surfaceColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: tokens.borderColor.withValues(alpha: 0.6),
          ),
        ),
        child: Text(
          formatInfo,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            fontFeatures: kTabularFigures,
            color: tokens.subtextColor,
          ),
        ),
      ),
    );
  }
}

class MarqueeTitleText extends StatefulWidget {
  const MarqueeTitleText({
    super.key,
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  @override
  State<MarqueeTitleText> createState() => _MarqueeTitleTextState();
}

class _MarqueeTitleTextState extends State<MarqueeTitleText>
    with SingleTickerProviderStateMixin {
  late ScrollController _scrollController;
  int _marqueeGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startMarquee());
  }

  @override
  void didUpdateWidget(covariant MarqueeTitleText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _marqueeGeneration++;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _startMarquee());
    }
  }

  Future<void> _startMarquee() async {
    final gen = ++_marqueeGeneration;
    if (!mounted || !_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll > 0) {
      await Future<void>.delayed(const Duration(seconds: 2));
      while (mounted && gen == _marqueeGeneration && _scrollController.hasClients) {
        final currentMax = _scrollController.position.maxScrollExtent;
        if (currentMax <= 0) break;
        await _scrollController.animateTo(
          currentMax,
          duration: Duration(
            milliseconds: (currentMax * 40).toInt().clamp(2000, 10000),
          ),
          curve: Curves.linear,
        );
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!mounted || gen != _marqueeGeneration || !_scrollController.hasClients) {
          break;
        }
        await _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeOut,
        );
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  @override
  void dispose() {
    _marqueeGeneration++;
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final painter = TextPainter(
            text: TextSpan(text: widget.text, style: widget.style),
            maxLines: 1,
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();

          final overflows = painter.width > constraints.maxWidth;
          if (!overflows) {
            return Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: widget.style,
            );
          }

          return ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => const LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                Colors.white,
                Colors.white,
                Colors.transparent,
              ],
              stops: [0.0, 0.88, 1.0],
            ).createShader(bounds),
            child: SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.only(right: 20),
                child: Text(
                  widget.text,
                  maxLines: 1,
                  softWrap: false,
                  style: widget.style,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
