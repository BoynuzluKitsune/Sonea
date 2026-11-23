import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/playback/playback_controller.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/ui/components/artwork_thumbnail.dart';
import 'package:sonea/ui/now_playing/now_playing_screen.dart';

class FloatingMiniPlayer extends ConsumerWidget {
  const FloatingMiniPlayer({super.key});

  void _openNowPlaying(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const NowPlayingScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final tween = Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(
      playbackControllerProvider.select((s) => s.value?.currentTrack),
    );
    final hasQueue = ref.watch(
      playbackControllerProvider.select((s) => s.value?.queue.isNotEmpty ?? false),
    );
    final isPlaying = ref.watch(
      playbackControllerProvider.select((s) => s.value?.isPlaying ?? false),
    );
    final isLoading = ref.watch(
      playbackControllerProvider.select((s) => s.value?.isLoading ?? false),
    );
    final controller = ref.read(playbackControllerProvider.notifier);
    final strings = ref.watch(stringsProvider);
    final tokens = SoneaThemeTokens.of(context);

    if (track == null && !hasQueue) {
      return const SizedBox.shrink();
    }

    final title = track?.title ?? strings.noTrackSelected;
    final artist = (track?.artist != null && track!.artist!.isNotEmpty)
        ? track.artist!
        : strings.unknownArtist;
    final radius = tokens.radiusMd;

    return GestureDetector(
      onTap: () => _openNowPlaying(context),
      onVerticalDragUpdate: (details) {
        if (details.primaryDelta != null && details.primaryDelta! < -8) {
          _openNowPlaying(context);
        }
      },
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity;
        if (velocity == null) return;
        if (velocity < -200) {
          controller.next();
        } else if (velocity > 200) {
          controller.previous();
        }
      },
      child: RepaintBoundary(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: tokens.surfaceColor,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: tokens.borderColor.withValues(alpha: 0.7),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black
                    .withValues(alpha: tokens.isLight ? 0.06 : 0.16),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const RepaintBoundary(child: _MiniPlayerProgressLine()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    ArtworkThumbnail(
                      coverPath: track?.coverPath,
                      size: 44,
                      tokens: tokens,
                      radius: tokens.radiusSm,
                      cacheWidth: 96,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              letterSpacing: -0.1,
                              color: tokens.textColor,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: tokens.subtextColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 22,
                        icon: Icon(
                          Icons.skip_previous_rounded,
                          color: tokens.textColor,
                        ),
                        onPressed: controller.previous,
                        tooltip: strings.tooltipPrevious,
                      ),
                    ),
                    SizedBox(
                      width: 38,
                      height: 38,
                      child: isLoading
                          ? Padding(
                              padding: const EdgeInsets.all(9),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: tokens.accentColor,
                              ),
                            )
                          : IconButton(
                              padding: EdgeInsets.zero,
                              iconSize: 26,
                              icon: Icon(
                                isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                color: tokens.accentColor,
                              ),
                              onPressed: controller.togglePlayPause,
                              tooltip: isPlaying
                                  ? strings.tooltipPause
                                  : strings.tooltipPlay,
                            ),
                    ),
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 22,
                        icon: Icon(
                          Icons.skip_next_rounded,
                          color: tokens.textColor,
                        ),
                        onPressed: controller.next,
                        tooltip: strings.tooltipNext,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

class _MiniPlayerProgressLine extends ConsumerWidget {
  const _MiniPlayerProgressLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final posMs = ref.watch(
      playbackControllerProvider
          .select((s) => s.value?.position.inMilliseconds ?? 0),
    );
    final durMs = ref.watch(
      playbackControllerProvider
          .select((s) => s.value?.duration.inMilliseconds ?? 0),
    );
    final tokens = SoneaThemeTokens.of(context);
    final progress = (durMs > 0 ? posMs / durMs : 0.0).clamp(0.0, 1.0);

    return LinearProgressIndicator(
      value: progress,
      minHeight: 2,
      backgroundColor: tokens.borderColor.withValues(alpha: 0.4),
      valueColor: AlwaysStoppedAnimation<Color>(tokens.accentColor),
    );
  }
}
