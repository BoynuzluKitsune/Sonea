import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/core/app_paths.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/library/library_controller.dart' show libraryProvider;
import 'package:sonea/library/library_filter_controller.dart';
import 'package:sonea/playback/playback_controller.dart';
import 'package:sonea/settings/app_settings_controller.dart';
import 'package:sonea/src/rust/api/library.dart' as rust;
import 'package:sonea/src/rust/api/playlists.dart' as rust_playlists;
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/ui/components/artwork_thumbnail.dart';
import 'package:sonea/ui/components/playlist_artwork_collage.dart';
import 'package:sonea/ui/components/sonea_logo_mark.dart';
import 'package:sonea/ui/library/metadata_editor_dialog.dart';
import 'package:sonea/ui/navigation/navigation_back_controller.dart';
import 'package:sonea/ui/playlists/playlists_tab.dart' show playlistsRefreshProvider;
import 'package:path/path.dart' as p;

class FolderGroup {
  const FolderGroup({
    required this.path,
    required this.name,
    required this.relativePath,
    required this.tracks,
  });

  final String path;
  final String name;
  final String relativePath;
  final List<rust.Track> tracks;
}

class LibraryTab extends ConsumerStatefulWidget {
  const LibraryTab({super.key});

  @override
  ConsumerState<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends ConsumerState<LibraryTab>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  final _searchController = TextEditingController();
  final _tracksScrollController = ScrollController();
  bool _searchExpanded = false;
  bool _initialScanRequested = false;
  Timer? _searchDebounce;
  String? _selectedFolderPath;
  String? _draggedLetter;
  final Set<int> _selectedTrackIds = {};
  int _lastSubTabIndex = 0;
  bool _suppressSubTabHistory = false;

  static final List<String> _alphabet = [
    '#',
    ...List.generate(26, (i) => String.fromCharCode(65 + i))
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(_handleTabChange);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final perm = ref.read(libraryProvider).value?.permission;
      if (perm != 'granted') {
        unawaited(ref.read(libraryProvider.notifier).refreshPermission());
      }
    }
  }

  void _handleTabChange() {
    if (_tabController.indexIsChanging) return;
    final newTab = _tabController.index;
    if (!_suppressSubTabHistory && newTab != _lastSubTabIndex) {
      ref
          .read(navigationBackProvider.notifier)
          .recordLibrarySubTabChange(_lastSubTabIndex, newTab);
    }
    _lastSubTabIndex = newTab;
    _suppressSubTabHistory = false;
    ref.read(libraryProvider.notifier).setTab(newTab);
    if (newTab != 3 && _selectedFolderPath != null) {
      setState(() => _selectedFolderPath = null);
      ref
          .read(navigationBackProvider.notifier)
          .setLibraryUiState(folderDetailOpen: false);
    }
    if (_selectedTrackIds.isNotEmpty) {
      setState(() => _selectedTrackIds.clear());
      ref
          .read(navigationBackProvider.notifier)
          .setLibraryUiState(multiSelectActive: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _tracksScrollController.dispose();
    super.dispose();
  }

  String _normalizeLeadingChar(String str) {
    if (str.isEmpty) return '#';
    final first = str[0].toUpperCase();
    return switch (first) {
      'Ç' => 'C',
      'Ğ' => 'G',
      'I' || 'İ' => 'I',
      'Ö' => 'O',
      'Ş' => 'S',
      'Ü' => 'U',
      _ => (first.codeUnitAt(0) >= 65 && first.codeUnitAt(0) <= 90) ? first : '#',
    };
  }

  void _jumpToAlphabetLetter(String letter, List<rust.Track> tracks, double itemHeight) {
    if (tracks.isEmpty) return;
    int targetIdx = -1;
    if (letter == '#') {
      targetIdx = 0;
    } else {
      targetIdx = tracks.indexWhere((t) => _normalizeLeadingChar(t.title) == letter);
      if (targetIdx == -1) {
        targetIdx = tracks.indexWhere((t) => _normalizeLeadingChar(t.title).compareTo(letter) >= 0);
      }
    }
    if (targetIdx != -1) {
      final offset = (targetIdx * itemHeight).clamp(
        0.0,
        _tracksScrollController.position.maxScrollExtent,
      );
      _tracksScrollController.jumpTo(offset);
    }
  }

  List<FolderGroup> _groupTracksByFolder(List<rust.Track> tracks, String query) {
    final map = <String, List<rust.Track>>{};
    for (final t in tracks) {
      final parent = p.dirname(t.path);
      map.putIfAbsent(parent, () => []).add(t);
    }

    final folders = <FolderGroup>[];
    final normQuery = query.trim().toLowerCase();

    for (final entry in map.entries) {
      final folderPath = entry.key;
      final folderName = p.basename(folderPath).isEmpty ? 'Music' : p.basename(folderPath);

      String relativePath = folderPath;
      if (folderPath.contains('Music')) {
        relativePath = folderPath.substring(folderPath.indexOf('Music'));
      } else if (folderPath.contains('Download')) {
        relativePath = folderPath.substring(folderPath.indexOf('Download'));
      } else {
        final parts = folderPath.split(Platform.pathSeparator);
        if (parts.length > 2) {
          relativePath = parts.sublist(parts.length - 2).join('/');
        }
      }

      final folderTracks = entry.value;

      if (normQuery.isNotEmpty) {
        final matchesName = folderName.toLowerCase().contains(normQuery) ||
            relativePath.toLowerCase().contains(normQuery);
        final matchingTracks = folderTracks
            .where((t) =>
                t.title.toLowerCase().contains(normQuery) ||
                (t.artist?.toLowerCase().contains(normQuery) ?? false) ||
                (t.album?.toLowerCase().contains(normQuery) ?? false))
            .toList();

        if (!matchesName && matchingTracks.isEmpty) continue;
      }

      folders.add(FolderGroup(
        path: folderPath,
        name: folderName,
        relativePath: relativePath,
        tracks: folderTracks,
      ));
    }

    folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return folders;
  }

  void _hideFolder(FolderGroup folder, AppStrings strings) {
    ref.read(libraryFilterProvider.notifier).addExcludedFolder(folder.path);
    if (_selectedFolderPath == folder.path) {
      setState(() => _selectedFolderPath = null);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(strings.folderHidden),
        action: SnackBarAction(
          label: strings.undo,
          onPressed: () {
            ref.read(libraryFilterProvider.notifier).removeExcludedFolder(folder.path);
          },
        ),
      ),
    );
  }

  Future<void> _addTracksToFavorites(
    List<rust.Track> tracks,
    AppStrings strings,
  ) async {
    try {
      final dbPath = await AppPaths.databasePath();
      final trackIds = tracks.map((t) => t.id).toList();

      final addedCount = await rust.addTracksToFavorites(
        dbPath: dbPath,
        trackIds: Int64List.fromList(trackIds),
      );

      ref.read(playlistsRefreshProvider.notifier).bump();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(strings.addedTracksToFavorites(addedCount.toInt())),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _createPlaylistFromTracks(
    List<rust.Track> tracks,
    String defaultName,
    AppStrings strings,
  ) async {
    final playlistName = await showDialog<String>(
      context: context,
      builder: (_) => _CreatePlaylistNameDialog(
        defaultName: defaultName,
        strings: strings,
      ),
    );
    if (!mounted) return;

    if (playlistName != null && playlistName.isNotEmpty) {
      try {
        final dbPath = await AppPaths.databasePath();
        final playlist = await rust_playlists.createPlaylist(
          dbPath: dbPath,
          name: playlistName,
        );

        final trackIds = tracks.map((t) => t.id).toList();
        await rust_playlists.addTracksToPlaylist(
          dbPath: dbPath,
          playlistId: playlist.id,
          trackIds: Int64List.fromList(trackIds),
        );

        ref.read(playlistsRefreshProvider.notifier).bump();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                strings.addedFolderToPlaylist(trackIds.length, playlist.name),
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')),
          );
        }
      }
    }
  }

  Future<void> _addTracksToExistingPlaylist(
    List<rust.Track> tracks,
    AppStrings strings,
  ) async {
    try {
      final dbPath = await AppPaths.databasePath();
      final playlists = await rust_playlists.listPlaylists(dbPath: dbPath);

      if (!mounted) return;

      if (playlists.isEmpty) {
        await _createPlaylistFromTracks(tracks, 'Playlist 1', strings);
        return;
      }

      final selected = await showModalBottomSheet<rust_playlists.Playlist>(
        context: context,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (sheetContext) {
          final tokens = SoneaThemeTokens.of(sheetContext);

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      strings.addToExistingPlaylist,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: tokens.textColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 240,
                    child: ListView.builder(
                      itemCount: playlists.length,
                      itemBuilder: (itemContext, index) {
                        final p = playlists[index];
                        return ListTile(
                          leading: Icon(Icons.queue_music, color: tokens.accentColor),
                          title: Text(p.name, style: TextStyle(color: tokens.textColor)),
                          subtitle: Text(
                            strings.folderTrackCount(p.trackCount.toInt()),
                            style: TextStyle(color: tokens.subtextColor, fontSize: 12),
                          ),
                          onTap: () => Navigator.pop(sheetContext, p),
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

      if (selected != null) {
        final trackIds = tracks.map((t) => t.id).toList();
        final addedCount = await rust_playlists.addTracksToPlaylist(
          dbPath: dbPath,
          playlistId: selected.id,
          trackIds: Int64List.fromList(trackIds),
        );

        ref.read(playlistsRefreshProvider.notifier).bump();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                strings.addedFolderToPlaylist(addedCount.toInt(), selected.name),
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      navigationBackProvider.select((s) => s.backActionNonce),
      (_, _) {
        final action = ref.read(navigationBackProvider).lastBackAction;
        if (!mounted || action == null) return;
        if (action == 'close_library_multiselect') {
          setState(() => _selectedTrackIds.clear());
        } else if (action == 'close_library_search') {
          setState(() {
            _searchExpanded = false;
            _searchController.clear();
          });
          ref.read(libraryProvider.notifier).search('');
        } else if (action == 'close_library_folder') {
          setState(() => _selectedFolderPath = null);
        } else if (action.startsWith('pop_library_subtab:')) {
          final idx = int.tryParse(action.split(':').last);
          if (idx != null && idx >= 0 && idx < 4 && _tabController.index != idx) {
            _suppressSubTabHistory = true;
            _tabController.animateTo(idx);
          }
        }
      },
    );

    final libraryAsync = ref.watch(libraryProvider);
    final libraryNotifier = ref.read(libraryProvider.notifier);
    final filterState = ref.watch(libraryFilterProvider);
    final appSettings = ref.watch(appSettingsProvider);
    final strings = ref.watch(stringsProvider);
    final tokens = SoneaThemeTokens.of(context);

    return SafeArea(
      bottom: false,
      child: libraryAsync.when(
        loading: () => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SoneaLogoMark(
                size: 48,
                upperColor: tokens.textColor.withValues(alpha: 0.8),
                lowerColor: tokens.accentColor,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: tokens.accentColor,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                strings.isTurkish
                    ? 'Kütüphane hazırlanıyor...'
                    : 'Preparing library...',
                style: TextStyle(fontSize: 13, color: tokens.subtextColor),
              ),
            ],
          ),
        ),
        error: (err, _) => Center(child: Text('Error: $err')),
        data: (library) {
          if (library.permission != 'granted') {
            final permanent = library.permission == 'permanentlyDenied';
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        color: tokens.surfaceColor,
                        borderRadius: BorderRadius.circular(tokens.radiusLg),
                        border: Border.all(
                          color: tokens.accentColor.withValues(alpha: 0.35),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: SoneaLogoMark(
                        size: 46,
                        upperColor: tokens.textColor,
                        lowerColor: tokens.accentColor,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      permanent
                          ? strings.permissionSettingsRequired
                          : strings.permissionRequired,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.45,
                        color: tokens.textColor,
                      ),
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: tokens.accentColor,
                        foregroundColor: tokens.onAccentColor,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                      ),
                      onPressed: permanent
                          ? libraryNotifier.openSettings
                          : libraryNotifier.requestPermission,
                      icon: Icon(
                        permanent
                            ? Icons.settings_rounded
                            : Icons.folder_open_rounded,
                        size: 18,
                      ),
                      label: Text(
                        permanent ? strings.openSettings : strings.allowAccess,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          if (!_initialScanRequested && appSettings.autoScanOnStartup) {
            _initialScanRequested = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final latest = ref.read(libraryProvider).value;
              if (latest?.permission == 'granted' &&
                  latest?.scanning != true &&
                  latest?.tracks.isEmpty == true) {
                unawaited(ref.read(libraryProvider.notifier).scan());
              }
            });
          }

          if (_tabController.index != library.tab) {
            _suppressSubTabHistory = true;
            _tabController.index = library.tab;
            _lastSubTabIndex = library.tab;
          }

          // Apply non-destructive filtering
          final filteredTracks = library.tracks.where(filterState.isTrackAllowed).toList();
          final folders = _groupTracksByFolder(filteredTracks, library.query);
          FolderGroup? currentFolder;
          if (_selectedFolderPath != null) {
            for (final f in folders) {
              if (f.path == _selectedFolderPath) {
                currentFolder = f;
                break;
              }
            }
          }

          final isMultiSelecting = _selectedTrackIds.isNotEmpty;

          return Column(
              children: [
                // Top Header OR Contextual Selection Bar
                if (isMultiSelecting)
                  Container(
                    color: tokens.surfaceColor,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Row(
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            setState(() => _selectedTrackIds.clear());
                            ref
                                .read(navigationBackProvider.notifier)
                                .setLibraryUiState(multiSelectActive: false);
                          },
                          tooltip: strings.clearSelection,
                        ),
                        Expanded(
                          child: Text(
                            strings.selectedCount(_selectedTrackIds.length),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: tokens.textColor,
                            ),
                          ),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          onPressed: () {
                            setState(() {
                              if (_selectedTrackIds.length == filteredTracks.length) {
                                _selectedTrackIds.clear();
                              } else {
                                _selectedTrackIds.addAll(filteredTracks.map((t) => t.id.toInt()));
                              }
                            });
                          },
                          child: Text(
                            _selectedTrackIds.length == filteredTracks.length
                                ? strings.clearSelection
                                : strings.selectAll,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.favorite_rounded, color: Colors.redAccent),
                          onPressed: () {
                            final selectedTracks = filteredTracks
                                .where((t) => _selectedTrackIds.contains(t.id.toInt()))
                                .toList();
                            _addTracksToFavorites(selectedTracks, strings);
                            setState(() => _selectedTrackIds.clear());
                          },
                          tooltip: strings.addToFavorites,
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.playlist_add),
                          onPressed: () {
                            final selectedTracks = filteredTracks
                                .where((t) => _selectedTrackIds.contains(t.id.toInt()))
                                .toList();
                            _createPlaylistFromTracks(selectedTracks, strings.newPlaylist, strings);
                          },
                          tooltip: strings.create,
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.queue_music),
                          onPressed: () {
                            final selectedTracks = filteredTracks
                                .where((t) => _selectedTrackIds.contains(t.id.toInt()))
                                .toList();
                            _addTracksToExistingPlaylist(selectedTracks, strings);
                          },
                          tooltip: strings.addToPlaylist,
                        ),
                      ],
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                    child: Row(
                      children: [
                        SoneaLogoMark(
                          key: const Key('library_header_logo'),
                          size: 36,
                          tight: true,
                          upperColor: tokens.textColor,
                          lowerColor: tokens.accentColor,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                strings.libraryTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: tokens.displayStyle(
                                  fontSize: 23,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.5,
                                  color: tokens.textColor,
                                ),
                              ),
                              Text(
                                library.scanning
                                    ? strings.scanningLiveCounter(
                                        library.processed,
                                        library.total,
                                      )
                                    : strings.trackCountLabel(
                                        filteredTracks.length,
                                      ),
                                key: const Key('library_header_subtitle'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: library.scanning
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  fontFeatures: kTabularFigures,
                                  color: library.scanning
                                      ? tokens.accentColor
                                      : tokens.subtextColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (filteredTracks.isNotEmpty) ...[
                          _headerActionButton(
                            icon: Icons.shuffle_rounded,
                            color: tokens.accentColor,
                            tokens: tokens,
                            tooltip: strings.shuffleAll,
                            onPressed: () => ref
                                .read(playbackControllerProvider.notifier)
                                .playShuffled(filteredTracks),
                          ),
                          const SizedBox(width: 6),
                        ],
                        _headerActionButton(
                          icon: _searchExpanded ? Icons.close : Icons.search,
                          color: _searchExpanded
                              ? tokens.accentColor
                              : tokens.textColor,
                          tokens: tokens,
                          tooltip: strings.searchPlaceholder,
                          onPressed: () {
                            setState(() {
                              _searchExpanded = !_searchExpanded;
                              if (!_searchExpanded) {
                                _searchController.clear();
                                libraryNotifier.search('');
                              }
                            });
                            ref
                                .read(navigationBackProvider.notifier)
                                .setLibraryUiState(searchOpen: _searchExpanded);
                          },
                        ),
                        const SizedBox(width: 6),
                        _headerActionButton(
                          icon: Icons.refresh_rounded,
                          color: library.scanning
                              ? tokens.accentColor
                              : tokens.textColor,
                          tokens: tokens,
                          tooltip: strings.scanButton,
                          onPressed: libraryNotifier.scan,
                        ),
                      ],
                    ),
                  ),

                // Expandable Pill Search Bar
                if (_searchExpanded && !isMultiSelecting)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: SizedBox(
                      height: 44,
                      child: TextField(
                        controller: _searchController,
                        style: TextStyle(color: tokens.textColor, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: strings.searchPlaceholder,
                          hintStyle: TextStyle(
                            color: tokens.subtextColor,
                            fontSize: 14,
                          ),
                          prefixIcon: Icon(
                            Icons.search,
                            color: tokens.subtextColor,
                            size: 20,
                          ),
                          filled: true,
                          fillColor: tokens.surfaceColor,
                          contentPadding: EdgeInsets.zero,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(tokens.radiusPill),
                            borderSide: BorderSide(
                              color: tokens.borderColor.withValues(alpha: 0.7),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(tokens.radiusPill),
                            borderSide: BorderSide(
                              color: tokens.borderColor.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                        onChanged: (val) {
                          _searchDebounce?.cancel();
                          _searchDebounce = Timer(
                            const Duration(milliseconds: 250),
                            () => libraryNotifier.search(val),
                          );
                        },
                      ),
                    ),
                  ),

                // Live Scanning Progress Banner Card
                if (library.scanning)
                  Container(
                    key: const Key('library_live_scan_banner'),
                    margin: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: tokens.surfaceColor,
                      borderRadius: BorderRadius.circular(tokens.radiusMd),
                      border: Border.all(
                        color: tokens.accentColor.withValues(alpha: 0.45),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: tokens.accentColor,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                strings.scanningLiveCounter(
                                  library.processed,
                                  library.total,
                                ),
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: kTabularFigures,
                                  color: tokens.textColor,
                                ),
                              ),
                            ),
                            if (library.total > 0)
                              Text(
                                '${((library.processed / library.total) * 100).clamp(0, 100).round()}%',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: kTabularFigures,
                                  color: tokens.accentColor,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(tokens.radiusPill),
                          child: LinearProgressIndicator(
                            minHeight: 5,
                            value: library.total == 0
                                ? null
                                : (library.processed / library.total)
                                    .clamp(0.0, 1.0),
                            backgroundColor:
                                tokens.borderColor.withValues(alpha: 0.5),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              tokens.accentColor,
                            ),
                          ),
                        ),
                        if (library.unreadable > 0) ...[
                          const SizedBox(height: 5),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              strings.scanProgress(
                                library.processed,
                                library.total,
                                library.unreadable,
                              ),
                              style: TextStyle(
                                fontSize: 10.5,
                                fontFeatures: kTabularFigures,
                                color: tokens.subtextColor,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                // Visible Scan / Library Error Banner
                if (library.error != null && library.error!.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.error.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(tokens.radiusMd),
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
                            library.error!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: tokens.textColor),
                          ),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          onPressed: libraryNotifier.scan,
                          child: Text(strings.retry, style: const TextStyle(fontSize: 12)),
                        ),
                        IconButton(
                          constraints: const BoxConstraints(),
                          padding: EdgeInsets.zero,
                          icon: Icon(Icons.close_rounded, size: 16, color: tokens.subtextColor),
                          onPressed: libraryNotifier.clearError,
                        ),
                      ],
                    ),
                  ),

                // Tab Selector spanning full width (4 tabs with FittedBox)
                TabBar(
                  controller: _tabController,
                  isScrollable: false,
                  padding: EdgeInsets.zero,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                  labelStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                  unselectedLabelStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
                  dividerColor: Colors.transparent,
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicatorColor: tokens.accentColor,
                  labelColor: tokens.accentColor,
                  unselectedLabelColor: tokens.subtextColor,
                  indicatorWeight: 3,
                  tabs: [
                    Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text(strings.subTabTracks, maxLines: 1))),
                    Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text(strings.subTabAlbums, maxLines: 1))),
                    Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text(strings.subTabArtists, maxLines: 1))),
                    Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text(strings.tabFiles, maxLines: 1))),
                  ],
                ),

                // Tab Views via TabBarView
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildTracksList(
                        filteredTracks,
                        tokens,
                        strings,
                        ref,
                        isScanning: library.scanning,
                        processedCount: library.processed,
                        totalCount: library.total,
                        onRescan: libraryNotifier.scan,
                      ),
                      _buildAlbumsGrid(filteredTracks, tokens, strings),
                      _buildArtistsList(filteredTracks, tokens, strings),
                      currentFolder != null
                          ? _buildFolderDetailView(currentFolder, tokens, strings, ref)
                          : _buildFoldersList(folders, tokens, strings, ref),
                    ],
                  ),
                ),
              ],
            );
        },
      ),
    );
  }

  Widget _buildFoldersList(
    List<FolderGroup> folders,
    SoneaThemeTokens tokens,
    AppStrings strings,
    WidgetRef ref,
  ) {
    if (folders.isEmpty) {
      return Center(
        child: Text(
          strings.noFilesFound,
          style: TextStyle(color: tokens.subtextColor),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 180),
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final folder = folders[index];
        return ListTile(
          onTap: () {
            setState(() => _selectedFolderPath = folder.path);
            ref
                .read(navigationBackProvider.notifier)
                .setLibraryUiState(folderDetailOpen: true);
          },
          leading: Icon(
            Icons.folder_rounded,
            size: 36,
            color: tokens.accentColor,
          ),
          title: Text(
            folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: tokens.textColor,
            ),
          ),
          subtitle: Text(
            '${folder.relativePath} • ${strings.folderTrackCount(folder.tracks.length)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: tokens.subtextColor),
          ),
          trailing: PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: tokens.subtextColor),
            onSelected: (val) {
              if (val == 'play_all') {
                ref
                    .read(playbackControllerProvider.notifier)
                    .playTrackList(folder.tracks, 0);
              } else if (val == 'create_playlist') {
                _createPlaylistFromTracks(folder.tracks, folder.name, strings);
              } else if (val == 'add_to_playlist') {
                _addTracksToExistingPlaylist(folder.tracks, strings);
              } else if (val == 'add_favorites') {
                _addTracksToFavorites(folder.tracks, strings);
              } else if (val == 'hide_folder') {
                _hideFolder(folder, strings);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'play_all',
                child: Row(
                  children: [
                    const Icon(Icons.play_arrow, size: 20),
                    const SizedBox(width: 8),
                    Text(strings.playAll),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'create_playlist',
                child: Row(
                  children: [
                    const Icon(Icons.playlist_add, size: 20),
                    const SizedBox(width: 8),
                    Text(strings.createPlaylistFromFolder),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'add_to_playlist',
                child: Row(
                  children: [
                    const Icon(Icons.queue_music, size: 20),
                    const SizedBox(width: 8),
                    Text(strings.addToExistingPlaylist),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'add_favorites',
                child: Row(
                  children: [
                    const Icon(Icons.favorite_rounded, size: 20, color: Colors.redAccent),
                    const SizedBox(width: 8),
                    Text(strings.addToFavorites),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'hide_folder',
                child: Row(
                  children: [
                    const Icon(Icons.folder_off_rounded, size: 20, color: Colors.redAccent),
                    const SizedBox(width: 8),
                    Text(strings.hideFolder),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFolderDetailView(
    FolderGroup folder,
    SoneaThemeTokens tokens,
    AppStrings strings,
    WidgetRef ref,
  ) {
    return Column(
      children: [
        // Folder Detail Header Action Bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () {
                      setState(() => _selectedFolderPath = null);
                      ref
                          .read(navigationBackProvider.notifier)
                          .setLibraryUiState(folderDetailOpen: false);
                    },
                    tooltip: strings.backToFolders,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          folder.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: tokens.textColor,
                          ),
                        ),
                        Text(
                          strings.folderTrackCount(folder.tracks.length),
                          style: TextStyle(fontSize: 12, color: tokens.subtextColor),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.favorite_rounded, color: Colors.redAccent),
                    onPressed: () => _addTracksToFavorites(folder.tracks, strings),
                    tooltip: strings.addToFavorites,
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Action Buttons Row (Play All, Create Playlist, Add to Playlist)
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: tokens.accentColor,
                        foregroundColor: tokens.onAccentColor,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 8,
                        ),
                      ),
                      onPressed: () {
                        ref
                            .read(playbackControllerProvider.notifier)
                            .playTrackList(folder.tracks, 0);
                      },
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: Text(
                        strings.playAll,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 8,
                        ),
                        side: BorderSide(color: tokens.subtextColor.withValues(alpha: 0.3)),
                      ),
                      onPressed: () => _createPlaylistFromTracks(folder.tracks, folder.name, strings),
                      icon: const Icon(Icons.playlist_add, size: 16),
                      label: Text(
                        strings.create,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: tokens.textColor),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 8,
                        ),
                        side: BorderSide(color: tokens.subtextColor.withValues(alpha: 0.3)),
                      ),
                      onPressed: () => _addTracksToExistingPlaylist(folder.tracks, strings),
                      icon: const Icon(Icons.queue_music, size: 16),
                      label: Text(
                        strings.addToPlaylist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: tokens.textColor),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Folder Track List
        Expanded(
          child: _buildTracksList(folder.tracks, tokens, strings, ref),
        ),
      ],
    );
  }

  Widget _headerActionButton({
    required IconData icon,
    required Color color,
    required SoneaThemeTokens tokens,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: tokens.surfaceColor,
        borderRadius: BorderRadius.circular(tokens.radiusSm),
        border: Border.all(
          color: tokens.borderColor.withValues(alpha: 0.72),
        ),
      ),
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 20,
        icon: Icon(icon, color: color),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildTracksList(
    List<rust.Track> tracks,
    SoneaThemeTokens tokens,
    AppStrings strings,
    WidgetRef ref, {
    bool isScanning = false,
    int processedCount = 0,
    int totalCount = 0,
    VoidCallback? onRescan,
  }) {
    if (tracks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: tokens.surfaceColor,
                  borderRadius: BorderRadius.circular(tokens.radiusLg),
                  border: Border.all(
                    color: isScanning
                        ? tokens.accentColor.withValues(alpha: 0.45)
                        : tokens.borderColor,
                  ),
                ),
                alignment: Alignment.center,
                child: SoneaLogoMark(
                  size: 42,
                  upperColor: tokens.textColor.withValues(alpha: 0.8),
                  lowerColor: tokens.accentColor,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                isScanning
                    ? strings.scanningLiveCounter(processedCount, totalCount)
                    : strings.noMusicFound,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isScanning ? FontWeight.w700 : FontWeight.w500,
                  fontFeatures: kTabularFigures,
                  color: isScanning ? tokens.textColor : tokens.subtextColor,
                ),
              ),
              if (!isScanning && onRescan != null) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: tokens.accentColor,
                    foregroundColor: tokens.onAccentColor,
                  ),
                  onPressed: onRescan,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(
                    strings.isTurkish ? 'Müzikleri Tara' : 'Scan Music',
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final appSettings = ref.watch(appSettingsProvider);
    final itemHeight = appSettings.trackRowHeight;
    final artworkSize = appSettings.trackArtworkSize;
    final coverRadius = tokens.radiusSm;
    final isMultiSelecting = _selectedTrackIds.isNotEmpty;
    final showScroller = !isMultiSelecting && tokens.showAlphabetScroller;
    final currentPlayingId = ref.watch(
      playbackControllerProvider.select((s) => s.value?.currentTrack?.id.toInt()),
    );

    String formatDuration(int? ms) {
      if (ms == null || ms <= 0) return '';
      final seconds = (ms / 1000).round();
      final mins = seconds ~/ 60;
      final secs = seconds % 60;
      return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }

    return Stack(
      children: [
        Row(
          children: [
            Expanded(
              child: ListView.builder(
                key: const Key('library_tracks_listview'),
                controller: _tracksScrollController,
                padding: const EdgeInsets.only(bottom: 180),
                itemExtent: itemHeight,
                itemCount: tracks.length,
                itemBuilder: (itemContext, index) {
                  final track = tracks[index];
                  final trackId = track.id.toInt();
                  final isSelected = _selectedTrackIds.contains(trackId);
                  final isCurrentPlaying = trackId == currentPlayingId;
                  final coverPath = track.coverPath;
                  final format = track.format;

                  return RepaintBoundary(
                    child: InkWell(
                      onTap: () {
                        if (isMultiSelecting) {
                          setState(() {
                            if (isSelected) {
                              _selectedTrackIds.remove(trackId);
                            } else {
                              _selectedTrackIds.add(trackId);
                            }
                          });
                          ref
                              .read(navigationBackProvider.notifier)
                              .setLibraryUiState(
                                multiSelectActive: _selectedTrackIds.isNotEmpty,
                              );
                        } else {
                          ref
                              .read(playbackControllerProvider.notifier)
                              .playTrackList(tracks, index);
                        }
                      },
                      onLongPress: () {
                        setState(() {
                          _selectedTrackIds.add(trackId);
                        });
                        ref
                            .read(navigationBackProvider.notifier)
                            .setLibraryUiState(multiSelectActive: true);
                      },
                      child: Container(
                        height: itemHeight,
                        padding: EdgeInsets.fromLTRB(
                          16,
                          4,
                          showScroller ? 4 : 12,
                          4,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? tokens.accentColor.withValues(alpha: 0.18)
                              : (isCurrentPlaying
                                  ? tokens.accentColor.withValues(alpha: 0.10)
                                  : Colors.transparent),
                        ),
                        child: Row(
                          children: [
                            if (isMultiSelecting)
                              Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Icon(
                                  isSelected
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                                  color: isSelected
                                      ? tokens.accentColor
                                      : tokens.subtextColor,
                                  size: 20,
                                ),
                              ),
                            ArtworkThumbnail(
                              coverPath: coverPath,
                              size: artworkSize,
                              tokens: tokens,
                              radius: coverRadius,
                              cacheWidth: 160,
                              borderColor: isCurrentPlaying
                                  ? tokens.accentColor
                                  : tokens.borderColor.withValues(alpha: 0.5),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14.5,
                                      letterSpacing: -0.2,
                                      fontWeight: isCurrentPlaying
                                          ? FontWeight.bold
                                          : FontWeight.w600,
                                      color: (isSelected || isCurrentPlaying)
                                          ? tokens.accentColor
                                          : tokens.textColor,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    [track.artist, track.album]
                                        .whereType<String>()
                                        .where((s) => s.isNotEmpty)
                                        .join(' • '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w400,
                                      color: tokens.subtextColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (format != null &&
                                format.isNotEmpty &&
                                tokens.showFormatBadges)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                margin: const EdgeInsets.only(left: 4),
                                decoration: BoxDecoration(
                                  color: tokens.surfaceColor,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: tokens.subtextColor
                                        .withValues(alpha: 0.2),
                                  ),
                                ),
                                child: Text(
                                  format,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: kTabularFigures,
                                    color: tokens.accentColor,
                                  ),
                                ),
                              ),
                            if (tokens.showTrackDuration &&
                                track.durationMs != null &&
                                track.durationMs! > 0)
                              Padding(
                                padding:
                                    const EdgeInsets.only(left: 8, right: 2),
                                child: Text(
                                  formatDuration(track.durationMs),
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontFeatures: const [
                                      ui.FontFeature.tabularFigures(),
                                    ],
                                    color: tokens.subtextColor,
                                  ),
                                ),
                              ),
                            if (!isMultiSelecting)
                              SizedBox(
                                width: 32,
                                height: 36,
                                child: PopupMenuButton<String>(
                                  padding: EdgeInsets.zero,
                                  icon: Icon(
                                    Icons.more_vert,
                                    color: tokens.subtextColor,
                                    size: 19,
                                  ),
                                onSelected: (val) {
                                  if (!mounted) return;
                                  if (val == 'play_next') {
                                    ref
                                        .read(playbackControllerProvider
                                            .notifier)
                                        .playNext(track);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(strings.playNextAdded),
                                      ),
                                    );
                                  } else if (val == 'add_queue') {
                                    ref
                                        .read(playbackControllerProvider
                                            .notifier)
                                        .addToQueue(track);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(strings.addedToQueue),
                                      ),
                                    );
                                  } else if (val == 'add_favorites') {
                                    _addTracksToFavorites([track], strings);
                                  } else if (val == 'edit_metadata') {
                                    showDialog<void>(
                                      context: context,
                                      builder: (_) =>
                                          MetadataEditorDialog(track: track),
                                    );
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'play_next',
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.playlist_play_rounded,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(strings.playNext),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'add_queue',
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.queue_rounded,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(strings.addToQueue),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'add_favorites',
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.favorite_rounded,
                                          size: 18,
                                          color: Colors.redAccent,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(strings.addToFavorites),
                                      ],
                                    ),
                                  ),
                                    PopupMenuItem(
                                      value: 'edit_metadata',
                                      child: Row(
                                        children: [
                                          const Icon(Icons.edit_note, size: 18),
                                          const SizedBox(width: 8),
                                          Text(strings.editMetadataTitle),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            // Dedicated non-overlapping Right Gutter for A-Z Alphabet Scroller
            if (showScroller)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 6, 6, 168),
                child: SizedBox(
                  key: const Key('alphabet_scroller_strip'),
                  width: 30,
                  child: LayoutBuilder(
                    builder: (_, constraints) {
                      void processTouch(Offset localPos) {
                        if (constraints.maxHeight <= 0) return;
                        final itemH =
                            constraints.maxHeight / _alphabet.length;
                        final idx = (localPos.dy / itemH)
                            .floor()
                            .clamp(0, _alphabet.length - 1);
                        final letter = _alphabet[idx];
                        if (_draggedLetter != letter) {
                          setState(() => _draggedLetter = letter);
                          _jumpToAlphabetLetter(letter, tracks, itemHeight);
                        }
                      }

                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragStart: (d) =>
                            processTouch(d.localPosition),
                        onVerticalDragUpdate: (d) =>
                            processTouch(d.localPosition),
                        onVerticalDragEnd: (_) =>
                            setState(() => _draggedLetter = null),
                        onVerticalDragCancel: () =>
                            setState(() => _draggedLetter = null),
                        onTapDown: (d) {
                          processTouch(d.localPosition);
                          Future.delayed(const Duration(milliseconds: 500), () {
                            if (mounted) setState(() => _draggedLetter = null);
                          });
                        },
                        child: Column(
                          children: _alphabet.map((letter) {
                            final isSelected = _draggedLetter == letter;
                            return Expanded(
                              child: Center(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    letter,
                                    style: TextStyle(
                                      fontSize: isSelected ? 11.5 : 9.0,
                                      height: 1.0,
                                      fontWeight: isSelected
                                          ? FontWeight.bold
                                          : FontWeight.w600,
                                      color: isSelected
                                          ? tokens.accentColor
                                          : tokens.subtextColor,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),

        // Floating Letter Bubble Indicator while Scrubbing
        if (_draggedLetter != null)
          IgnorePointer(
            child: Center(
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: tokens.accentColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 12,
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Text(
                  _draggedLetter!,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: tokens.onAccentColor,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildAlbumsGrid(
    List<rust.Track> tracks,
    SoneaThemeTokens tokens,
    AppStrings strings,
  ) {
    final byAlbum = <String, List<rust.Track>>{};
    for (final t in tracks) {
      final name = (t.album != null && t.album!.trim().isNotEmpty)
          ? t.album!.trim()
          : strings.unknownAlbum;
      byAlbum.putIfAbsent(name, () => []).add(t);
    }
    if (byAlbum.isEmpty) {
      return Center(
        child: Text(
          strings.noAlbumsFound,
          style: TextStyle(color: tokens.subtextColor),
        ),
      );
    }

    final albumEntries = byAlbum.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));

    return LayoutBuilder(
      builder: (_, constraints) {
        final cols = constraints.maxWidth >= 720
            ? 4
            : (constraints.maxWidth >= 520 ? 3 : 2);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 180),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 0.78,
          ),
          itemCount: albumEntries.length,
          itemBuilder: (_, index) {
            final entry = albumEntries[index];
            final albumTracks = entry.value;
            String? coverPath;
            for (final t in albumTracks) {
              if (ArtworkThumbnail.isValidCoverFile(t.coverPath)) {
                coverPath = t.coverPath;
                break;
              }
            }
            final artistName = albumTracks
                .map((t) => t.albumArtist ?? t.artist)
                .firstWhere(
                  (a) => a != null && a.trim().isNotEmpty,
                  orElse: () => strings.unknownArtist,
                )!;
            final trackLabel = strings.trackCountLabel(albumTracks.length);

            return RepaintBoundary(
              child: InkWell(
                borderRadius: BorderRadius.circular(tokens.radiusMd),
                onTap: () {
                  ref.read(libraryProvider.notifier).search(entry.key);
                  _tabController.animateTo(0);
                },
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: tokens.surfaceColor,
                    borderRadius: BorderRadius.circular(tokens.radiusMd),
                    border: Border.all(
                      color: tokens.borderColor.withValues(alpha: 0.65),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (_, box) {
                            final side = box.maxWidth < box.maxHeight
                                ? box.maxWidth
                                : box.maxHeight;
                            return Center(
                              child: ArtworkThumbnail(
                                coverPath: coverPath,
                                size: side,
                                tokens: tokens,
                                radius: tokens.radiusMd,
                                cacheWidth: 320,
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        entry.key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: tokens.textColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$artistName • $trackLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: tokens.subtextColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildArtistsList(
    List<rust.Track> tracks,
    SoneaThemeTokens tokens,
    AppStrings strings,
  ) {
    final byArtist = <String, List<rust.Track>>{};
    for (final t in tracks) {
      final name = (t.artist != null && t.artist!.trim().isNotEmpty)
          ? t.artist!.trim()
          : strings.unknownArtist;
      byArtist.putIfAbsent(name, () => []).add(t);
    }
    if (byArtist.isEmpty) {
      return Center(
        child: Text(
          strings.noArtistsFound,
          style: TextStyle(color: tokens.subtextColor),
        ),
      );
    }

    final artistEntries = byArtist.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 180),
      itemExtent: 76,
      itemCount: artistEntries.length,
      itemBuilder: (_, index) {
        final entry = artistEntries[index];
        final artistTracks = entry.value;
        final covers = extractUniqueCovers(
          artistTracks
              .map((t) => t.coverPath)
              .where(ArtworkThumbnail.isValidCoverFile),
          maxCount: 4,
        );
        final albumsCount = artistTracks
            .map((t) => (t.album ?? '').trim())
            .where((a) => a.isNotEmpty)
            .toSet()
            .length;
        final subtitle = albumsCount > 0
            ? '${strings.albumCountLabel(albumsCount)} • ${strings.trackCountLabel(artistTracks.length)}'
            : strings.trackCountLabel(artistTracks.length);
        final initial =
            entry.key.trim().isNotEmpty ? entry.key.trim()[0].toUpperCase() : '?';

        return RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(tokens.radiusMd),
              onTap: () {
                ref.read(libraryProvider.notifier).search(entry.key);
                _tabController.animateTo(0);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: tokens.surfaceColor,
                  borderRadius: BorderRadius.circular(tokens.radiusMd),
                  border: Border.all(
                    color: tokens.borderColor.withValues(alpha: 0.6),
                  ),
                ),
                child: Row(
                  children: [
                    if (covers.isNotEmpty)
                      PlaylistArtworkCollage(
                        coverPaths: covers,
                        size: 50,
                        tokens: tokens,
                        radius: tokens.radiusSm,
                      )
                    else
                      Container(
                        width: 50,
                        height: 50,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: tokens.accentColor.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(tokens.radiusSm),
                          border: Border.all(
                            color: tokens.accentColor.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Text(
                          initial,
                          style: tokens.displayStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: tokens.accentColor,
                          ),
                        ),
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.key,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color: tokens.textColor,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
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
                    Icon(Icons.chevron_right_rounded, color: tokens.subtextColor),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CreatePlaylistNameDialog extends StatefulWidget {
  const _CreatePlaylistNameDialog({
    required this.defaultName,
    required this.strings,
  });

  final String defaultName;
  final AppStrings strings;

  @override
  State<_CreatePlaylistNameDialog> createState() =>
      _CreatePlaylistNameDialogState();
}

class _CreatePlaylistNameDialogState extends State<_CreatePlaylistNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.defaultName);
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
    return AlertDialog(
      title: Text(widget.strings.newPlaylist),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(hintText: widget.strings.playlistName),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.strings.close),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.strings.create),
        ),
      ],
    );
  }
}
