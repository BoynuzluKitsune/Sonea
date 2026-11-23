import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/theme/theme_controller.dart';

/// Shared 3-segment independent brightness selector (`System | Light | Dark`).
class ThemeBrightnessModeBar extends ConsumerWidget {
  const ThemeBrightnessModeBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = SoneaThemeTokens.of(context);
    final themeMode = ref.watch(
      themeControllerProvider.select((s) => s.themeMode),
    );
    final themeController = ref.read(themeControllerProvider.notifier);
    final strings = ref.watch(stringsProvider);

    return Container(
      key: const Key('theme_mode_selector_bar'),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: tokens.surfaceColor,
        borderRadius: BorderRadius.circular(tokens.radiusPill),
        border: Border.all(
          color: tokens.borderColor.withValues(alpha: 0.75),
        ),
      ),
      child: Row(
        children: [
          _segment(
            key: const Key('theme_mode_btn_system'),
            label: strings.modeSystem,
            icon: Icons.brightness_auto_rounded,
            selected: themeMode == ThemeMode.system,
            tokens: tokens,
            onTap: () => themeController.setThemeMode(ThemeMode.system),
          ),
          _segment(
            key: const Key('theme_mode_btn_light'),
            label: strings.modeLight,
            icon: Icons.light_mode_rounded,
            selected: themeMode == ThemeMode.light,
            tokens: tokens,
            onTap: () => themeController.setThemeMode(ThemeMode.light),
          ),
          _segment(
            key: const Key('theme_mode_btn_dark'),
            label: strings.modeDark,
            icon: Icons.dark_mode_rounded,
            selected: themeMode == ThemeMode.dark,
            tokens: tokens,
            onTap: () => themeController.setThemeMode(ThemeMode.dark),
          ),
        ],
      ),
    );
  }

  Widget _segment({
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
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? tokens.accentColor.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(tokens.radiusPill),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected ? tokens.accentColor : tokens.subtextColor,
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
                    color: selected ? tokens.accentColor : tokens.subtextColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dedicated full-screen 2-column gallery for all 10 Sanzo Wada 4-color palettes
/// with live Dark / Light / System mode switching.
class ThemeGalleryScreen extends ConsumerWidget {
  const ThemeGalleryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = SoneaThemeTokens.of(context);
    final themeController = ref.read(themeControllerProvider.notifier);
    final strings = ref.watch(stringsProvider);
    final activeBrightness = Theme.of(context).brightness;

    return Scaffold(
      backgroundColor: tokens.backgroundColor,
      appBar: AppBar(
        backgroundColor: tokens.backgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: tokens.textColor),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          strings.themeGalleryTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tokens.displayStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            color: tokens.textColor,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ThemeBrightnessModeBar(),
                  const SizedBox(height: 8),
                  Text(
                    strings.themeCollectionSubtitle,
                    style: tokens.bodyStyle(
                      fontSize: 12,
                      color: tokens.subtextColor,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GridView.builder(
                key: const Key('wada_theme_gallery_grid'),
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 32),
                itemCount: SoneaThemePalette.all.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  mainAxisExtent: 162,
                ),
                itemBuilder: (_, index) {
                  final palette = SoneaThemePalette.all[index];
                  final preview = palette.forBrightness(activeBrightness);
                  final isSelected = palette.id == tokens.packId;

                  return RepaintBoundary(
                    child: InkWell(
                      key: Key('wada_theme_card_${palette.id}'),
                      borderRadius: BorderRadius.circular(tokens.radiusMd),
                      onTap: () => themeController.selectPack(palette.id),
                      child: Container(
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: preview.backgroundColor,
                          borderRadius: BorderRadius.circular(tokens.radiusMd),
                          border: Border.all(
                            color: isSelected
                                ? preview.accentColor
                                : preview.borderColor,
                            width: isSelected ? 2.2 : 1.0,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 4-Color Sanzo Wada Swatch Bar
                            ClipRRect(
                              borderRadius: BorderRadius.circular(
                                tokens.radiusSm.clamp(2.0, 8.0),
                              ),
                              child: Container(
                                height: 22,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: preview.borderColor
                                        .withValues(alpha: 0.8),
                                    width: 0.75,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    for (final swatch
                                        in palette.paletteSwatches)
                                      Expanded(
                                        child: Container(color: swatch),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),

                            // Plate Number + Active Checkmark
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: preview.surfaceColor,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: preview.borderColor
                                          .withValues(alpha: 0.7),
                                    ),
                                  ),
                                  child: Text(
                                    palette.wadaNumber,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      fontFeatures: kTabularFigures,
                                      color: preview.accentColor,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                if (isSelected)
                                  Icon(
                                    Icons.check_circle_rounded,
                                    size: 17,
                                    color: preview.accentColor,
                                  ),
                              ],
                            ),
                            const Spacer(),

                            // Theme Title in its own Display Font
                            Text(
                              strings.themeName(palette.id),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: preview.displayStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                                color: preview.textColor,
                              ),
                            ),
                            const SizedBox(height: 3),

                            // Localized Poetic / Editorial Mood Subtitle
                            Text(
                              strings.themeMood(palette.id),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: preview.bodyStyle(
                                fontSize: 10.5,
                                height: 1.22,
                                color: preview.subtextColor,
                              ),
                            ),
                            const SizedBox(height: 4),

                            // Bespoke Typography Pairing Caption
                            Text(
                              palette.fontPairingLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w600,
                                color:
                                    preview.accentColor.withValues(alpha: 0.9),
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
          ],
        ),
      ),
    );
  }
}
