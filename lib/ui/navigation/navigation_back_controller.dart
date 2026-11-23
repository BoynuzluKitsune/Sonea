import 'package:flutter_riverpod/flutter_riverpod.dart';

class NavigationBackState {
  const NavigationBackState({
    this.currentTab = 1,
    this.rootTab = 1,
    this.tabHistory = const [],
    this.librarySubTabHistory = const [],
    this.librarySearchOpen = false,
    this.libraryMultiSelectActive = false,
    this.libraryFolderDetailOpen = false,
    this.playlistDetailOpen = false,
    this.settingsSearchActive = false,
    this.backActionNonce = 0,
    this.lastBackAction,
  });

  final int currentTab;
  final int rootTab;
  final List<int> tabHistory;
  final List<int> librarySubTabHistory;
  final bool librarySearchOpen;
  final bool libraryMultiSelectActive;
  final bool libraryFolderDetailOpen;
  final bool playlistDetailOpen;
  final bool settingsSearchActive;
  final int backActionNonce;
  final String? lastBackAction;

  /// True only when the user is at the root tab with no open in-tab overlays,
  /// details, or tab/sub-tab history — allowing Android Predictive Back to exit.
  bool get canPopApp {
    if (currentTab == 0) {
      if (libraryMultiSelectActive ||
          librarySearchOpen ||
          libraryFolderDetailOpen ||
          librarySubTabHistory.isNotEmpty) {
        return false;
      }
    } else if (currentTab == 1) {
      if (playlistDetailOpen) return false;
    } else if (currentTab == 2) {
      if (settingsSearchActive) return false;
    }
    if (tabHistory.isNotEmpty) return false;
    return currentTab == rootTab;
  }

  NavigationBackState copyWith({
    int? currentTab,
    int? rootTab,
    List<int>? tabHistory,
    List<int>? librarySubTabHistory,
    bool? librarySearchOpen,
    bool? libraryMultiSelectActive,
    bool? libraryFolderDetailOpen,
    bool? playlistDetailOpen,
    bool? settingsSearchActive,
    int? backActionNonce,
    String? lastBackAction,
  }) {
    return NavigationBackState(
      currentTab: currentTab ?? this.currentTab,
      rootTab: rootTab ?? this.rootTab,
      tabHistory: tabHistory ?? this.tabHistory,
      librarySubTabHistory: librarySubTabHistory ?? this.librarySubTabHistory,
      librarySearchOpen: librarySearchOpen ?? this.librarySearchOpen,
      libraryMultiSelectActive:
          libraryMultiSelectActive ?? this.libraryMultiSelectActive,
      libraryFolderDetailOpen:
          libraryFolderDetailOpen ?? this.libraryFolderDetailOpen,
      playlistDetailOpen: playlistDetailOpen ?? this.playlistDetailOpen,
      settingsSearchActive: settingsSearchActive ?? this.settingsSearchActive,
      backActionNonce: backActionNonce ?? this.backActionNonce,
      lastBackAction: lastBackAction ?? this.lastBackAction,
    );
  }
}

final navigationBackProvider =
    NotifierProvider<NavigationBackController, NavigationBackState>(
  NavigationBackController.new,
);

class NavigationBackController extends Notifier<NavigationBackState> {
  static const _maxHistory = 12;

  @override
  NavigationBackState build() => const NavigationBackState();

  void initializeRootTab(int tab) {
    final safe = tab.clamp(0, 2);
    state = state.copyWith(
      currentTab: safe,
      rootTab: safe,
      tabHistory: const [],
    );
  }

  void selectTab(int nextTab) {
    final safe = nextTab.clamp(0, 2);
    if (safe == state.currentTab) return;
    final history = List<int>.from(state.tabHistory)..add(state.currentTab);
    if (history.length > _maxHistory) {
      history.removeRange(0, history.length - _maxHistory);
    }
    state = state.copyWith(
      currentTab: safe,
      tabHistory: history,
    );
  }

  void recordLibrarySubTabChange(int fromSubTab, int toSubTab) {
    if (fromSubTab == toSubTab) return;
    final history = List<int>.from(state.librarySubTabHistory);
    if (history.isEmpty || history.last != fromSubTab) {
      history.add(fromSubTab);
      if (history.length > _maxHistory) {
        history.removeRange(0, history.length - _maxHistory);
      }
      state = state.copyWith(librarySubTabHistory: history);
    }
  }

  void setLibraryUiState({
    bool? searchOpen,
    bool? multiSelectActive,
    bool? folderDetailOpen,
  }) {
    state = state.copyWith(
      librarySearchOpen: searchOpen,
      libraryMultiSelectActive: multiSelectActive,
      libraryFolderDetailOpen: folderDetailOpen,
    );
  }

  void setPlaylistDetailOpen(bool open) {
    if (state.playlistDetailOpen == open) return;
    state = state.copyWith(playlistDetailOpen: open);
  }

  void setSettingsSearchActive(bool active) {
    if (state.settingsSearchActive == active) return;
    state = state.copyWith(settingsSearchActive: active);
  }

  /// Handles a system back press/gesture in strict priority order:
  /// 1. Close active modal/search/multi-select in current tab.
  /// 2. Close in-tab detail view (folder or playlist detail).
  /// 3. Pop in-tab sub-tab history (Library Tracks/Albums/Artists/Folders).
  /// 4. Pop main bottom-bar tab history, or return to rootTab.
  /// Returns the popped Library sub-tab index if a sub-tab pop occurred.
  int? handleBackPress() {
    // Priority 1 & 2: Current tab overlays & details
    if (state.currentTab == 0) {
      if (state.libraryMultiSelectActive) {
        state = state.copyWith(
          libraryMultiSelectActive: false,
          backActionNonce: state.backActionNonce + 1,
          lastBackAction: 'close_library_multiselect',
        );
        return null;
      }
      if (state.librarySearchOpen) {
        state = state.copyWith(
          librarySearchOpen: false,
          backActionNonce: state.backActionNonce + 1,
          lastBackAction: 'close_library_search',
        );
        return null;
      }
      if (state.libraryFolderDetailOpen) {
        state = state.copyWith(
          libraryFolderDetailOpen: false,
          backActionNonce: state.backActionNonce + 1,
          lastBackAction: 'close_library_folder',
        );
        return null;
      }
      // Priority 3a: Library sub-tab history
      if (state.librarySubTabHistory.isNotEmpty) {
        final history = List<int>.from(state.librarySubTabHistory);
        final prevSubTab = history.removeLast();
        state = state.copyWith(
          librarySubTabHistory: history,
          backActionNonce: state.backActionNonce + 1,
          lastBackAction: 'pop_library_subtab:$prevSubTab',
        );
        return prevSubTab;
      }
    } else if (state.currentTab == 1 && state.playlistDetailOpen) {
      state = state.copyWith(
        playlistDetailOpen: false,
        backActionNonce: state.backActionNonce + 1,
        lastBackAction: 'close_playlist_detail',
      );
      return null;
    } else if (state.currentTab == 2 && state.settingsSearchActive) {
      state = state.copyWith(
        settingsSearchActive: false,
        backActionNonce: state.backActionNonce + 1,
        lastBackAction: 'close_settings_search',
      );
      return null;
    }

    // Priority 3b: Main navigation tab history
    if (state.tabHistory.isNotEmpty) {
      final history = List<int>.from(state.tabHistory);
      final prevTab = history.removeLast();
      state = state.copyWith(
        currentTab: prevTab,
        tabHistory: history,
        backActionNonce: state.backActionNonce + 1,
        lastBackAction: 'pop_main_tab:$prevTab',
      );
      return null;
    }

    // Priority 3c: Return to root tab if not already there
    if (state.currentTab != state.rootTab) {
      state = state.copyWith(
        currentTab: state.rootTab,
        backActionNonce: state.backActionNonce + 1,
        lastBackAction: 'return_root_tab:${state.rootTab}',
      );
      return null;
    }

    return null;
  }
}
