import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:sonea/core/app_logger.dart';
import 'package:sonea/core/app_paths.dart';
import 'package:sonea/core/backup_validator.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/library/library_controller.dart' show libraryProvider;
import 'package:sonea/library/library_filter_controller.dart';
import 'package:sonea/playback/lyrics_controller.dart';
import 'package:sonea/playback/replay_gain_controller.dart';
import 'package:sonea/playback/sleep_timer_controller.dart';
import 'package:sonea/settings/app_settings_controller.dart';
import 'package:sonea/src/rust/api/backup.dart' as rust_backup;
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/theme/theme_controller.dart';
import 'package:sonea/ui/components/equalizer_dialog.dart';
import 'package:sonea/ui/navigation/navigation_back_controller.dart';
import 'package:sonea/ui/onboarding/onboarding_screen.dart';
import 'package:sonea/ui/settings/theme_gallery_screen.dart';

class SettingsTab extends ConsumerStatefulWidget {
  const SettingsTab({super.key});

  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab> {
  final _searchController = TextEditingController();
  String _filter = '';

  int _coverCacheBytes = 0;
  int _coverCacheFiles = 0;
  int _dbBytes = 0;
  bool _storageLoading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshStorageStats());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matches(String query) {
    if (_filter.trim().isEmpty) return true;
    return query.toLowerCase().contains(_filter.trim().toLowerCase());
  }

  Future<void> _refreshStorageStats() async {
    if (_storageLoading) return;
    if (mounted) setState(() => _storageLoading = true);
    try {
      final dbPath = await AppPaths.databasePath();
      final coversPath = await AppPaths.coversDir();

      int dbSize = 0;
      final dbFile = File(dbPath);
      if (dbFile.existsSync()) {
        dbSize = dbFile.lengthSync();
      }
      final walFile = File('$dbPath-wal');
      if (walFile.existsSync()) {
        dbSize += walFile.lengthSync();
      }

      int coverBytes = 0;
      int coverFiles = 0;
      final coversDir = Directory(coversPath);
      if (coversDir.existsSync()) {
        for (final entity in coversDir.listSync(recursive: true)) {
          if (entity is File) {
            coverFiles++;
            coverBytes += entity.lengthSync();
          }
        }
      }

      if (mounted) {
        setState(() {
          _dbBytes = dbSize;
          _coverCacheBytes = coverBytes;
          _coverCacheFiles = coverFiles;
          _storageLoading = false;
        });
      }
    } catch (e) {
      appLog('SettingsTab', '_refreshStorageStats failed: $e');
      if (mounted) setState(() => _storageLoading = false);
    }
  }

  Future<void> _clearCoverCache(AppStrings strings) async {
    try {
      final coversPath = await AppPaths.coversDir();
      final coversDir = Directory(coversPath);
      if (coversDir.existsSync()) {
        await coversDir.delete(recursive: true);
        await coversDir.create(recursive: true);
      }
      PaintingBinding.instance.imageCache.clear();
      await _refreshStorageStats();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              strings.isTurkish
                  ? 'Kapak önbelleği temizlendi.'
                  : 'Cover cache cleared.',
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

  List<File> _collectBackupJsonFiles(
    List<Directory> dirs,
    String nameFragment,
  ) {
    final seen = <String>{};
    final matched = <File>[];
    for (final dir in dirs) {
      if (!seen.add(dir.path)) continue;
      try {
        if (!dir.existsSync()) continue;
        for (final entity in dir.listSync(followLinks: false)) {
          if (entity is File) {
            final name = p.basename(entity.path);
            if (name.endsWith('.json') && name.contains(nameFragment)) {
              matched.add(entity);
            }
          }
        }
      } catch (e) {
        appLog('SettingsTab', 'Skipping unreadable backup dir', e);
      }
    }
    matched.sort((a, b) {
      try {
        return b.lastModifiedSync().compareTo(a.lastModifiedSync());
      } catch (e) {
        appLog('SettingsTab', 'Backup mtime compare failed', e);
        return 0;
      }
    });
    return matched;
  }

  Future<void> _exportBackup(AppStrings strings) async {
    try {
      final dbPath = await AppPaths.databasePath();
      final targetDir = await AppPaths.backupsDir();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final file = File(p.join(targetDir, 'sonea_backup_$ts.json'));

      await rust_backup.exportBackupJson(
        dbPath: dbPath,
        outputFilePath: file.path,
      );

      // Also bundle app settings alongside the exported JSON backup.
      final settingsFile = File(p.join(targetDir, 'sonea_settings_$ts.json'));
      await settingsFile.writeAsString(
        jsonEncode(ref.read(appSettingsProvider).toJson()),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${strings.backupSuccess}: ${p.basename(file.path)}'),
          ),
        );
      }
    } catch (e, st) {
      appLog('SettingsTab', '_exportBackup failed', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _importBackup(AppStrings strings) async {
    try {
      final dbPath = await AppPaths.databasePath();
      final primaryBackupDir = Directory(await AppPaths.backupsDir());
      final supportDir = File(dbPath).parent;
      final searchDirs = <Directory>[
        primaryBackupDir,
        Directory(p.join(supportDir.path, 'backups')),
        supportDir,
        Directory('/sdcard/Download'),
      ];

      final jsonFiles = _collectBackupJsonFiles(searchDirs, 'sonea_backup');

      if (jsonFiles.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                strings.isTurkish
                    ? 'Yedek dosyası bulunamadı.'
                    : 'No backup file found.',
              ),
            ),
          );
        }
        return;
      }

      // Enforce strict size and JSON schema validation before Rust restore.
      await BackupValidator.validateLibraryBackupFile(jsonFiles.first);

      await rust_backup.importBackupJson(
        dbPath: dbPath,
        inputFilePath: jsonFiles.first.path,
      );

      // Immediately refresh library state once the database restore commits.
      ref.invalidate(libraryProvider);

      // Restore companion settings file if present and valid (best-effort).
      final settingsFiles =
          _collectBackupJsonFiles(searchDirs, 'sonea_settings');
      if (settingsFiles.isNotEmpty) {
        try {
          final sanitized =
              await BackupValidator.validateAndSanitizeSettingsFile(
            settingsFiles.first,
          );
          if (sanitized.isNotEmpty) {
            await ref.read(appSettingsProvider.notifier).applyJson(sanitized);
          }
        } catch (e, st) {
          appLog('SettingsTab', 'Companion settings restore skipped', e, st);
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.restoreSuccess)),
        );
      }
    } catch (e, st) {
      appLog('SettingsTab', '_importBackup failed', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> _showAddExcludedFolderDialog(
    AppStrings strings,
    LibraryFilterController filterController,
  ) async {
    final path = await showDialog<String>(
      context: context,
      builder: (_) => _FolderPathDialog(isTurkish: strings.isTurkish),
    );
    if (path != null && path.trim().isNotEmpty && mounted) {
      await filterController.addExcludedFolder(path.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      navigationBackProvider.select((s) => s.backActionNonce),
      (_, _) {
        final action = ref.read(navigationBackProvider).lastBackAction;
        if (action == 'close_settings_search' && mounted) {
          setState(() {
            _filter = '';
            _searchController.clear();
          });
        }
      },
    );

    final strings = ref.watch(stringsProvider);
    final isTr = strings.isTurkish;
    final currentLang = ref.watch(appLanguageProvider);
    final langNotifier = ref.read(appLanguageProvider.notifier);

    final tokens = SoneaThemeTokens.of(context);
    final themeController = ref.read(themeControllerProvider.notifier);

    final appSettings = ref.watch(appSettingsProvider);
    final settingsCtrl = ref.read(appSettingsProvider.notifier);

    final rgState = ref.watch(replayGainControllerProvider);
    final rgController = ref.read(replayGainControllerProvider.notifier);

    final filterState = ref.watch(libraryFilterProvider);
    final filterController = ref.read(libraryFilterProvider.notifier);

    final timerState = ref.watch(sleepTimerControllerProvider);
    final timerController = ref.read(sleepTimerControllerProvider.notifier);

    final lyricsState = ref.watch(lyricsControllerProvider);
    final lyricsNotifier = ref.read(lyricsControllerProvider.notifier);

    final libraryState = ref.watch(libraryProvider).value;

    return Scaffold(
      backgroundColor: tokens.backgroundColor,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 180),
          children: [
            Text(
              strings.settingsTitle,
              style: tokens.displayStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.6,
                color: tokens.textColor,
              ),
            ),
            const SizedBox(height: 14),

            // Settings Search Bar
            SizedBox(
              height: 44,
              child: TextField(
                controller: _searchController,
                style: TextStyle(color: tokens.textColor, fontSize: 14),
                decoration: InputDecoration(
                  hintText: strings.searchSettings,
                  hintStyle: TextStyle(
                    color: tokens.subtextColor,
                    fontSize: 14,
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    color: tokens.subtextColor,
                    size: 20,
                  ),
                  suffixIcon: _filter.isNotEmpty
                      ? IconButton(
                          icon: Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: tokens.subtextColor,
                          ),
                          onPressed: () {
                            setState(() {
                              _filter = '';
                              _searchController.clear();
                            });
                            ref
                                .read(navigationBackProvider.notifier)
                                .setSettingsSearchActive(false);
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: tokens.surfaceColor,
                  contentPadding: EdgeInsets.zero,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(tokens.radiusPill),
                      borderSide: BorderSide(color: tokens.borderColor),
                    ),
                ),
                onChanged: (v) {
                  setState(() => _filter = v);
                  ref
                      .read(navigationBackProvider.notifier)
                      .setSettingsSearchActive(v.trim().isNotEmpty);
                },
              ),
            ),
            const SizedBox(height: 22),

            // ================================================================
            // 1. GÖRÜNÜM (Appearance & Sanzo Wada 4-Color Themes)
            // ================================================================
            if (_matches(strings.sectionAppearance) ||
                _matches(strings.themePacksSection) ||
                _matches(strings.themeGalleryTitle) ||
                _matches('sanzo wada haishoku harf kaydırıcı alphabet density font')) ...[
              _buildSectionHeader(
                strings.sectionAppearance,
                Icons.palette_outlined,
                tokens,
              ),
              const SizedBox(height: 10),

              // 1. Independent Brightness Mode Selector (System | Light | Dark)
              const ThemeBrightnessModeBar(),
              const SizedBox(height: 10),

              // 2. Active Sanzo Wada Theme Entry Card -> opens ThemeGalleryScreen
              Builder(
                builder: (context) {
                  final activePalette =
                      SoneaThemePalette.findById(tokens.packId);
                  return InkWell(
                    key: const Key('settings_open_theme_gallery_card'),
                    borderRadius: BorderRadius.circular(tokens.radiusMd),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ThemeGalleryScreen(),
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(
                        color: tokens.surfaceColor,
                        borderRadius: BorderRadius.circular(tokens.radiusMd),
                        border: Border.all(
                          color: tokens.borderColor.withValues(alpha: 0.78),
                        ),
                      ),
                      child: Row(
                        children: [
                          // 4-Color Wada Swatch Column/Bar
                          ClipRRect(
                            borderRadius: BorderRadius.circular(
                              tokens.radiusSm.clamp(3.0, 10.0),
                            ),
                            child: Container(
                              width: 56,
                              height: 44,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color:
                                      tokens.borderColor.withValues(alpha: 0.8),
                                  width: 0.75,
                                ),
                              ),
                              child: Row(
                                children: [
                                  for (final swatch
                                      in activePalette.paletteSwatches)
                                    Expanded(child: Container(color: swatch)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 1.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: tokens.elevatedSurfaceColor,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: tokens.borderColor
                                              .withValues(alpha: 0.7),
                                        ),
                                      ),
                                      child: Text(
                                        activePalette.wadaNumber,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          fontFeatures: kTabularFigures,
                                          color: tokens.accentColor,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        strings.themeGalleryTitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: tokens.subtextColor,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  strings.themeName(activePalette.id),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: tokens.displayStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.2,
                                    color: tokens.textColor,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  activePalette.fontPairingLabel,
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
                          const SizedBox(width: 8),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: tokens.subtextColor,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),

              _buildSettingsCard(
                tokens: tokens,
                children: [
                  // A-Z Fast Alphabet Scroller toggle
                  SwitchListTile(
                    key: const Key('settings_alphabet_scroller_switch'),
                    title: Text(
                      isTr
                          ? 'A–Z Hızlı Harf Kaydırıcısı'
                          : 'A–Z Fast Alphabet Scroller',
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      isTr
                          ? 'Şarkı listesinin sağ kenarında hızlı harf çubuğunu göster'
                          : 'Show fast A–Z letter jump bar on the right edge of tracks',
                      style: TextStyle(
                        color: tokens.subtextColor,
                        fontSize: 12,
                      ),
                    ),
                    value: tokens.showAlphabetScroller,
                    activeThumbColor: tokens.accentColor,
                    onChanged: (v) =>
                        themeController.setShowAlphabetScroller(v),
                  ),
                  _divider(tokens),

                  // List Density
                  _buildSegmentedTile<ListDensity>(
                    title: isTr ? 'Liste Yoğunluğu' : 'List Density',
                    tokens: tokens,
                    value: appSettings.listDensity,
                    options: [
                      (ListDensity.compact, isTr ? 'Kompakt' : 'Compact'),
                      (ListDensity.normal, 'Normal'),
                      (ListDensity.comfortable, isTr ? 'Rahat' : 'Comfortable'),
                    ],
                    onChanged: (v) {
                      settingsCtrl.setListDensity(v);
                      themeController
                          .setCompactListMode(v == ListDensity.compact);
                    },
                  ),
                  _divider(tokens),

                  // Text Scale
                  _buildSegmentedTile<AppTextScale>(
                    title: isTr ? 'Yazı Boyutu Ölçeği' : 'Text Size Scale',
                    tokens: tokens,
                    value: appSettings.textScale,
                    options: [
                      (AppTextScale.small, isTr ? 'Küçük' : 'Small'),
                      (AppTextScale.normal, 'Normal'),
                      (AppTextScale.large, isTr ? 'Büyük' : 'Large'),
                    ],
                    onChanged: settingsCtrl.setTextScale,
                  ),
                  _divider(tokens),

                  // Cover Corner Style (affects cards, covers, mini-player, dialogs, sheets)
                  _buildSegmentedTile<SoneaCornerStyle>(
                    title: isTr ? 'Köşe Stili' : 'Corner Style',
                    tokens: tokens,
                    value: tokens.cornerStyle,
                    options: [
                      (SoneaCornerStyle.sharp, isTr ? 'Keskin' : 'Sharp'),
                      (SoneaCornerStyle.soft, isTr ? 'Yumuşak' : 'Soft'),
                      (SoneaCornerStyle.rounded, isTr ? 'Yuvarlak' : 'Rounded'),
                    ],
                    onChanged: (v) {
                      themeController.setCornerStyle(v);
                      settingsCtrl.setCoverCornerStyle(switch (v) {
                        SoneaCornerStyle.sharp => CoverCornerStyle.sharp,
                        SoneaCornerStyle.soft => CoverCornerStyle.soft,
                        SoneaCornerStyle.rounded => CoverCornerStyle.rounded,
                      });
                    },
                  ),
                  _divider(tokens),

                  // Now Playing Background Effect
                  _buildSegmentedTile<NowPlayingBgEffect>(
                    title: isTr
                        ? 'Now Playing Arka Plan Efekti'
                        : 'Now Playing Background Effect',
                    tokens: tokens,
                    value: appSettings.nowPlayingBgEffect,
                    options: [
                      (NowPlayingBgEffect.off, isTr ? 'Kapalı' : 'Off'),
                      (
                        NowPlayingBgEffect.subtle,
                        isTr ? 'Hafif Parlama' : 'Subtle Glow',
                      ),
                      (NowPlayingBgEffect.rich, isTr ? 'Zengin' : 'Rich'),
                    ],
                    onChanged: (v) {
                      settingsCtrl.setNowPlayingBgEffect(v);
                      themeController.setUseDynamicCoverGlow(
                        v != NowPlayingBgEffect.off,
                      );
                    },
                  ),
                  _divider(tokens),

                  // Format Badges
                  SwitchListTile(
                    title: Text(
                      isTr
                          ? 'Teknik Ses Formatı Rozeti'
                          : 'Audio Format Badges',
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      isTr
                          ? 'FLAC, MP3, OPUS gibi format rozetlerini listelerde göster'
                          : 'Show FLAC, MP3, OPUS format tags on track rows',
                      style: TextStyle(
                        color: tokens.subtextColor,
                        fontSize: 12,
                      ),
                    ),
                    value: tokens.showFormatBadges,
                    activeThumbColor: tokens.accentColor,
                    onChanged: themeController.setShowFormatBadges,
                  ),
                  _divider(tokens),

                  // Startup Tab
                  _buildSegmentedTile<int>(
                    title: isTr ? 'Başlangıç Sekmesi' : 'Startup Tab',
                    tokens: tokens,
                    value: tokens.startupTab == 0 ? 0 : 1,
                    options: [
                      (0, strings.tabLibrary),
                      (1, strings.tabPlaylists),
                    ],
                    onChanged: themeController.setStartupTab,
                  ),
                  _divider(tokens),

                  // Language
                  ListTile(
                    title: Text(
                      isTr ? 'Dil' : 'Language',
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    trailing: DropdownButton<AppLanguage>(
                      value: currentLang,
                      underline: const SizedBox.shrink(),
                      dropdownColor: tokens.surfaceColor,
                      items: const [
                        DropdownMenuItem(
                          value: AppLanguage.tr,
                          child: Text('Türkçe'),
                        ),
                        DropdownMenuItem(
                          value: AppLanguage.en,
                          child: Text('English'),
                        ),
                      ],
                      onChanged: (lang) {
                        if (lang != null) langNotifier.setLanguage(lang);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
            ],

            // ================================================================
            // 2. OYNATMA & SES (Playback & Audio)
            // ================================================================
            if (_matches(isTr ? 'oynatma ses' : 'playback audio') ||
                _matches('replaygain bluetooth speed equalizer sleep')) ...[
              _buildSectionHeader(
                isTr ? 'Oynatma & Ses' : 'Playback & Audio',
                Icons.headphones_rounded,
                tokens,
              ),
              const SizedBox(height: 10),
              _buildSettingsCard(
                tokens: tokens,
                children: [
                  // Gapless Playback
                  SwitchListTile(
                    title: Text(
                      strings.gaplessPlaybackTitle,
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      strings.gaplessPlaybackSubtitle,
                      style: TextStyle(
                        color: tokens.subtextColor,
                        fontSize: 12,
                      ),
                    ),
                    value: appSettings.gaplessPlayback,
                    activeThumbColor: tokens.accentColor,
                    onChanged: settingsCtrl.setGaplessPlayback,
                  ),
                  _divider(tokens),

                  // ReplayGain Mode
                  _buildSegmentedTile<ReplayGainMode>(
                    title: isTr
                        ? 'Ses Normalleştirme (ReplayGain)'
                        : 'Volume Normalization (ReplayGain)',
                    tokens: tokens,
                    value: rgState.mode,
                    options: [
                      (ReplayGainMode.off, isTr ? 'Kapalı' : 'Off'),
                      (ReplayGainMode.track, isTr ? 'Parça' : 'Track'),
                      (ReplayGainMode.album, isTr ? 'Albüm' : 'Album'),
                    ],
                    onChanged: rgController.setMode,
                  ),
                  _divider(tokens),

                  // Pause on headphone / Bluetooth disconnect
                  SwitchListTile(
                    title: Text(
                      isTr
                          ? 'Kulaklık / Bluetooth Çıkarılınca Duraklat'
                          : 'Pause on Headphone / Bluetooth Disconnect',
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    value: appSettings.pauseOnNoisy,
                    activeThumbColor: tokens.accentColor,
                    onChanged: settingsCtrl.setPauseOnNoisy,
                  ),
                  _divider(tokens),

                  // Interruption behavior (Duck / Pause)
                  _buildSegmentedTile<AudioInterruptionBehavior>(
                    title: isTr
                        ? 'Bildirim / Ses Kesintisi Davranışı'
                        : 'Audio Interruption Behavior',
                    tokens: tokens,
                    value: appSettings.interruptionBehavior,
                    options: [
                      (
                        AudioInterruptionBehavior.duck,
                        isTr ? 'Sesi Kıs (Duck)' : 'Duck Volume',
                      ),
                      (
                        AudioInterruptionBehavior.pause,
                        isTr ? 'Duraklat' : 'Pause',
                      ),
                    ],
                    onChanged: settingsCtrl.setInterruptionBehavior,
                  ),
                  _divider(tokens),

                  // Skip Forward / Backward Duration
                  _buildSegmentedTile<int>(
                    title: isTr
                        ? 'İleri / Geri Atlama Süresi'
                        : 'Seek Skip Interval',
                    tokens: tokens,
                    value: appSettings.skipSeconds,
                    options: [
                      (5, isTr ? '5 sn' : '5s'),
                      (10, isTr ? '10 sn' : '10s'),
                      (15, isTr ? '15 sn' : '15s'),
                      (30, isTr ? '30 sn' : '30s'),
                    ],
                    onChanged: settingsCtrl.setSkipSeconds,
                  ),
                  _divider(tokens),

                  // Default Playback Speed
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                isTr
                                    ? 'Varsayılan Oynatma Hızı'
                                    : 'Default Playback Speed',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: tokens.textColor,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${appSettings.playbackSpeed.toStringAsFixed(2)}x',
                              style: TextStyle(
                                color: tokens.accentColor,
                                fontWeight: FontWeight.w700,
                                fontFeatures: kTabularFigures,
                              ),
                            ),
                          ],
                        ),
                        Slider(
                          value: appSettings.playbackSpeed,
                          min: 0.75,
                          max: 2.0,
                          divisions: 25,
                          activeColor: tokens.accentColor,
                          onChanged: settingsCtrl.setPlaybackSpeed,
                        ),
                      ],
                    ),
                  ),
                  _divider(tokens),

                  // Equalizer Quick Access
                  ListTile(
                    leading: Icon(Icons.equalizer_rounded,
                        color: tokens.accentColor),
                    title: Text(
                      strings.equalizerTitle,
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      color: tokens.subtextColor,
                    ),
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (_) => const EqualizerDialog(),
                    ),
                  ),
                  _divider(tokens),

                  // Sleep Timer Quick Access (layout-safe stacked chips)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.bedtime_outlined,
                              size: 20,
                              color: timerState.isActive
                                  ? tokens.accentColor
                                  : tokens.subtextColor,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                strings.sleepTimerTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: tokens.textColor,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              timerState.isActive
                                  ? (timerState.isEndOfTrack
                                      ? strings.sleepEndOfTrack
                                      : strings.sleepMinutes(
                                          ((timerState.remainingSeconds ?? 0) /
                                                  60)
                                              .ceil(),
                                        ))
                                  : strings.modeOff,
                              style: TextStyle(
                                color: timerState.isActive
                                    ? tokens.accentColor
                                    : tokens.subtextColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                fontFeatures: kTabularFigures,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            if (timerState.isActive)
                              OutlinedButton.icon(
                                onPressed: timerController.cancelTimer,
                                icon: const Icon(Icons.close_rounded, size: 16),
                                label: Text(strings.cancelTimer),
                              )
                            else ...[
                              for (final mins in const [15, 30, 60])
                                ActionChip(
                                  label: Text(
                                    isTr ? '$mins dk' : '${mins}m',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontFeatures: kTabularFigures,
                                    ),
                                  ),
                                  onPressed: () =>
                                      timerController.startTimer(mins),
                                ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
            ],

            // ================================================================
            // 3. KÜTÜPHANE & TARAMA (Library & Scanning)
            // ================================================================
            if (_matches(isTr ? 'kütüphane tarama klasör' : 'library scan folder') ||
                _matches('duration filter excluded')) ...[
              _buildSectionHeader(
                isTr ? 'Kütüphane & Tarama' : 'Library & Scanning',
                Icons.library_music_outlined,
                tokens,
              ),
              const SizedBox(height: 10),
              _buildSettingsCard(
                tokens: tokens,
                children: [
                  // Minimum Track Duration Filter
                  _buildSegmentedTile<int>(
                    title: isTr
                        ? 'Minimum Parça Süresi Filtresi'
                        : 'Minimum Track Duration Filter',
                    tokens: tokens,
                    value: filterState.minTrackDurationSec,
                    options: [
                      (0, isTr ? 'Kapalı' : 'Off'),
                      (15, isTr ? '15 sn' : '15s'),
                      (30, isTr ? '30 sn' : '30s'),
                      (60, isTr ? '60 sn' : '60s'),
                    ],
                    onChanged: filterController.setMinDurationSec,
                  ),
                  _divider(tokens),

                  // Auto-scan on startup
                  SwitchListTile(
                    title: Text(
                      isTr
                          ? 'Açılışta Otomatik Hızlı Tarama'
                          : 'Auto Quick Scan on Startup',
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    value: appSettings.autoScanOnStartup,
                    activeThumbColor: tokens.accentColor,
                    onChanged: settingsCtrl.setAutoScanOnStartup,
                  ),
                  _divider(tokens),

                  // Excluded folders (blacklist)
                  ListTile(
                    title: Text(
                      isTr
                          ? 'Hariç Tutulan Klasörler (Kara Liste)'
                          : 'Excluded Folders (Blacklist)',
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      filterState.excludedFolders.isEmpty
                          ? (isTr
                              ? 'WhatsApp Audio, Notifications vb. gizlemek için ekle'
                              : 'Add folders like WhatsApp Audio or Ringtones to hide')
                          : strings.foldersHiddenLabel(
                              filterState.excludedFolders.length,
                            ),
                      style: TextStyle(
                        color: tokens.subtextColor,
                        fontSize: 12,
                      ),
                    ),
                    trailing: IconButton(
                      icon: Icon(Icons.add_rounded, color: tokens.accentColor),
                      onPressed: () =>
                          _showAddExcludedFolderDialog(strings, filterController),
                    ),
                  ),
                  if (filterState.excludedFolders.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: filterState.excludedFolders.map((folder) {
                          return InputChip(
                            label: Text(
                              folder,
                              style: const TextStyle(fontSize: 11.5),
                            ),
                            onDeleted: () =>
                                filterController.removeExcludedFolder(folder),
                          );
                        }).toList(),
                      ),
                    ),
                  _divider(tokens),

                  // Manual Quick Scan & Full Rescan
                  ListTile(
                    leading: Icon(Icons.sync_rounded, color: tokens.accentColor),
                    title: Text(
                      isTr ? 'Kütüphaneyi Tara' : 'Scan Library',
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      libraryState?.scanning == true
                          ? strings.scanProgress(
                              libraryState!.processed,
                              libraryState.total,
                              libraryState.unreadable,
                            )
                          : (libraryState?.error ??
                              strings.tracksIndexedLabel(
                                libraryState?.tracks.length ?? 0,
                              )),
                      style: TextStyle(
                        color: libraryState?.error != null
                            ? Theme.of(context).colorScheme.error
                            : tokens.subtextColor,
                        fontSize: 12,
                      ),
                    ),
                    trailing: Wrap(
                      spacing: 6,
                      children: [
                        FilledButton.tonal(
                          onPressed: libraryState?.scanning == true
                              ? null
                              : () => ref.read(libraryProvider.notifier).scan(),
                          child: Text(isTr ? 'Hızlı Tara' : 'Quick Scan'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
            ],

            // ================================================================
            // 4. ŞARKI SÖZLERİ (Lyrics)
            // ================================================================
            if (_matches(isTr ? 'şarkı sözleri lyrics kanji' : 'lyrics transliteration scroll')) ...[
              _buildSectionHeader(
                isTr ? 'Şarkı Sözleri' : 'Lyrics',
                Icons.lyrics_outlined,
                tokens,
              ),
              const SizedBox(height: 10),
              _buildSettingsCard(
                tokens: tokens,
                children: [
                  _buildSegmentedTile<LyricsFontSize>(
                    title: isTr ? 'Söz Yazı Boyutu' : 'Lyrics Font Size',
                    tokens: tokens,
                    value: appSettings.lyricsFontSize,
                    options: [
                      (LyricsFontSize.small, isTr ? 'Küçük' : 'Small'),
                      (LyricsFontSize.medium, isTr ? 'Orta' : 'Medium'),
                      (LyricsFontSize.large, isTr ? 'Büyük' : 'Large'),
                    ],
                    onChanged: settingsCtrl.setLyricsFontSize,
                  ),
                  _divider(tokens),
                  _buildSegmentedTile<LyricsAlignment>(
                    title: isTr ? 'Söz Hizalama' : 'Lyrics Alignment',
                    tokens: tokens,
                    value: appSettings.lyricsAlignment,
                    options: [
                      (LyricsAlignment.left, isTr ? 'Sol' : 'Left'),
                      (LyricsAlignment.center, isTr ? 'Orta' : 'Center'),
                    ],
                    onChanged: settingsCtrl.setLyricsAlignment,
                  ),
                  _divider(tokens),
                  SwitchListTile(
                    title: Text(
                      isTr ? 'Otomatik Kaydırma' : 'Auto-Scroll Lyrics',
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    value: appSettings.lyricsAutoScroll,
                    activeThumbColor: tokens.accentColor,
                    onChanged: settingsCtrl.setLyricsAutoScroll,
                  ),
                  _divider(tokens),
                  SwitchListTile(
                    title: Text(
                      strings.autoFetchLyricsTitle,
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      strings.autoFetchLyricsSubtitle,
                      style: TextStyle(
                        color: tokens.subtextColor,
                        fontSize: 12,
                      ),
                    ),
                    value: appSettings.autoFetchLyrics,
                    activeThumbColor: tokens.accentColor,
                    onChanged: settingsCtrl.setAutoFetchLyrics,
                  ),
                  _divider(tokens),
                  SwitchListTile(
                    title: Text(
                      strings.romajiTranslitTitle,
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      strings.romajiTranslitSubtitle,
                      style: TextStyle(
                        color: tokens.subtextColor,
                        fontSize: 12,
                      ),
                    ),
                    value: appSettings.japaneseTransliteration,
                    activeThumbColor: tokens.accentColor,
                    onChanged: (enabled) {
                      settingsCtrl.setJapaneseTransliteration(enabled);
                      lyricsNotifier.setMode(
                        enabled
                            ? TransliterationMode.under
                            : TransliterationMode.off,
                      );
                    },
                  ),
                  _divider(tokens),

                  // Bulk Lyrics Download Section
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.cloud_download_outlined,
                              size: 20,
                              color: tokens.accentColor,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                isTr
                                    ? 'Tüm Şarkı Sözlerini İndir'
                                    : 'Download All Lyrics',
                                style: TextStyle(
                                  color: tokens.textColor,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (lyricsState.coverage != null)
                              Flexible(
                                child: Text(
                                  strings.lyricsCoverageBadge(
                                    lyricsState.coverage!.syncedCount +
                                        lyricsState.coverage!.plainCount,
                                    lyricsState.coverage!.instrumentalCount,
                                    lyricsState.coverage!.totalTracks,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.end,
                                  style: TextStyle(
                                    color: tokens.accentColor,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: kTabularFigures,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        if (lyricsState.isBulkDownloading) ...[
                          LinearProgressIndicator(
                            value: lyricsState.bulkTotal > 0
                                ? (lyricsState.bulkProcessed /
                                        lyricsState.bulkTotal)
                                    .clamp(0.0, 1.0)
                                : null,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              tokens.accentColor,
                            ),
                            backgroundColor:
                                tokens.borderColor.withValues(alpha: 0.4),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            strings.lyricsBulkProgress(
                              lyricsState.bulkProcessed,
                              lyricsState.bulkTotal,
                              lyricsState.bulkSynced + lyricsState.bulkPlain,
                              lyricsState.bulkInstrumental,
                              lyricsState.bulkNotFound,
                            ),
                            style: TextStyle(
                              color: tokens.subtextColor,
                              fontSize: 12,
                              fontFeatures: kTabularFigures,
                            ),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            key: const Key('bulk_lyrics_cancel_btn'),
                            onPressed: lyricsNotifier.cancelBulkDownload,
                            icon: const Icon(Icons.stop_circle_outlined,
                                size: 18),
                            label: Text(strings.cancel),
                          ),
                        ] else ...[
                          Text(
                            lyricsState.bulkTotal > 0
                                ? strings.lyricsBulkLastRun(
                                    lyricsState.bulkProcessed,
                                    lyricsState.bulkTotal,
                                    lyricsState.bulkSynced +
                                        lyricsState.bulkPlain,
                                    lyricsState.bulkInstrumental,
                                    lyricsState.bulkNotFound,
                                  )
                                : strings.lyricsBulkIdleHint,
                            style: TextStyle(
                              color: tokens.subtextColor,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.tonalIcon(
                                key: const Key('bulk_lyrics_start_btn'),
                                onPressed: lyricsNotifier.startBulkDownload,
                                icon: const Icon(
                                  Icons.download_rounded,
                                  size: 18,
                                ),
                                label: Text(
                                  isTr
                                      ? 'Tüm Şarkı Sözlerini İndir'
                                      : 'Download All Lyrics',
                                ),
                              ),
                              OutlinedButton.icon(
                                key: const Key('clear_auto_lyrics_cache_btn'),
                                onPressed: () => _confirmAndClearAutoLyricsCache(
                                  strings: strings,
                                  lyricsNotifier: lyricsNotifier,
                                ),
                                icon: const Icon(
                                  Icons.cleaning_services_outlined,
                                  size: 17,
                                ),
                                label: Text(strings.clearAutoLyricsTitle),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
            ],

            // ================================================================
            // 5. DEPOLAMA & YEDEKLEME (Storage & Backup)
            // ================================================================
            if (_matches(isTr ? 'depolama yedekleme önbellek' : 'storage backup cache')) ...[
              _buildSectionHeader(
                isTr ? 'Depolama & Yedekleme' : 'Storage & Backup',
                Icons.storage_rounded,
                tokens,
              ),
              const SizedBox(height: 10),
              _buildSettingsCard(
                tokens: tokens,
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.image_outlined,
                      color: tokens.accentColor,
                    ),
                    title: Text(
                      isTr ? 'Kapak Önbelleği & Veritabanı' : 'Cover Cache & Database',
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      _storageLoading
                          ? (isTr ? 'Hesaplanıyor...' : 'Calculating...')
                          : (isTr
                              ? 'Kapaklar: ${_formatBytes(_coverCacheBytes)} (${strings.fileCountLabel(_coverCacheFiles)}) • DB: ${_formatBytes(_dbBytes)}'
                              : 'Covers: ${_formatBytes(_coverCacheBytes)} (${strings.fileCountLabel(_coverCacheFiles)}) • DB: ${_formatBytes(_dbBytes)}'),
                      style: TextStyle(
                        color: tokens.subtextColor,
                        fontSize: 12,
                        fontFeatures: kTabularFigures,
                      ),
                    ),
                    trailing: IconButton(
                      icon: Icon(
                        Icons.refresh_rounded,
                        size: 20,
                        color: tokens.subtextColor,
                      ),
                      onPressed: _refreshStorageStats,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _clearCoverCache(strings),
                            icon: const Icon(Icons.cleaning_services_outlined,
                                size: 17),
                            label: Text(
                              isTr
                                  ? 'Kapak Önbelleğini Temizle'
                                  : 'Clear Cover Cache',
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _divider(tokens),
                  ListTile(
                    leading: Icon(Icons.upload_file_rounded,
                        color: tokens.accentColor),
                    title: Text(
                      isTr ? 'Yedek Dışa Aktar (JSON)' : 'Export Backup (JSON)',
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      isTr
                          ? 'Çalma listeleri ve uygulama ayarlarını JSON olarak dışa aktar'
                          : 'Export playlists and app settings as JSON',
                      style: TextStyle(
                        color: tokens.subtextColor,
                        fontSize: 12,
                      ),
                    ),
                    onTap: () => _exportBackup(strings),
                  ),
                  _divider(tokens),
                  ListTile(
                    leading: Icon(Icons.download_rounded,
                        color: tokens.accentColor),
                    title: Text(
                      isTr ? 'Yedekten Geri Yükle (JSON)' : 'Import Backup (JSON)',
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      isTr
                          ? 'Son JSON yedeğinden çalma listelerini ve ayarları geri yükle'
                          : 'Restore playlists and settings from latest JSON backup',
                      style: TextStyle(
                        color: tokens.subtextColor,
                        fontSize: 12,
                      ),
                    ),
                    onTap: () => _importBackup(strings),
                  ),
                ],
              ),
              const SizedBox(height: 22),
            ],

            // ================================================================
            // 6. GENEL VE KURULUM (General & Setup Actions)
            // ================================================================
            if (_matches(strings.sectionGeneralSetup) ||
                _matches(strings.rerunSetupWizardTitle) ||
                _matches(strings.resetDefaultsTitle) ||
                _matches('wizard onboarding reset default kurulum sıfırla')) ...[
              _buildSectionHeader(
                strings.sectionGeneralSetup,
                Icons.tune_rounded,
                tokens,
              ),
              const SizedBox(height: 10),
              _buildSettingsCard(
                tokens: tokens,
                children: [
                  ListTile(
                    key: const Key('settings_rerun_wizard_tile'),
                    leading: Icon(
                      Icons.auto_awesome_outlined,
                      color: tokens.accentColor,
                    ),
                    title: Text(
                      strings.rerunSetupWizardTitle,
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      strings.rerunSetupWizardSubtitle,
                      style: TextStyle(
                        color: tokens.subtextColor,
                        fontSize: 12,
                      ),
                    ),
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      color: tokens.subtextColor,
                    ),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (routeContext) => OnboardingScreen(
                            onCompleted: () {
                              if (Navigator.of(routeContext).canPop()) {
                                Navigator.of(routeContext).pop();
                              }
                            },
                          ),
                        ),
                      );
                    },
                  ),
                  _divider(tokens),
                  ListTile(
                    key: const Key('settings_reset_defaults_tile'),
                    leading: Icon(
                      Icons.restart_alt_rounded,
                      color: tokens.accentColor,
                    ),
                    title: Text(
                      strings.resetDefaultsTitle,
                      style: TextStyle(
                        color: tokens.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      strings.resetDefaultsSubtitle,
                      style: TextStyle(
                        color: tokens.subtextColor,
                        fontSize: 12,
                      ),
                    ),
                    onTap: () => _confirmAndResetDefaults(
                      strings: strings,
                      langNotifier: langNotifier,
                      themeController: themeController,
                      settingsCtrl: settingsCtrl,
                      filterController: filterController,
                      rgController: rgController,
                      lyricsNotifier: lyricsNotifier,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmAndResetDefaults({
    required AppStrings strings,
    required AppLanguageNotifier langNotifier,
    required ThemeController themeController,
    required AppSettingsController settingsCtrl,
    required LibraryFilterController filterController,
    required ReplayGainController rgController,
    required LyricsController lyricsNotifier,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.resetDefaultsDialogTitle),
        content: Text(strings.resetDefaultsDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('settings_reset_confirm_btn'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.resetDefaultsConfirm),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    await Future.wait([
      langNotifier.resetToSystemDefault(),
      themeController.resetToDefaults(),
      settingsCtrl.resetToDefaults(),
      filterController.resetToDefaults(),
      rgController.resetToDefaults(),
    ]);
    lyricsNotifier.setMode(TransliterationMode.under);

    if (mounted) {
      final updatedStrings = ref.read(stringsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(updatedStrings.resetDefaultsSuccess)),
      );
    }
  }

  Future<void> _confirmAndClearAutoLyricsCache({
    required AppStrings strings,
    required LyricsController lyricsNotifier,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.clearAutoLyricsDialogTitle),
        content: Text(strings.clearAutoLyricsDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('clear_auto_lyrics_confirm_btn'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.clearAutoLyricsConfirm),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final cleared = await lyricsNotifier.clearAutoCache();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.clearAutoLyricsSuccess(cleared))),
        );
      }
    } catch (e, st) {
      appLog('SettingsTab', '_confirmAndClearAutoLyricsCache failed', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Widget _divider(SoneaThemeTokens tokens) => Divider(
        height: 1,
        indent: 16,
        endIndent: 16,
        color: tokens.borderColor.withValues(alpha: 0.5),
      );

  Widget _buildSettingsCard({
    required SoneaThemeTokens tokens,
    required List<Widget> children,
  }) {
    return Material(
      color: tokens.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        side: BorderSide(color: tokens.borderColor.withValues(alpha: 0.7)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _buildSegmentedTile<T>({
    required String title,
    required SoneaThemeTokens tokens,
    required T value,
    required List<(T, String)> options,
    required ValueChanged<T> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: tokens.textColor,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: options.map((opt) {
              final selected = opt.$1 == value;
              return ChoiceChip(
                label: Text(opt.$2),
                selected: selected,
                selectedColor: tokens.accentColor.withValues(alpha: 0.22),
                labelStyle: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? tokens.accentColor : tokens.textColor,
                ),
                side: BorderSide(
                  color: selected
                      ? tokens.accentColor
                      : tokens.borderColor.withValues(alpha: 0.7),
                ),
                onSelected: (_) => onChanged(opt.$1),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(
    String title,
    IconData icon,
    SoneaThemeTokens tokens,
  ) {
    return Row(
      children: [
        Icon(icon, size: 18, color: tokens.accentColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.displayStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: tokens.textColor,
            ),
          ),
        ),
      ],
    );
  }
}

class _FolderPathDialog extends StatefulWidget {
  const _FolderPathDialog({required this.isTurkish});

  final bool isTurkish;

  @override
  State<_FolderPathDialog> createState() => _FolderPathDialogState();
}

class _FolderPathDialogState extends State<_FolderPathDialog> {
  final _controller = TextEditingController(
    text: '/storage/emulated/0/Notifications',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.isTurkish ? 'Klasör Hariç Tut' : 'Exclude Folder',
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: '/storage/emulated/0/WhatsApp/Media/WhatsApp Audio',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.isTurkish ? 'İptal' : 'Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(widget.isTurkish ? 'Ekle' : 'Add'),
        ),
      ],
    );
  }
}
