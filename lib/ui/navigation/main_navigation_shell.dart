import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/library/library_controller.dart' show libraryProvider;
import 'package:sonea/playback/playback_controller.dart'
    show widgetOpenNowPlayingProvider;
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/theme/theme_controller.dart';
import 'package:sonea/ui/library/library_tab.dart';
import 'package:sonea/ui/mini_player/floating_mini_player.dart';
import 'package:sonea/ui/navigation/navigation_back_controller.dart';
import 'package:sonea/ui/now_playing/now_playing_screen.dart';
import 'package:sonea/ui/playlists/playlists_tab.dart';
import 'package:sonea/ui/settings/settings_tab.dart';

class MainNavigationShell extends ConsumerStatefulWidget {
  const MainNavigationShell({super.key});

  @override
  ConsumerState<MainNavigationShell> createState() =>
      _MainNavigationShellState();
}

class _MainNavigationShellState extends ConsumerState<MainNavigationShell> {
  bool _initializedStartupTab = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_initializedStartupTab && mounted) {
        _initializedStartupTab = true;
        final tokens = ref.read(themeControllerProvider);
        final nav = ref.read(navigationBackProvider.notifier);
        if (tokens.startupTab == 0) {
          nav.initializeRootTab(0);
        } else if (tokens.startupTab == 1) {
          nav.initializeRootTab(1);
        } else if (tokens.startupTab == 2) {
          nav.initializeRootTab(0);
          ref.read(libraryProvider.notifier).setTab(3);
        }
      }
    });
  }

  static const _pages = [
    LibraryTab(),
    PlaylistsTab(),
    SettingsTab(),
  ];

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(widgetOpenNowPlayingProvider, (prev, next) {
      if (prev != null && next > prev && mounted) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const NowPlayingScreen()),
        );
      }
    });

    final strings = ref.watch(stringsProvider);
    final tokens = SoneaThemeTokens.of(context);
    final navState = ref.watch(navigationBackProvider);
    final navNotifier = ref.read(navigationBackProvider.notifier);

    return PopScope(
      canPop: navState.canPopApp,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final poppedSubTab = navNotifier.handleBackPress();
        if (poppedSubTab != null) {
          ref.read(libraryProvider.notifier).setTab(poppedSubTab);
        }
      },
      child: Scaffold(
        backgroundColor: tokens.backgroundColor,
        body: Stack(
          children: [
            IndexedStack(
              index: navState.currentTab,
              children: _pages,
            ),

            // Mini player + Floating Pill Dock at bottom
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const FloatingMiniPlayer(),

                    // Floating Minimalist Icon Dock
                    Container(
                      key: const Key('floating_nav_dock'),
                      margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: tokens.surfaceColor,
                        borderRadius: BorderRadius.circular(tokens.radiusLg),
                        border: Border.all(
                          color: tokens.borderColor.withValues(alpha: 0.7),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: tokens.isLight ? 0.06 : 0.18,
                            ),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          _buildNavItem(
                            index: 0,
                            currentIndex: navState.currentTab,
                            icon: Icons.library_music_outlined,
                            activeIcon: Icons.library_music_rounded,
                            label: strings.tabLibrary,
                            tokens: tokens,
                            onTap: () => navNotifier.selectTab(0),
                          ),
                          _buildNavItem(
                            index: 1,
                            currentIndex: navState.currentTab,
                            icon: Icons.queue_music_outlined,
                            activeIcon: Icons.queue_music_rounded,
                            label: strings.tabPlaylists,
                            tokens: tokens,
                            onTap: () => navNotifier.selectTab(1),
                          ),
                          _buildNavItem(
                            index: 2,
                            currentIndex: navState.currentTab,
                            icon: Icons.settings_outlined,
                            activeIcon: Icons.settings_rounded,
                            label: strings.tabSettings,
                            tokens: tokens,
                            onTap: () => navNotifier.selectTab(2),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required int index,
    required int currentIndex,
    required IconData icon,
    required IconData activeIcon,
    required String label,
    required SoneaThemeTokens tokens,
    required VoidCallback onTap,
  }) {
    final isSelected = currentIndex == index;

    return Expanded(
      child: Semantics(
        selected: isSelected,
        button: true,
        label: label,
        child: Tooltip(
          message: label,
          child: GestureDetector(
            key: Key('nav_tab_$index'),
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                width: 64,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected
                      ? tokens.accentColor.withValues(alpha: 0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(tokens.radiusPill),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isSelected ? activeIcon : icon,
                      size: 23,
                      color:
                          isSelected ? tokens.accentColor : tokens.subtextColor,
                    ),
                    const SizedBox(height: 3),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      width: isSelected ? 14 : 0,
                      height: 2.5,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? tokens.accentColor
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
