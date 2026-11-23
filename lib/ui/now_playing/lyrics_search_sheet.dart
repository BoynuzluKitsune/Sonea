import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/core/app_logger.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/playback/lyrics_controller.dart';
import 'package:sonea/src/rust/api/library.dart' as rust_lib;
import 'package:sonea/src/rust/api/lyrics.dart' as rust_lyrics;
import 'package:sonea/theme/sonea_theme_tokens.dart';

/// Opens the Lyrics Search & Manual Paste modal sheet.
/// Pass [initialTab] = 1 to jump straight to the Paste / Edit Lyrics tab.
Future<bool> showLyricsSearchSheet(
  BuildContext context, {
  required rust_lib.Track track,
  int initialTab = 0,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => LyricsSearchSheet(
      track: track,
      initialTab: initialTab,
    ),
  );
  return result ?? false;
}

final RegExp _lrcTimestampPattern = RegExp(r'\[\d{1,3}:\d{2}(?:[.,]\d{1,3})?\]');

class LyricsSearchSheet extends ConsumerStatefulWidget {
  const LyricsSearchSheet({
    super.key,
    required this.track,
    this.initialTab = 0,
  });

  final rust_lib.Track track;
  final int initialTab;

  @override
  ConsumerState<LyricsSearchSheet> createState() => _LyricsSearchSheetState();
}

class _LyricsSearchSheetState extends ConsumerState<LyricsSearchSheet> {
  late final TextEditingController _queryController;
  late final TextEditingController _artistController;
  late final TextEditingController _pasteController;

  late int _activeTab; // 0 = Search Online, 1 = Paste / Edit Lyrics
  bool _isSearching = false;
  bool _isApplying = false;
  bool _hasSearched = false;
  String? _errorMessage;
  String? _pasteError;
  List<rust_lyrics.LyricsCandidateDto> _candidates = const [];

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab.clamp(0, 1);
    _queryController = TextEditingController(text: widget.track.title);
    _artistController = TextEditingController(text: widget.track.artist ?? '');

    final existing = ref.read(lyricsControllerProvider).lyrics;
    final prefillText = _buildEditableLyricsSeed(existing);
    _pasteController = TextEditingController(text: prefillText);

    if (_activeTab == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_runSearch());
        }
      });
    }
  }

  String _buildEditableLyricsSeed(rust_lyrics.LyricsResult? existing) {
    if (existing == null) return '';
    if (existing.isSynced && existing.lines.isNotEmpty) {
      final buf = StringBuffer();
      for (final line in existing.lines) {
        final ms = line.timeMs.toInt();
        final mins = (ms ~/ 60000).toString().padLeft(2, '0');
        final secs = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
        final cs = ((ms % 1000) ~/ 10).toString().padLeft(2, '0');
        buf.writeln('[$mins:$secs.$cs]${line.text}');
      }
      return buf.toString().trimRight();
    }
    return existing.plainText ?? '';
  }

  @override
  void dispose() {
    _queryController.dispose();
    _artistController.dispose();
    _pasteController.dispose();
    super.dispose();
  }

  String _formatDuration(int? secs) {
    if (secs == null || secs <= 0) return '';
    final m = secs ~/ 60;
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _runSearch() async {
    final query = _queryController.text.trim();
    if (query.isEmpty || _isSearching) return;
    final artist = _artistController.text.trim();
    final durMs = widget.track.durationMs?.toInt();
    final durSecs = (durMs != null && durMs > 0) ? (durMs ~/ 1000) : null;

    setState(() {
      _isSearching = true;
      _errorMessage = null;
    });

    try {
      final results =
          await ref.read(lyricsControllerProvider.notifier).searchCandidates(
                query: query,
                artist: artist.isEmpty ? null : artist,
                durationSecs: durSecs,
              );
      if (mounted) {
        setState(() {
          _candidates = results;
          _isSearching = false;
          _hasSearched = true;
        });
      }
    } catch (e, st) {
      appLog('LyricsSearchSheet', 'searchCandidates failed', e, st);
      if (mounted) {
        setState(() {
          _isSearching = false;
          _hasSearched = true;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _selectCandidate(
    rust_lyrics.LyricsCandidateDto candidate,
  ) async {
    if (_isApplying) return;
    setState(() => _isApplying = true);
    try {
      await ref.read(lyricsControllerProvider.notifier).applyCustomLyrics(
            trackId: widget.track.id.toInt(),
            syncedLrc: candidate.syncedLrc,
            plainLyrics: candidate.plainLyrics,
            source: candidate.source,
          );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e, st) {
      appLog('LyricsSearchSheet', 'applyCustomLyrics failed', e, st);
      if (mounted) {
        setState(() {
          _isApplying = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _savePastedLyrics(AppStrings strings) async {
    if (_isApplying) return;
    final raw = _pasteController.text.trim();
    if (raw.isEmpty) {
      setState(() => _pasteError = strings.pasteLyricsEmptyError);
      return;
    }

    setState(() {
      _isApplying = true;
      _pasteError = null;
    });

    final looksSynced = _lrcTimestampPattern.hasMatch(raw);
    try {
      await ref.read(lyricsControllerProvider.notifier).applyCustomLyrics(
            trackId: widget.track.id.toInt(),
            syncedLrc: looksSynced ? raw : null,
            plainLyrics: looksSynced ? null : raw,
            source: 'manual',
          );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e, st) {
      appLog('LyricsSearchSheet', 'savePastedLyrics failed', e, st);
      if (mounted) {
        setState(() {
          _isApplying = false;
          _pasteError = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final tokens = SoneaThemeTokens.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: FractionallySizedBox(
        heightFactor: 0.86,
        child: Container(
          decoration: BoxDecoration(
            color: tokens.surfaceColor,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(tokens.radiusLg),
            ),
            border: Border(
              top: BorderSide(color: tokens.borderColor.withValues(alpha: 0.8)),
            ),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: tokens.borderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
                child: Row(
                  children: [
                    Icon(
                      _activeTab == 0
                          ? Icons.manage_search_rounded
                          : Icons.edit_note_rounded,
                      color: tokens.accentColor,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        strings.searchLyricsTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.displayStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: tokens.textColor,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.close_rounded,
                        color: tokens.subtextColor,
                      ),
                      onPressed: () => Navigator.of(context).pop(false),
                      tooltip: strings.close,
                    ),
                  ],
                ),
              ),

              // 2-Tab Mode Switcher: Online Search | Paste / Edit Lyrics
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: tokens.elevatedSurfaceColor,
                    borderRadius: BorderRadius.circular(tokens.radiusPill),
                    border: Border.all(
                      color: tokens.borderColor.withValues(alpha: 0.7),
                    ),
                  ),
                  child: Row(
                    children: [
                      _tabSegment(
                        key: const Key('lyrics_sheet_tab_search'),
                        label: strings.searchLyricsTab,
                        icon: Icons.search_rounded,
                        selected: _activeTab == 0,
                        tokens: tokens,
                        onTap: () {
                          if (_activeTab != 0) {
                            setState(() => _activeTab = 0);
                            if (!_hasSearched && !_isSearching) {
                              unawaited(_runSearch());
                            }
                          }
                        },
                      ),
                      _tabSegment(
                        key: const Key('lyrics_sheet_tab_paste'),
                        label: strings.pasteLyricsTab,
                        icon: Icons.content_paste_rounded,
                        selected: _activeTab == 1,
                        tokens: tokens,
                        onTap: () {
                          if (_activeTab != 1) {
                            setState(() => _activeTab = 1);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),

              if (_activeTab == 0) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      TextField(
                        key: const Key('lyrics_search_query_field'),
                        controller: _queryController,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _runSearch(),
                        style: TextStyle(color: tokens.textColor, fontSize: 14),
                        decoration: InputDecoration(
                          labelText: strings.searchLyricsQueryLabel,
                          labelStyle: TextStyle(
                            color: tokens.subtextColor,
                            fontSize: 12.5,
                          ),
                          isDense: true,
                          filled: true,
                          fillColor: tokens.elevatedSurfaceColor,
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(tokens.radiusMd),
                            borderSide: BorderSide(color: tokens.borderColor),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('lyrics_search_artist_field'),
                              controller: _artistController,
                              textInputAction: TextInputAction.search,
                              onSubmitted: (_) => _runSearch(),
                              style: TextStyle(
                                color: tokens.textColor,
                                fontSize: 14,
                              ),
                              decoration: InputDecoration(
                                labelText: strings.searchLyricsArtistLabel,
                                labelStyle: TextStyle(
                                  color: tokens.subtextColor,
                                  fontSize: 12.5,
                                ),
                                isDense: true,
                                filled: true,
                                fillColor: tokens.elevatedSurfaceColor,
                                border: OutlineInputBorder(
                                  borderRadius:
                                      BorderRadius.circular(tokens.radiusMd),
                                  borderSide:
                                      BorderSide(color: tokens.borderColor),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            key: const Key('lyrics_search_submit_btn'),
                            style: FilledButton.styleFrom(
                              backgroundColor: tokens.accentColor,
                              foregroundColor: tokens.onAccentColor,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                            ),
                            onPressed: _isSearching ? null : _runSearch,
                            icon: const Icon(Icons.search_rounded, size: 18),
                            label: Text(
                              strings.searchLyricsButton,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Divider(
                  height: 1,
                  color: tokens.borderColor.withValues(alpha: 0.6),
                ),
                Expanded(
                  child: _buildResultsBody(strings, tokens),
                ),
              ] else ...[
                Expanded(
                  child: _buildPasteBody(strings, tokens),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabSegment({
    required Key key,
    required String label,
    required IconData icon,
    required bool selected,
    required SoneaThemeTokens tokens,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        key: key,
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? tokens.accentColor : Colors.transparent,
            borderRadius: BorderRadius.circular(tokens.radiusPill),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected ? tokens.onAccentColor : tokens.subtextColor,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color:
                        selected ? tokens.onAccentColor : tokens.subtextColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPasteBody(AppStrings strings, SoneaThemeTokens tokens) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_pasteError != null) ...[
            Text(
              _pasteError!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: 6),
          ],
          Expanded(
            child: TextField(
              key: const Key('lyrics_paste_input_field'),
              controller: _pasteController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: TextStyle(
                color: tokens.textColor,
                fontSize: 13.5,
                height: 1.45,
                fontFeatures: kTabularFigures,
              ),
              decoration: InputDecoration(
                hintText: strings.pasteLyricsHint,
                hintStyle: TextStyle(
                  color: tokens.subtextColor,
                  fontSize: 12.5,
                ),
                filled: true,
                fillColor: tokens.elevatedSurfaceColor,
                contentPadding: const EdgeInsets.all(12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(tokens.radiusMd),
                  borderSide: BorderSide(color: tokens.borderColor),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('lyrics_paste_save_btn'),
            style: FilledButton.styleFrom(
              backgroundColor: tokens.accentColor,
              foregroundColor: tokens.onAccentColor,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: _isApplying ? null : () => _savePastedLyrics(strings),
            icon: _isApplying
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: tokens.onAccentColor,
                    ),
                  )
                : const Icon(Icons.check_rounded, size: 18),
            label: Text(
              strings.saveLyricsAction,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsBody(AppStrings strings, SoneaThemeTokens tokens) {
    if (_isSearching || _isApplying) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: tokens.accentColor),
              const SizedBox(height: 12),
              Text(
                strings.searchLyricsSearching,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: tokens.subtextColor),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 36,
                color: tokens.subtextColor,
              ),
              const SizedBox(height: 10),
              Text(
                strings.searchLyricsFailed,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: tokens.textColor),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _runSearch,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: Text(strings.retryLyrics),
              ),
            ],
          ),
        ),
      );
    }

    if (_hasSearched && _candidates.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                strings.searchLyricsEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: tokens.subtextColor),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () => setState(() => _activeTab = 1),
                icon: const Icon(Icons.content_paste_rounded, size: 17),
                label: Text(strings.pasteLyricsAction),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _candidates.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final cand = _candidates[index];
        final durLabel = _formatDuration(cand.durationSecs);
        final sourceLabel = strings.lyricsSourceLabel(cand.source);

        return InkWell(
          key: Key('lyrics_candidate_$index'),
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          onTap: () => _selectCandidate(cand),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: tokens.elevatedSurfaceColor,
              borderRadius: BorderRadius.circular(tokens.radiusMd),
              border: Border.all(
                color: tokens.borderColor.withValues(alpha: 0.75),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        cand.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.displayStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: tokens.textColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: tokens.subtextColor,
                    ),
                  ],
                ),
                if (cand.artist.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    cand.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: tokens.subtextColor,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _pill(
                      label: sourceLabel,
                      bg: tokens.surfaceColor,
                      fg: tokens.textColor,
                      border: tokens.borderColor,
                      radius: tokens.radiusSm,
                    ),
                    _pill(
                      label: cand.isSynced
                          ? strings.lyricsSyncedBadge
                          : strings.lyricsPlainBadge,
                      bg: cand.isSynced
                          ? tokens.accentColor.withValues(alpha: 0.16)
                          : tokens.surfaceColor,
                      fg: cand.isSynced
                          ? tokens.accentColor
                          : tokens.subtextColor,
                      border: cand.isSynced
                          ? tokens.accentColor.withValues(alpha: 0.45)
                          : tokens.borderColor,
                      radius: tokens.radiusSm,
                    ),
                    if (durLabel.isNotEmpty)
                      _pill(
                        label: durLabel,
                        bg: tokens.surfaceColor,
                        fg: tokens.subtextColor,
                        border: tokens.borderColor,
                        radius: tokens.radiusSm,
                        tabular: true,
                      ),
                  ],
                ),
                if (cand.preview.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    cand.preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.35,
                      color: tokens.subtextColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _pill({
    required String label,
    required Color bg,
    required Color fg,
    required Color border,
    required double radius,
    bool tabular = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border.withValues(alpha: 0.7)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          fontFeatures: tabular ? kTabularFigures : null,
          color: fg,
        ),
      ),
    );
  }
}
