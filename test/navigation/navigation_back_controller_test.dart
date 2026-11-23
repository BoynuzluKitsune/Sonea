import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonea/ui/navigation/navigation_back_controller.dart';

void main() {
  group('NavigationBackController priority back-stack', () {
    test('handles in-tab overlays, details, sub-tabs, and main tab history in strict order', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final ctrl = container.read(navigationBackProvider.notifier);
      ctrl.initializeRootTab(1); // Playlists is root
      expect(container.read(navigationBackProvider).canPopApp, isTrue);

      // Navigate to Library (0), then sub-tabs 0 -> 1 -> 2, open folder, search, multi-select
      ctrl.selectTab(0);
      ctrl.recordLibrarySubTabChange(0, 1);
      ctrl.recordLibrarySubTabChange(1, 2);
      ctrl.setLibraryUiState(
        folderDetailOpen: true,
        searchOpen: true,
        multiSelectActive: true,
      );
      expect(container.read(navigationBackProvider).canPopApp, isFalse);

      // 1. Multi-select closes first
      ctrl.handleBackPress();
      expect(container.read(navigationBackProvider).libraryMultiSelectActive, isFalse);
      expect(container.read(navigationBackProvider).librarySearchOpen, isTrue);

      // 2. Search closes second
      ctrl.handleBackPress();
      expect(container.read(navigationBackProvider).librarySearchOpen, isFalse);
      expect(container.read(navigationBackProvider).libraryFolderDetailOpen, isTrue);

      // 3. Folder detail closes third
      ctrl.handleBackPress();
      expect(container.read(navigationBackProvider).libraryFolderDetailOpen, isFalse);

      // 4. Library sub-tab history pops (2 -> 1 -> 0)
      expect(ctrl.handleBackPress(), 1);
      expect(ctrl.handleBackPress(), 0);
      expect(container.read(navigationBackProvider).librarySubTabHistory, isEmpty);

      // 5. Main tab history pops back to Playlists (1)
      ctrl.handleBackPress();
      expect(container.read(navigationBackProvider).currentTab, 1);
      expect(container.read(navigationBackProvider).canPopApp, isTrue);
    });

    test('closes playlist detail before exiting from root tab', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final ctrl = container.read(navigationBackProvider.notifier);
      ctrl.initializeRootTab(1);
      ctrl.setPlaylistDetailOpen(true);
      expect(container.read(navigationBackProvider).canPopApp, isFalse);

      ctrl.handleBackPress();
      expect(container.read(navigationBackProvider).playlistDetailOpen, isFalse);
      expect(container.read(navigationBackProvider).canPopApp, isTrue);
    });
  });
}
