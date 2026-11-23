import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/core/app_logger.dart';
import 'package:sonea/core/app_paths.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/library/playlist_cover_service.dart';
import 'package:sonea/playback/playback_controller.dart';
import 'package:sonea/src/rust/api/library.dart' as rust_lib;
import 'package:sonea/src/rust/api/playlists.dart' as rust_pl;
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/ui/components/artwork_thumbnail.dart';
import 'package:sonea/ui/components/playlist_artwork_collage.dart';
import 'package:sonea/ui/components/sonea_logo_mark.dart';
import 'package:sonea/ui/navigation/navigation_back_controller.dart';

final playlistsRefreshProvider =
    NotifierProvider<PlaylistsRefreshNotifier, int>(
  PlaylistsRefreshNotifier.new,
);

class PlaylistsRefreshNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

class _PlaylistSummary {
  const _PlaylistSummary({
    required this.coverPaths,
    required this.totalDurationMs,
  });

  final List<String> coverPaths;
  final int totalDurationMs;
}

String formatPlaylistTotalDuration(int totalMs, {required bool isTurkish}) {
  if (totalMs <= 0) return '';
  final totalMinutes = totalMs ~/ 60000;
  final hours = totalMinutes ~/ 60;
  final mins = totalMinutes % 60;
  if (hours > 0) {
    return isTurkish ? '${hours}sa ${mins}dk' : '${hours}h ${mins}m';
  }
  if (totalMinutes > 0) {
    return isTurkish ? '$totalMinutes dk' : '$totalMinutes min';
  }
  final secs = (totalMs / 1000).round();
  return isTurkish ? '$secs sn' : '${secs}s';
}

class PlaylistsTab extends ConsumerStatefulWidget {
  const PlaylistsTab({super.key});

  @override
  ConsumerState<PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends ConsumerState<PlaylistsTab> {
  String? _dbPath;
  List<rust_pl.Playlist> _userPlaylists = [];
  Map<int, _PlaylistSummary> _summaries = {};
  List<rust_lib.Track> _activeTrackList = [];
  String _activeTitle = '';
  int? _activeUserPlaylistId;
  bool _isLoading = true;
  bool _isLoadingTracks = false;
  bool _isReordering = false;
  bool _isRemovingTrack = false;
  int _detailLoadNonce = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_initData());
  }

  Future<String> _ensureDbPath() async {
    final cached = _dbPath;
    if (cached != null) return cached;
    final path = await AppPaths.databasePath();
    _dbPath = path;
    return path;
  }

  Future<void> _initData() async {
    await _ensureDbPath();
    await _loadUserPlaylists();
  }

  Future<void> _loadUserPlaylists() async {
    try {
      final db = await _ensureDbPath();
      final list = await rust_pl.listPlaylists(dbPath: db);

      final entries = await Future.wait(
        list.map((pl) async {
          try {
            final tracks = await rust_pl.getPlaylistTracks(
              dbPath: db,
              playlistId: pl.id,
            );
            final covers = extractUniqueCovers(
              tracks.map((t) => t.coverPath),
              maxCount: 4,
            );
            int totalMs = 0;
            for (final t in tracks) {
              totalMs += t.durationMs?.toInt() ?? 0;
            }
            return MapEntry(
              pl.id.toInt(),
              _PlaylistSummary(coverPaths: covers, totalDurationMs: totalMs),
            );
          } catch (e) {
            appLog('PlaylistsTab', 'summary load failed for #${pl.id}', e);
            return MapEntry(
              pl.id.toInt(),
              const _PlaylistSummary(coverPaths: [], totalDurationMs: 0),
            );
          }
        }),
      );

      if (mounted) {
        setState(() {
          _userPlaylists = list;
          _summaries = Map.fromEntries(entries);
          _isLoading = false;
          _error = null;
        });
      }
    } catch (e, st) {
      appLog('PlaylistsTab', '_loadUserPlaylists failed', e, st);
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _playUserPlaylistDirect(
    rust_pl.Playlist pl, {
    required bool shuffled,
  }) async {
    try {
      final db = await _ensureDbPath();
      final tracks =
          await rust_pl.getPlaylistTracks(dbPath: db, playlistId: pl.id);
      if (tracks.isEmpty) return;
      final controller = ref.read(playbackControllerProvider.notifier);
      if (shuffled) {
        await controller.playShuffled(tracks);
      } else {
        await controller.playTrackList(tracks, 0);
      }
    } catch (e, st) {
      appLog('PlaylistsTab', 'direct play failed', e, st);
    }
  }

  Future<void> _openSmartPlaylist(
    String title,
    Future<List<rust_lib.Track>> Function(String dbPath) fetch,
  ) async {
    final nonce = ++_detailLoadNonce;
    setState(() {
      _activeTitle = title;
      _activeUserPlaylistId = null;
      _isReordering = false;
      _isLoadingTracks = true;
      _error = null;
    });
    ref.read(navigationBackProvider.notifier).setPlaylistDetailOpen(true);
    try {
      final db = await _ensureDbPath();
      final tracks = await fetch(db);
      if (mounted && nonce == _detailLoadNonce) {
        setState(() {
          _activeTrackList = tracks;
          _isLoadingTracks = false;
        });
      }
    } catch (e, st) {
      appLog('PlaylistsTab', '_openSmartPlaylist failed', e, st);
      if (mounted && nonce == _detailLoadNonce) {
        setState(() {
          _isLoadingTracks = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _openUserPlaylist(rust_pl.Playlist pl) async {
    final nonce = ++_detailLoadNonce;
    setState(() {
      _activeTitle = pl.name;
      _activeUserPlaylistId = pl.id.toInt();
      _isReordering = false;
      _isLoadingTracks = true;
      _error = null;
    });
    ref.read(navigationBackProvider.notifier).setPlaylistDetailOpen(true);
    try {
      final db = await _ensureDbPath();
      final tracks =
          await rust_pl.getPlaylistTracks(dbPath: db, playlistId: pl.id);
      if (mounted && nonce == _detailLoadNonce) {
        setState(() {
          _activeTrackList = tracks;
          _isLoadingTracks = false;
        });
      }
    } catch (e, st) {
      appLog('PlaylistsTab', '_openUserPlaylist failed', e, st);
      if (mounted && nonce == _detailLoadNonce) {
        setState(() {
          _isLoadingTracks = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _reorderTrackInActivePlaylist(int oldIndex, int newIndex) async {
    final plId = _activeUserPlaylistId;
    if (plId == null) return;
    if (oldIndex == newIndex ||
        oldIndex < 0 ||
        newIndex < 0 ||
        oldIndex >= _activeTrackList.length ||
        newIndex >= _activeTrackList.length) {
      return;
    }

    final previous = List<rust_lib.Track>.from(_activeTrackList);
    final updated = List<rust_lib.Track>.from(_activeTrackList);
    final moved = updated.removeAt(oldIndex);
    updated.insert(newIndex, moved);
    setState(() => _activeTrackList = updated);

    try {
      final db = await _ensureDbPath();
      await rust_pl.reorderPlaylistTrack(
        dbPath: db,
        playlistId: plId,
        oldIndex: oldIndex,
        newIndex: newIndex,
      );
      ref.read(playlistsRefreshProvider.notifier).bump();
    } catch (e, st) {
      appLog('PlaylistsTab', 'reorderPlaylistTrack failed', e, st);
      if (mounted) {
        setState(() => _activeTrackList = previous);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _removeTrackFromActivePlaylist(int index) async {
    final plId = _activeUserPlaylistId;
    if (plId == null ||
        _isRemovingTrack ||
        index < 0 ||
        index >= _activeTrackList.length) {
      return;
    }
    _isRemovingTrack = true;
    try {
      final db = await _ensureDbPath();
      await rust_pl.removeTrackFromPlaylist(
        dbPath: db,
        playlistId: plId,
        position: index,
      );
      if (mounted &&
          _activeUserPlaylistId == plId &&
          index < _activeTrackList.length) {
        setState(() {
          _activeTrackList = List<rust_lib.Track>.from(_activeTrackList)
            ..removeAt(index);
        });
      }
      await _loadUserPlaylists();
    } catch (e, st) {
      appLog('PlaylistsTab', 'removeTrackFromPlaylist failed', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      _isRemovingTrack = false;
    }
  }

  Future<void> _confirmDeletePlaylist(
    rust_pl.Playlist pl,
    AppStrings strings,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.deletePlaylistTitle),
        content: Text(strings.deletePlaylistConfirm(pl.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(strings.close),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final db = await _ensureDbPath();
      await rust_pl.deletePlaylist(dbPath: db, playlistId: pl.id);
      await _loadUserPlaylists();
    } catch (e, st) {
      appLog('PlaylistsTab', 'deletePlaylist failed', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _showNewPlaylistDialog(AppStrings strings) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NewPlaylistDialog(strings: strings),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final db = await _ensureDbPath();
      await rust_pl.createPlaylist(dbPath: db, name: name);
      await _loadUserPlaylists();
    } catch (e, st) {
      appLog('PlaylistsTab', 'createPlaylist failed', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _closePlaylistDetail() {
    if (_activeTitle.isEmpty) return;
    _detailLoadNonce++;
    setState(() {
      _activeTitle = '';
      _activeUserPlaylistId = null;
      _activeTrackList = [];
      _isReordering = false;
      _isLoadingTracks = false;
      _error = null;
    });
    ref.read(navigationBackProvider.notifier).setPlaylistDetailOpen(false);
  }

  Future<void> _changePlaylistCover(int playlistId, AppStrings strings) async {
    try {
      final saved = await ref
          .read(playlistCoversProvider.notifier)
          .pickAndSetCover(playlistId);
      if (saved != null && mounted) {
        ref.read(playlistsRefreshProvider.notifier).bump();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.playlistCoverUpdated)),
        );
      }
    } catch (e, st) {
      appLog('PlaylistsTab', '_changePlaylistCover failed', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _resetPlaylistCover(int playlistId, AppStrings strings) async {
    try {
      await ref
          .read(playlistCoversProvider.notifier)
          .clearCustomCover(playlistId);
      if (mounted) {
        ref.read(playlistsRefreshProvider.notifier).bump();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.playlistCoverReset)),
        );
      }
    } catch (e, st) {
      appLog('PlaylistsTab', '_resetPlaylistCover failed', e, st);
    }
  }

  void _showCoverOptionsSheet(int playlistId, AppStrings strings) {
    final hasCustom =
        ref.read(playlistCoversProvider).coverPathFor(playlistId) != null;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        final sheetTokens = SoneaThemeTokens.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(
                    Icons.photo_library_outlined,
                    color: sheetTokens.accentColor,
                  ),
                  title: Text(
                    strings.changeCoverImage,
                    style: TextStyle(color: sheetTokens.textColor),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (mounted) {
                      unawaited(_changePlaylistCover(playlistId, strings));
                    }
                  },
                ),
                if (hasCustom)
                  ListTile(
                    leading: Icon(
                      Icons.grid_view_rounded,
                      color: sheetTokens.subtextColor,
                    ),
                    title: Text(
                      strings.resetToAutoCollage,
                      style: TextStyle(color: sheetTokens.textColor),
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      if (mounted) {
                        unawaited(_resetPlaylistCover(playlistId, strings));
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

  String _formatTrackDuration(int? ms) {
    if (ms == null || ms <= 0) return '';
    final secs = (ms / 1000).round();
    final m = secs ~/ 60;
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playlistsRefreshProvider, (_, _) {
      unawaited(_loadUserPlaylists());
    });
    ref.listen(
      navigationBackProvider.select((s) => s.backActionNonce),
      (_, _) {
        final action = ref.read(navigationBackProvider).lastBackAction;
        if (action == 'close_playlist_detail' && mounted) {
          _closePlaylistDetail();
        }
      },
    );

    final strings = ref.watch(stringsProvider);
    final tokens = SoneaThemeTokens.of(context);
    final playlistCovers = ref.watch(playlistCoversProvider);
    final currentTrackId = ref.watch(
      playbackControllerProvider
          .select((s) => s.value?.currentTrack?.id.toInt()),
    );

    final activeCovers = extractUniqueCovers(
      _activeTrackList.map((t) => t.coverPath),
      maxCount: 4,
    );
    int activeTotalMs = 0;
    for (final t in _activeTrackList) {
      activeTotalMs += t.durationMs?.toInt() ?? 0;
    }

    return Scaffold(
      backgroundColor: tokens.backgroundColor,
      body: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top Bar
              Row(
                children: [
                  if (_activeTitle.isNotEmpty) ...[
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.arrow_back_rounded,
                        color: tokens.textColor,
                      ),
                      onPressed: _closePlaylistDetail,
                    ),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      _activeTitle.isNotEmpty
                          ? _activeTitle
                          : strings.playlistsTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.displayStyle(
                        fontSize: _activeTitle.isNotEmpty ? 20 : 26,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        color: tokens.textColor,
                      ),
                    ),
                  ),
                  if (_activeTitle.isEmpty)
                    FilledButton.tonalIcon(
                      key: const Key('playlists_new_btn'),
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            tokens.accentColor.withValues(alpha: 0.16),
                        foregroundColor: tokens.accentColor,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(tokens.radiusPill),
                        ),
                      ),
                      onPressed: () => _showNewPlaylistDialog(strings),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: Text(
                        strings.newShort,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  else if (_activeUserPlaylistId != null &&
                      _activeTrackList.length > 1)
                    TextButton.icon(
                      key: const Key('playlist_reorder_toggle_btn'),
                      style: TextButton.styleFrom(
                        foregroundColor: _isReordering
                            ? tokens.accentColor
                            : tokens.subtextColor,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () =>
                          setState(() => _isReordering = !_isReordering),
                      icon: Icon(
                        _isReordering
                            ? Icons.check_rounded
                            : Icons.swap_vert_rounded,
                        size: 18,
                      ),
                      label: Text(
                        _isReordering ? strings.done : strings.reorderAction,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 14),

              if (_activeTitle.isEmpty) ...[
                // Smart Auto-Playlist Cards Row
                Row(
                  children: [
                    _buildSmartCard(
                      title: strings.smartFavorites,
                      icon: Icons.favorite_rounded,
                      color: Colors.redAccent,
                      tokens: tokens,
                      onTap: () => _openSmartPlaylist(
                        strings.smartFavorites,
                        (db) => rust_lib.listFavoriteTracks(dbPath: db),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _buildSmartCard(
                      title: strings.smartRecentlyPlayed,
                      icon: Icons.history_rounded,
                      color: tokens.accentColor,
                      tokens: tokens,
                      onTap: () => _openSmartPlaylist(
                        strings.smartRecentlyPlayed,
                        (db) => rust_lib.listRecentlyPlayedTracks(
                          dbPath: db,
                          limit: 50,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _buildSmartCard(
                      title: strings.smartMostPlayed,
                      icon: Icons.bar_chart_rounded,
                      color: Colors.amber,
                      tokens: tokens,
                      onTap: () => _openSmartPlaylist(
                        strings.smartMostPlayed,
                        (db) => rust_lib.listMostPlayedTracks(
                          dbPath: db,
                          limit: 50,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      strings.yourPlaylists,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                        color: tokens.subtextColor,
                      ),
                    ),
                    if (_userPlaylists.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: tokens.surfaceColor,
                          borderRadius:
                              BorderRadius.circular(tokens.radiusPill),
                          border: Border.all(
                            color: tokens.borderColor.withValues(alpha: 0.7),
                          ),
                        ),
                        child: Text(
                          '${_userPlaylists.length}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            fontFeatures: kTabularFigures,
                            color: tokens.subtextColor,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),

                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _userPlaylists.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 72,
                                      height: 72,
                                      decoration: BoxDecoration(
                                        color: tokens.surfaceColor,
                                        borderRadius: BorderRadius.circular(
                                          tokens.radiusLg,
                                        ),
                                        border: Border.all(
                                          color: tokens.borderColor,
                                        ),
                                      ),
                                      alignment: Alignment.center,
                                      child: SoneaLogoMark(
                                        size: 42,
                                        upperColor: tokens.textColor
                                            .withValues(alpha: 0.75),
                                        lowerColor: tokens.accentColor,
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                    Text(
                                      strings.noUserPlaylists,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: tokens.textColor,
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                    FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: tokens.accentColor,
                                        foregroundColor: tokens.onAccentColor,
                                      ),
                                      onPressed: () =>
                                          _showNewPlaylistDialog(strings),
                                      icon: const Icon(
                                        Icons.add_rounded,
                                        size: 18,
                                      ),
                                      label: Text(strings.newPlaylist),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(bottom: 180),
                              itemExtent: 96,
                              itemCount: _userPlaylists.length,
                              itemBuilder: (context, index) {
                                final pl = _userPlaylists[index];
                                final summary = _summaries[pl.id.toInt()];
                                final durText = formatPlaylistTotalDuration(
                                  summary?.totalDurationMs ?? 0,
                                  isTurkish: strings.isTurkish,
                                );
                                final plId = pl.id.toInt();
                                final customCover =
                                    playlistCovers.coverPathFor(plId);
                                final coverRev =
                                    playlistCovers.revisionFor(plId);

                                return RepaintBoundary(
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(
                                        tokens.radiusMd,
                                      ),
                                      onTap: () => _openUserPlaylist(pl),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 11,
                                          vertical: 9,
                                        ),
                                        decoration: BoxDecoration(
                                          color: tokens.surfaceColor,
                                          borderRadius: BorderRadius.circular(
                                            tokens.radiusMd,
                                          ),
                                          border: Border.all(
                                            color: tokens.borderColor
                                                .withValues(alpha: 0.72),
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            PlaylistArtworkCollage(
                                              coverPaths:
                                                  summary?.coverPaths ??
                                                      const [],
                                              customCoverPath: customCover,
                                              cacheRevision: coverRev,
                                              size: 62,
                                              tokens: tokens,
                                              radius: tokens.radiusSm,
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: ClipRect(
                                                child: Column(
                                                  key: Key('playlist_card_meta_$plId'),
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      pl.name,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: tokens.displayStyle(
                                                        color: tokens.textColor,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        fontSize: 15,
                                                        letterSpacing: -0.2,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 5),
                                                    Text(
                                                      durText.isNotEmpty
                                                          ? '${strings.trackCountLabel(pl.trackCount)} • $durText'
                                                          : strings.trackCountLabel(
                                                              pl.trackCount,
                                                            ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        fontFeatures:
                                                            kTabularFigures,
                                                        color:
                                                            tokens.subtextColor,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Row(
                                              key: Key('playlist_card_actions_$plId'),
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (pl.trackCount > 0) ...[
                                                  SizedBox(
                                                    width: 34,
                                                    height: 34,
                                                    child: IconButton(
                                                      padding: EdgeInsets.zero,
                                                      constraints:
                                                          const BoxConstraints(
                                                        minWidth: 34,
                                                        minHeight: 34,
                                                      ),
                                                      iconSize: 18,
                                                      style:
                                                          IconButton.styleFrom(
                                                        backgroundColor: tokens
                                                            .elevatedSurfaceColor,
                                                        shape:
                                                            RoundedRectangleBorder(
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(
                                                            tokens.radiusSm,
                                                          ),
                                                        ),
                                                      ),
                                                      icon: Icon(
                                                        Icons.shuffle_rounded,
                                                        color:
                                                            tokens.subtextColor,
                                                      ),
                                                      tooltip:
                                                          strings.shuffleAll,
                                                      onPressed: () =>
                                                          _playUserPlaylistDirect(
                                                        pl,
                                                        shuffled: true,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                  SizedBox(
                                                    width: 34,
                                                    height: 34,
                                                    child: IconButton(
                                                      padding: EdgeInsets.zero,
                                                      constraints:
                                                          const BoxConstraints(
                                                        minWidth: 34,
                                                        minHeight: 34,
                                                      ),
                                                      iconSize: 20,
                                                      style:
                                                          IconButton.styleFrom(
                                                        backgroundColor:
                                                            tokens.accentColor,
                                                        shape:
                                                            RoundedRectangleBorder(
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(
                                                            tokens.radiusSm,
                                                          ),
                                                        ),
                                                      ),
                                                      icon: Icon(
                                                        Icons.play_arrow_rounded,
                                                        color: tokens
                                                            .onAccentColor,
                                                      ),
                                                      tooltip: strings.playAll,
                                                      onPressed: () =>
                                                          _playUserPlaylistDirect(
                                                        pl,
                                                        shuffled: false,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 2),
                                                ],
                                                SizedBox(
                                                  width: 30,
                                                  height: 36,
                                                  child:
                                                      PopupMenuButton<String>(
                                                    padding: EdgeInsets.zero,
                                                    icon: Icon(
                                                      Icons.more_vert_rounded,
                                                      size: 19,
                                                      color:
                                                          tokens.subtextColor,
                                                    ),
                                                    onSelected: (action) {
                                                      if (action ==
                                                          'change_cover') {
                                                        unawaited(
                                                          _changePlaylistCover(
                                                            plId,
                                                            strings,
                                                          ),
                                                        );
                                                      } else if (action ==
                                                          'reset_cover') {
                                                        unawaited(
                                                          _resetPlaylistCover(
                                                            plId,
                                                            strings,
                                                          ),
                                                        );
                                                      } else if (action ==
                                                          'delete') {
                                                        unawaited(
                                                          _confirmDeletePlaylist(
                                                            pl,
                                                            strings,
                                                          ),
                                                        );
                                                      }
                                                    },
                                                    itemBuilder: (_) => [
                                                      PopupMenuItem(
                                                        value: 'change_cover',
                                                        child: Row(
                                                          children: [
                                                            const Icon(
                                                              Icons
                                                                  .photo_library_outlined,
                                                              size: 18,
                                                            ),
                                                            const SizedBox(
                                                              width: 8,
                                                            ),
                                                            Flexible(
                                                              child: Text(
                                                                strings
                                                                    .changeCoverImage,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      if (customCover != null)
                                                        PopupMenuItem(
                                                          value: 'reset_cover',
                                                          child: Row(
                                                            children: [
                                                              const Icon(
                                                                Icons
                                                                    .grid_view_rounded,
                                                                size: 18,
                                                              ),
                                                              const SizedBox(
                                                                width: 8,
                                                              ),
                                                              Flexible(
                                                                child: Text(
                                                                  strings
                                                                      .resetToAutoCollage,
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      PopupMenuItem(
                                                        value: 'delete',
                                                        child: Row(
                                                          children: [
                                                            const Icon(
                                                              Icons
                                                                  .delete_outline_rounded,
                                                              size: 18,
                                                              color: Colors
                                                                  .redAccent,
                                                            ),
                                                            const SizedBox(
                                                              width: 8,
                                                            ),
                                                            Flexible(
                                                              child: Text(
                                                                strings.delete,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                ),
              ] else ...[
                // Modern Playlist Detail Header with Theme Gradient Backdrop, Large Cover & Pill Actions
                Container(
                  key: const Key('playlist_detail_header'),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        tokens.accentColor
                            .withValues(alpha: tokens.isLight ? 0.14 : 0.22),
                        tokens.surfaceColor,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(tokens.radiusLg),
                    border: Border.all(
                      color: tokens.borderColor.withValues(alpha: 0.75),
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          GestureDetector(
                            onTap: _activeUserPlaylistId != null
                                ? () => _showCoverOptionsSheet(
                                      _activeUserPlaylistId!,
                                      strings,
                                    )
                                : null,
                            child: Stack(
                              children: [
                                PlaylistArtworkCollage(
                                  coverPaths: activeCovers,
                                  customCoverPath: _activeUserPlaylistId != null
                                      ? playlistCovers
                                          .coverPathFor(_activeUserPlaylistId!)
                                      : null,
                                  cacheRevision: _activeUserPlaylistId != null
                                      ? playlistCovers
                                          .revisionFor(_activeUserPlaylistId!)
                                      : 0,
                                  size: 104,
                                  tokens: tokens,
                                  radius: tokens.radiusMd,
                                ),
                                if (_activeUserPlaylistId != null)
                                  Positioned(
                                    right: 5,
                                    bottom: 5,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: tokens.backgroundColor
                                            .withValues(alpha: 0.86),
                                        borderRadius: BorderRadius.circular(
                                          tokens.radiusSm,
                                        ),
                                        border: Border.all(
                                          color: tokens.accentColor
                                              .withValues(alpha: 0.45),
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.edit_rounded,
                                            size: 11,
                                            color: tokens.accentColor,
                                          ),
                                          const SizedBox(width: 3),
                                          Text(
                                            strings.coverBadge,
                                            style: TextStyle(
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.w700,
                                              color: tokens.textColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _activeTitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: tokens.displayStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.3,
                                    color: tokens.textColor,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    _metaPill(
                                      label: strings.trackCountLabel(
                                        _activeTrackList.length,
                                      ),
                                      tokens: tokens,
                                    ),
                                    if (activeTotalMs > 0)
                                      _metaPill(
                                        label: formatPlaylistTotalDuration(
                                          activeTotalMs,
                                          isTurkish: strings.isTurkish,
                                        ),
                                        tokens: tokens,
                                      ),
                                  ],
                                ),
                                if (_activeUserPlaylistId != null) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    strings.tapArtworkCoverHint,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: tokens.subtextColor,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: tokens.accentColor,
                                foregroundColor: tokens.onAccentColor,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 11,
                                ),
                                shape: const StadiumBorder(),
                              ),
                              onPressed: _activeTrackList.isEmpty
                                  ? null
                                  : () {
                                      ref
                                          .read(playbackControllerProvider
                                              .notifier)
                                          .playTrackList(
                                            _activeTrackList,
                                            0,
                                          );
                                    },
                              icon: const Icon(
                                Icons.play_arrow_rounded,
                                size: 20,
                              ),
                              label: Text(
                                strings.playAll,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: tokens.textColor,
                                backgroundColor: tokens.surfaceColor
                                    .withValues(alpha: 0.65),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 11,
                                ),
                                side: BorderSide(color: tokens.borderColor),
                                shape: const StadiumBorder(),
                              ),
                              onPressed: _activeTrackList.isEmpty
                                  ? null
                                  : () {
                                      ref
                                          .read(playbackControllerProvider
                                              .notifier)
                                          .playShuffled(_activeTrackList);
                                    },
                              icon: const Icon(
                                Icons.shuffle_rounded,
                                size: 18,
                              ),
                              label: Text(
                                strings.shuffleAll,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: _isLoadingTracks
                      ? const Center(child: CircularProgressIndicator())
                      : _activeTrackList.isEmpty
                          ? Center(
                              child: Text(
                                strings.noMusicFound,
                                style: TextStyle(color: tokens.subtextColor),
                              ),
                            )
                          : (_isReordering && _activeUserPlaylistId != null)
                              ? ReorderableListView.builder(
                                  padding: const EdgeInsets.only(bottom: 180),
                                  itemCount: _activeTrackList.length,
                                  onReorderItem: (oldIndex, newIndex) {
                                    unawaited(
                                      _reorderTrackInActivePlaylist(
                                        oldIndex,
                                        newIndex,
                                      ),
                                    );
                                  },
                                  itemBuilder: (context, index) {
                                    final track = _activeTrackList[index];
                                    return _buildTrackRow(
                                      key: ValueKey('pl_track_${track.id}_$index'),
                                      track: track,
                                      index: index,
                                      isCurrent:
                                          track.id.toInt() == currentTrackId,
                                      reordering: true,
                                      tokens: tokens,
                                      strings: strings,
                                    );
                                  },
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.only(bottom: 180),
                                  itemExtent: 64,
                                  itemCount: _activeTrackList.length,
                                  itemBuilder: (context, index) {
                                    final track = _activeTrackList[index];
                                    return _buildTrackRow(
                                      track: track,
                                      index: index,
                                      isCurrent:
                                          track.id.toInt() == currentTrackId,
                                      reordering: false,
                                      tokens: tokens,
                                      strings: strings,
                                    );
                                  },
                                ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTrackRow({
    Key? key,
    required rust_lib.Track track,
    required int index,
    required bool isCurrent,
    required bool reordering,
    required SoneaThemeTokens tokens,
    required AppStrings strings,
  }) {
    final dur = _formatTrackDuration(track.durationMs?.toInt());
    return RepaintBoundary(
      key: key,
      child: InkWell(
        borderRadius: BorderRadius.circular(tokens.radiusSm),
        onTap: reordering
            ? null
            : () {
                ref
                    .read(playbackControllerProvider.notifier)
                    .playTrackList(_activeTrackList, index);
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            children: [
              ArtworkThumbnail(
                coverPath: track.coverPath,
                size: 44,
                tokens: tokens,
                cacheWidth: 160,
                borderColor: isCurrent ? tokens.accentColor : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isCurrent ? tokens.accentColor : tokens.textColor,
                        fontSize: 14,
                        fontWeight:
                            isCurrent ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.artist?.isNotEmpty == true
                          ? track.artist!
                          : strings.unknownArtist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tokens.subtextColor,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (!reordering && dur.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    dur,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      fontFeatures: kTabularFigures,
                      color: tokens.subtextColor,
                    ),
                  ),
                ),
              if (reordering)
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(
                      Icons.drag_handle_rounded,
                      color: tokens.accentColor,
                    ),
                  ),
                )
              else if (_activeUserPlaylistId != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.remove_circle_outline_rounded,
                    size: 18,
                    color: tokens.subtextColor,
                  ),
                  onPressed: () => _removeTrackFromActivePlaylist(index),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metaPill({
    required String label,
    required SoneaThemeTokens tokens,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: BoxDecoration(
        color: tokens.elevatedSurfaceColor,
        borderRadius: BorderRadius.circular(tokens.radiusPill),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          fontFeatures: kTabularFigures,
          color: tokens.subtextColor,
        ),
      ),
    );
  }

  Widget _buildSmartCard({
    required String title,
    required IconData icon,
    required Color color,
    required SoneaThemeTokens tokens,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: RepaintBoundary(
        child: InkWell(
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 96),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              color: tokens.surfaceColor,
              borderRadius: BorderRadius.circular(tokens.radiusMd),
              border: Border.all(
                color: tokens.borderColor.withValues(alpha: 0.72),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(tokens.radiusSm),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, color: color, size: 19),
                ),
                const SizedBox(height: 6),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: tokens.textColor,
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

class _NewPlaylistDialog extends StatefulWidget {
  const _NewPlaylistDialog({required this.strings});

  final AppStrings strings;

  @override
  State<_NewPlaylistDialog> createState() => _NewPlaylistDialogState();
}

class _NewPlaylistDialogState extends State<_NewPlaylistDialog> {
  final _controller = TextEditingController();
  bool _canSubmit = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final next = _controller.text.trim().isNotEmpty;
      if (next != _canSubmit) {
        setState(() => _canSubmit = next);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = SoneaThemeTokens.of(context);
    return AlertDialog(
      backgroundColor: tokens.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusLg),
        side: BorderSide(color: tokens.borderColor),
      ),
      title: Row(
        children: [
          Icon(Icons.playlist_add_rounded, color: tokens.accentColor, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.strings.newPlaylist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.displayStyle(
                fontWeight: FontWeight.w700,
                color: tokens.textColor,
              ),
            ),
          ),
        ],
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 80,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        style: TextStyle(color: tokens.textColor),
        decoration: InputDecoration(
          hintText: widget.strings.playlistName,
          hintStyle: TextStyle(color: tokens.subtextColor),
          filled: true,
          fillColor: tokens.elevatedSurfaceColor,
          prefixIcon: Icon(
            Icons.queue_music_rounded,
            color: tokens.accentColor,
            size: 20,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(tokens.radiusMd),
            borderSide: BorderSide(color: tokens.borderColor),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.strings.close),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: tokens.accentColor,
            foregroundColor: tokens.onAccentColor,
          ),
          onPressed: _canSubmit ? _submit : null,
          child: Text(widget.strings.create),
        ),
      ],
    );
  }
}
