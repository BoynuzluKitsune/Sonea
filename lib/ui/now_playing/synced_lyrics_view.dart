import 'dart:async';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/playback/lyrics_controller.dart';
import 'package:sonea/playback/playback_controller.dart';
import 'package:sonea/settings/app_settings_controller.dart';
import 'package:sonea/src/rust/api/library.dart' as rust_lib;
import 'package:sonea/src/rust/api/lyrics.dart' as rust_lyrics;
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/ui/components/sonea_logo_mark.dart';
import 'package:sonea/ui/library/metadata_editor_dialog.dart';
import 'package:sonea/ui/now_playing/lyrics_search_sheet.dart';

final RegExp _kInlineWordTimestampRe =
    RegExp(r'<\d{1,3}:\d{2}(?:[.,]\d{1,3})?>');

/// Strips enhanced-LRC inline word timestamps (`<mm:ss.xx>`) cleanly so raw
/// angle-bracket timestamps never leak into rendered karaoke lines.
String stripEnhancedLrcTags(String text) {
  if (!text.contains('<')) return text;
  return text
      .replaceAll(_kInlineWordTimestampRe, ' ')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
}

/// Computes the active lyric line index for [positionMs] using binary search.
///
/// Adds [lookaheadMs] (+120ms default) for audio latency compensation.
/// When [lines] is non-empty and playback hasn't reached the first timestamp
/// yet (e.g. during an intro at 0:00), returns `0` so the opening line is
/// immediately highlighted and kept centered without requiring user input.
int findActiveLyricIndex(
  List<rust_lyrics.LyricLine> lines,
  int positionMs, {
  int lookaheadMs = 120,
}) {
  if (lines.isEmpty) return -1;
  final target = positionMs + lookaheadMs;
  if (target < lines.first.timeMs) return 0;

  int low = 0;
  int high = lines.length - 1;
  int result = 0;
  while (low <= high) {
    final mid = (low + high) >> 1;
    if (lines[mid].timeMs <= target) {
      result = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return result;
}

class SyncedLyricsView extends ConsumerStatefulWidget {
  const SyncedLyricsView({super.key});

  @override
  ConsumerState<SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

class _SyncedLyricsViewState extends ConsumerState<SyncedLyricsView> {
  final ScrollController _scrollController = ScrollController();

  int? _lastTrackId;
  int _lastScrolledIndex = -1;
  bool _userScrolling = false;
  Timer? _userScrollResumeTimer;

  @override
  void dispose() {
    _userScrollResumeTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _resetForNewTrack(int? trackId) {
    if (_lastTrackId == trackId) return;
    _lastTrackId = trackId;
    _lastScrolledIndex = -1;
    _userScrolling = false;
    _userScrollResumeTimer?.cancel();
  }

  void _onUserScrollStart() {
    _userScrolling = true;
    _userScrollResumeTimer?.cancel();
    _userScrollResumeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        _userScrolling = false;
      }
    });
  }

  /// Scrolls smoothly to [index] purely via [ScrollController] without dynamic
  /// [GlobalKey] maps, preventing InheritedElement `_dependents.isEmpty` crashes.
  void _scheduleScrollToActive(
    int index,
    int totalLines, {
    required double viewportHeight,
    required bool hasSubLines,
    bool force = false,
  }) {
    if (index < 0 || totalLines <= 0) return;
    if (!force && (_userScrolling || index == _lastScrolledIndex)) return;

    final animate = _lastScrolledIndex != -1;
    _lastScrolledIndex = index;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (!force && _userScrolling) return;

      final position = _scrollController.position;
      final maxExtent = position.maxScrollExtent;
      if (maxExtent <= 0) return;

      final estimatedRowExtent = hasSubLines ? 68.0 : 46.0;
      const topPadding = 72.0;
      final targetOffset =
          (topPadding + (index * estimatedRowExtent) - (viewportHeight * 0.36))
              .clamp(0.0, maxExtent);

      if ((position.pixels - targetOffset).abs() < 2.0) return;

      _scrollController.animateTo(
        targetOffset,
        duration: animate
            ? const Duration(milliseconds: 260)
            : const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _showLatinHint(BuildContext context, AppStrings strings) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(strings.alreadyLatin),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _openManualSearch(
    rust_lib.Track track,
    AppStrings strings, {
    int initialTab = 0,
  }) async {
    if (!mounted) return;
    final applied = await showLyricsSearchSheet(
      context,
      track: track,
      initialTab: initialTab,
    );
    if (applied && mounted) {
      _lastScrolledIndex = -1;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(strings.searchLyricsApplied),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lyricsState = ref.watch(lyricsControllerProvider);
    final lyricsController = ref.read(lyricsControllerProvider.notifier);
    final controller = ref.read(playbackControllerProvider.notifier);
    final strings = ref.watch(stringsProvider);
    final tokens = SoneaThemeTokens.of(context);

    final currentTrack = ref.watch(
      playbackControllerProvider.select((s) => s.value?.currentTrack),
    );
    final currentTrackId = currentTrack?.id.toInt();

    if (_lastTrackId != currentTrackId) {
      _resetForNewTrack(currentTrackId);
    }

    if (lyricsState.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final lyrics = lyricsState.lyrics;
    if (lyrics != null && lyrics.isInstrumental) {
      return Center(
        key: const Key('lyrics_instrumental_view'),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: tokens.accentColor.withValues(alpha: 0.14),
                  border: Border.all(
                    color: tokens.accentColor.withValues(alpha: 0.35),
                  ),
                ),
                child: Icon(
                  Icons.piano_rounded,
                  size: 36,
                  color: tokens.accentColor,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                strings.instrumentalTrackTitle,
                textAlign: TextAlign.center,
                style: tokens.displayStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: tokens.textColor,
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  strings.instrumentalTrackSubtitle,
                  textAlign: TextAlign.center,
                  style: tokens.bodyStyle(
                    fontSize: 13.5,
                    height: 1.5,
                    color: tokens.subtextColor,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _buildSourcePill(
                label:
                    '${strings.instrumentalBadge} • ${strings.lyricsSourceLabel(lyrics.source)}',
                tokens: tokens,
              ),
              if (currentTrack != null) ...[
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('lyrics_instrumental_search_btn'),
                      onPressed: () =>
                          unawaited(_openManualSearch(currentTrack, strings)),
                      icon: const Icon(Icons.manage_search_rounded, size: 17),
                      label: Text(strings.searchLyricsAnyway),
                    ),
                    OutlinedButton.icon(
                      key: const Key('lyrics_instrumental_paste_btn'),
                      onPressed: () => unawaited(
                        _openManualSearch(
                          currentTrack,
                          strings,
                          initialTab: 1,
                        ),
                      ),
                      icon: const Icon(Icons.content_paste_rounded, size: 16),
                      label: Text(strings.pasteLyricsShort),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (lyrics == null ||
        (lyrics.lines.isEmpty && (lyrics.plainText?.isEmpty ?? true))) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SoneaLogoMark(
              size: 48,
              upperColor: tokens.textColor.withValues(alpha: 0.65),
              lowerColor: tokens.accentColor.withValues(alpha: 0.85),
            ),
            const SizedBox(height: 12),
            Text(
              strings.noLyricsSaved,
              style: TextStyle(color: tokens.subtextColor, fontSize: 15),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: const Key('lyrics_retry_empty_btn'),
                  onPressed: lyricsController.refreshLyrics,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(strings.retryLyrics),
                ),
                if (currentTrack != null)
                  FilledButton.tonalIcon(
                    key: const Key('lyrics_search_empty_btn'),
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          tokens.accentColor.withValues(alpha: 0.16),
                      foregroundColor: tokens.accentColor,
                    ),
                    onPressed: () =>
                        unawaited(_openManualSearch(currentTrack, strings)),
                    icon: const Icon(Icons.manage_search_rounded, size: 18),
                    label: Text(strings.searchLyrics),
                  ),
                if (currentTrack != null)
                  OutlinedButton.icon(
                    key: const Key('lyrics_paste_empty_btn'),
                    onPressed: () => unawaited(
                      _openManualSearch(
                        currentTrack,
                        strings,
                        initialTab: 1,
                      ),
                    ),
                    icon: const Icon(Icons.content_paste_rounded, size: 17),
                    label: Text(strings.pasteLyricsAction),
                  ),
                if (currentTrack != null)
                  OutlinedButton.icon(
                    onPressed: () {
                      if (!mounted) return;
                      showDialog<void>(
                        context: this.context,
                        builder: (dialogContext) =>
                            MetadataEditorDialog(track: currentTrack),
                      );
                    },
                    icon: const Icon(Icons.edit_note_rounded, size: 18),
                    label: Text(strings.editMetadataTitle),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    final mode = lyricsState.mode;
    final lines = lyrics.lines;

    if (!lyrics.isSynced || lines.isEmpty) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _buildSourcePill(
                  label:
                      '${strings.lyricsSourceLabel(lyrics.source)} • ${strings.lyricsPlainBadge}',
                  tokens: tokens,
                ),
                _buildRetryHeaderBtn(
                  strings: strings,
                  tokens: tokens,
                  onTap: lyricsController.refreshLyrics,
                ),
                if (currentTrack != null)
                  _buildSearchHeaderBtn(
                    track: currentTrack,
                    strings: strings,
                    tokens: tokens,
                  ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Text(
                lyrics.plainText ?? '',
                style: tokens.bodyStyle(
                  fontSize: 15.5,
                  height: 1.65,
                  color: tokens.textColor,
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Only rebuild this view when the active lyric line index actually changes.
    final activeIdx = ref.watch(
      playbackControllerProvider.select((s) {
        final posMs = s.value?.position.inMilliseconds ?? 0;
        return findActiveLyricIndex(lines, posMs);
      }),
    );

    final hasTransliteration = lines.any((l) => l.transliterated != null);
    final showSubLines = mode == TransliterationMode.under && hasTransliteration;

    return Column(
      children: [
        // Compact Transliteration Segmented Toggle + Source Badge + Retry + Manual Search
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: tokens.surfaceColor,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: tokens.borderColor.withValues(alpha: 0.6),
                  ),
                ),
                padding: const EdgeInsets.all(3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildModeBtn(
                      label: strings.modeOff,
                      tokens: tokens,
                      active: mode == TransliterationMode.off,
                      onTap: () =>
                          lyricsController.setMode(TransliterationMode.off),
                    ),
                    _buildModeBtn(
                      label: strings.modeUnder,
                      tokens: tokens,
                      active: mode == TransliterationMode.under,
                      onTap: () {
                        if (!hasTransliteration) {
                          _showLatinHint(context, strings);
                        }
                        lyricsController.setMode(TransliterationMode.under);
                      },
                    ),
                    _buildModeBtn(
                      label: strings.modeLatin,
                      tokens: tokens,
                      active: mode == TransliterationMode.latin,
                      onTap: () {
                        if (!hasTransliteration) {
                          _showLatinHint(context, strings);
                        }
                        lyricsController.setMode(TransliterationMode.latin);
                      },
                    ),
                  ],
                ),
              ),
              _buildSourcePill(
                label: strings.lyricsSourceLabel(lyrics.source),
                tokens: tokens,
              ),
              _buildRetryHeaderBtn(
                strings: strings,
                tokens: tokens,
                onTap: lyricsController.refreshLyrics,
              ),
              if (currentTrack != null)
                _buildSearchHeaderBtn(
                  track: currentTrack,
                  strings: strings,
                  tokens: tokens,
                ),
            ],
          ),
        ),

        // Synced Lines View — ScrollController-driven without GlobalKey maps.
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final appSettings = ref.watch(appSettingsProvider);
              final textAlign = appSettings.lyricsAlignment == LyricsAlignment.left
                  ? TextAlign.left
                  : TextAlign.center;
              final crossAlign = appSettings.lyricsAlignment == LyricsAlignment.left
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center;

              if (activeIdx >= 0 && appSettings.lyricsAutoScroll) {
                _scheduleScrollToActive(
                  activeIdx,
                  lines.length,
                  viewportHeight: constraints.maxHeight,
                  hasSubLines: showSubLines,
                );
              }

              return RepaintBoundary(
                child: NotificationListener<UserScrollNotification>(
                  onNotification: (notification) {
                    if (notification.direction != ScrollDirection.idle) {
                      _onUserScrollStart();
                    }
                    return false;
                  },
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 72,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: List.generate(lines.length, (index) {
                        final line = lines[index];
                        final isActive = index == activeIdx;
                        final isPast = activeIdx >= 0 && index < activeIdx;
                        final translit = line.transliterated != null
                            ? stripEnhancedLrcTags(line.transliterated!)
                            : null;

                        String mainText = stripEnhancedLrcTags(line.text);
                        String? subText;

                        if (mode == TransliterationMode.under &&
                            translit != null) {
                          subText = translit;
                        } else if (mode == TransliterationMode.latin &&
                            translit != null) {
                          mainText = translit;
                        }

                        final inactiveAlpha = isPast ? 0.40 : 0.66;

                        return RepaintBoundary(
                          key: ValueKey('lyric_${currentTrackId ?? 0}_$index'),
                          child: GestureDetector(
                            onTap: () {
                              _userScrolling = false;
                              _userScrollResumeTimer?.cancel();
                              controller.seek(
                                Duration(milliseconds: line.timeMs.toInt()),
                              );
                              _scheduleScrollToActive(
                                index,
                                lines.length,
                                viewportHeight: constraints.maxHeight,
                                hasSubLines: showSubLines,
                                force: true,
                              );
                            },
                            behavior: HitTestBehavior.opaque,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 9,
                                horizontal: 6,
                              ),
                              child: AnimatedScale(
                                scale: isActive ? 1.03 : 1.0,
                                alignment:
                                    appSettings.lyricsAlignment ==
                                            LyricsAlignment.left
                                        ? Alignment.centerLeft
                                        : Alignment.center,
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOutCubic,
                                child: Column(
                                  crossAxisAlignment: crossAlign,
                                  children: [
                                    Text(
                                      mainText,
                                      textAlign: textAlign,
                                      style: isActive
                                          ? tokens.displayStyle(
                                              fontSize: appSettings
                                                  .lyricsActiveFontSize,
                                              height: 1.35,
                                              fontWeight: FontWeight.w700,
                                              color: tokens.accentColor,
                                              fontFeatures: kTabularFigures,
                                            )
                                          : tokens.bodyStyle(
                                              fontSize: appSettings
                                                  .lyricsInactiveFontSize,
                                              height: 1.35,
                                              fontWeight: FontWeight.w400,
                                              color: tokens.subtextColor
                                                  .withValues(
                                                    alpha: inactiveAlpha,
                                                  ),
                                              fontFeatures: kTabularFigures,
                                            ),
                                    ),
                                    if (subText != null) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        subText,
                                        textAlign: textAlign,
                                        style: TextStyle(
                                          fontSize: isActive ? 14 : 12,
                                          fontWeight: isActive
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                          color: isActive
                                              ? tokens.accentColor
                                                  .withValues(alpha: 0.85)
                                              : tokens.subtextColor.withValues(
                                                  alpha: isPast ? 0.32 : 0.48,
                                                ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSourcePill({
    required String label,
    required SoneaThemeTokens tokens,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: tokens.surfaceColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: tokens.borderColor.withValues(alpha: 0.6),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: tokens.subtextColor,
        ),
      ),
    );
  }

  Widget _buildRetryHeaderBtn({
    required AppStrings strings,
    required SoneaThemeTokens tokens,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: const Key('lyrics_retry_header_btn'),
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5.5),
        decoration: BoxDecoration(
          color: tokens.surfaceColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: tokens.borderColor.withValues(alpha: 0.65),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.refresh_rounded,
              size: 14,
              color: tokens.subtextColor,
            ),
            const SizedBox(width: 4),
            Text(
              strings.retryLyrics,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: tokens.textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchHeaderBtn({
    required rust_lib.Track track,
    required AppStrings strings,
    required SoneaThemeTokens tokens,
  }) {
    return InkWell(
      key: const Key('lyrics_search_header_btn'),
      borderRadius: BorderRadius.circular(18),
      onTap: () => unawaited(_openManualSearch(track, strings)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5.5),
        decoration: BoxDecoration(
          color: tokens.surfaceColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: tokens.borderColor.withValues(alpha: 0.65),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.manage_search_rounded,
              size: 14,
              color: tokens.accentColor,
            ),
            const SizedBox(width: 4),
            Text(
              strings.searchLyricsShort,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: tokens.textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeBtn({
    required String label,
    required SoneaThemeTokens tokens,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? tokens.accentColor : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: active ? tokens.onAccentColor : tokens.subtextColor,
          ),
        ),
      ),
    );
  }
}
