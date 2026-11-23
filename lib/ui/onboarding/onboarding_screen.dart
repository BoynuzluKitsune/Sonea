import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/library/library_controller.dart'
    show LibraryState, libraryProvider;
import 'package:sonea/library/library_filter_controller.dart';
import 'package:sonea/playback/lyrics_controller.dart';
import 'package:sonea/playback/replay_gain_controller.dart';
import 'package:sonea/settings/app_settings_controller.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/theme/theme_controller.dart';
import 'package:sonea/ui/components/sonea_logo_mark.dart';
import 'package:sonea/ui/settings/theme_gallery_screen.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.onCompleted});

  final VoidCallback? onCompleted;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static const int _totalSteps = 4;

  final PageController _pageController = PageController();
  int _step = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goToStep(int next) {
    final target = next.clamp(0, _totalSteps - 1);
    setState(() => _step = target);
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _finish({bool triggerScan = false}) async {
    // Capture notifiers/state BEFORE completeOnboarding() triggers SoneaApp to
    // swap OnboardingScreen out of the widget tree (prevents ref-after-dispose).
    final settingsNotifier = ref.read(appSettingsProvider.notifier);
    final libNotifier = ref.read(libraryProvider.notifier);
    final libState = ref.read(libraryProvider).value;

    if (triggerScan) {
      if (libState?.permission != 'granted') {
        await libNotifier.requestPermission();
      } else if (libState?.scanning != true &&
          (libState?.tracks.isEmpty ?? true)) {
        unawaited(libNotifier.scan());
      }
    }
    await settingsNotifier.completeOnboarding();
    widget.onCompleted?.call();
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final currentLang = ref.watch(appLanguageProvider);
    final langNotifier = ref.read(appLanguageProvider.notifier);

    final tokens = SoneaThemeTokens.of(context);
    final themeCtrl = ref.read(themeControllerProvider.notifier);

    final appSettings = ref.watch(appSettingsProvider);
    final settingsCtrl = ref.read(appSettingsProvider.notifier);

    final filterState = ref.watch(libraryFilterProvider);
    final filterCtrl = ref.read(libraryFilterProvider.notifier);

    final rgState = ref.watch(replayGainControllerProvider);
    final rgCtrl = ref.read(replayGainControllerProvider.notifier);

    final lyricsNotifier = ref.read(lyricsControllerProvider.notifier);
    final libraryState = ref.watch(libraryProvider).value;

    final isLastStep = _step == _totalSteps - 1;
    final showSkip = _step != 1; // Optional Skip on non-permission steps

    return Scaffold(
      backgroundColor: tokens.backgroundColor,
      body: Stack(
        children: [
          // Subtle top ambient gradient anchored to selected Sanzo Wada accent
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 200,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      tokens.accentColor
                          .withValues(alpha: tokens.isLight ? 0.12 : 0.16),
                      tokens.backgroundColor.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                // Top progress bar: 4 animated pills + step count + optional Skip
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 14, 4),
                  child: Row(
                    children: [
                      Row(
                        children: List.generate(_totalSteps, (i) {
                          final active = i == _step;
                          final completed = i < _step;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            margin: const EdgeInsets.only(right: 6),
                            height: 6,
                            width: active ? 26 : 10,
                            decoration: BoxDecoration(
                              color: active
                                  ? tokens.accentColor
                                  : (completed
                                      ? tokens.accentColor
                                          .withValues(alpha: 0.45)
                                      : tokens.borderColor),
                              borderRadius:
                                  BorderRadius.circular(tokens.radiusPill),
                            ),
                          );
                        }),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${_step + 1} / $_totalSteps',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          fontFeatures: kTabularFigures,
                          color: tokens.subtextColor,
                        ),
                      ),
                      const Spacer(),
                      if (showSkip)
                        TextButton(
                          key: const Key('onboarding_skip_btn'),
                          onPressed: () => _finish(triggerScan: false),
                          child: Text(
                            strings.onboardingSkip,
                            style: TextStyle(
                              color: tokens.subtextColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                      else
                        const SizedBox(height: 40),
                    ],
                  ),
                ),

                // 4-Step Wizard PageView
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: (idx) => setState(() => _step = idx),
                    children: [
                      _buildStep1WelcomeAppearance(
                        tokens: tokens,
                        strings: strings,
                        currentLang: currentLang,
                        langNotifier: langNotifier,
                        themeCtrl: themeCtrl,
                      ),
                      _buildStep2PermissionFilter(
                        tokens: tokens,
                        strings: strings,
                        libraryState: libraryState,
                        filterState: filterState,
                        filterCtrl: filterCtrl,
                        themeCtrl: themeCtrl,
                      ),
                      _buildStep3AudioLyrics(
                        tokens: tokens,
                        strings: strings,
                        appSettings: appSettings,
                        settingsCtrl: settingsCtrl,
                        rgState: rgState,
                        rgCtrl: rgCtrl,
                        themeCtrl: themeCtrl,
                        lyricsNotifier: lyricsNotifier,
                      ),
                      _buildStep4Summary(
                        tokens: tokens,
                        strings: strings,
                        appSettings: appSettings,
                        filterState: filterState,
                        rgState: rgState,
                        libraryState: libraryState,
                      ),
                    ],
                  ),
                ),

                // Bottom Navigation Controls
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
                  child: Row(
                    children: [
                      if (_step > 0)
                        OutlinedButton(
                          key: const Key('onboarding_back_btn'),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: tokens.borderColor),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(tokens.radiusMd),
                            ),
                          ),
                          onPressed: () => _goToStep(_step - 1),
                          child: Text(strings.onboardingBack),
                        )
                      else
                        const SizedBox.shrink(),
                      const SizedBox(width: 10),
                      const Spacer(),
                      if (!isLastStep)
                        FilledButton.icon(
                          key: const Key('onboarding_next_btn'),
                          style: FilledButton.styleFrom(
                            backgroundColor: tokens.accentColor,
                            foregroundColor: tokens.onAccentColor,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 13,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(tokens.radiusMd),
                            ),
                          ),
                          onPressed: () => _goToStep(_step + 1),
                          icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                          label: Text(
                            strings.onboardingContinue,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        )
                      else
                        Flexible(
                          child: FilledButton.icon(
                            key: const Key('onboarding_finish_btn'),
                            style: FilledButton.styleFrom(
                              backgroundColor: tokens.accentColor,
                              foregroundColor: tokens.onAccentColor,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 13,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(tokens.radiusMd),
                              ),
                            ),
                            onPressed: () => _finish(triggerScan: true),
                            icon: Icon(
                              (libraryState?.tracks.isNotEmpty ?? false)
                                  ? Icons.play_arrow_rounded
                                  : Icons.library_music_rounded,
                              size: 19,
                            ),
                            label: Text(
                              (libraryState?.tracks.isNotEmpty ?? false)
                                  ? strings.onboardingStartListening
                                  : strings.onboardingScanAndStart,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
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
    );
  }

  // ===========================================================================
  // STEP 1 — Welcome, Language & Appearance
  // ===========================================================================
  Widget _buildStep1WelcomeAppearance({
    required SoneaThemeTokens tokens,
    required AppStrings strings,
    required AppLanguage currentLang,
    required AppLanguageNotifier langNotifier,
    required ThemeController themeCtrl,
  }) {
    final activePalette = SoneaThemePalette.findById(tokens.packId);

    return SingleChildScrollView(
      key: const Key('onboarding_step_0'),
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Compact Brand Header
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(tokens.radiusMd + 2),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      tokens.accentColor.withValues(alpha: 0.36),
                      tokens.borderColor.withValues(alpha: 0.45),
                    ],
                  ),
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: tokens.surfaceColor,
                    borderRadius: BorderRadius.circular(tokens.radiusMd),
                  ),
                  alignment: Alignment.center,
                  child: SoneaLogoMark(
                    size: 32,
                    upperColor: tokens.textColor,
                    lowerColor: tokens.accentColor,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sonea',
                      style: tokens.displayStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.6,
                        color: tokens.textColor,
                      ),
                    ),
                    Text(
                      strings.onboardingTagline,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: tokens.subtextColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Instant Türkçe | English Pill Toggle
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: tokens.surfaceColor,
              borderRadius: BorderRadius.circular(tokens.radiusMd),
              border: Border.all(
                color: tokens.borderColor.withValues(alpha: 0.78),
              ),
            ),
            child: Row(
              children: [
                _buildLangPill(
                  key: const Key('onboarding_lang_tr'),
                  label: strings.languageTR,
                  selected: currentLang == AppLanguage.tr,
                  tokens: tokens,
                  onTap: () => langNotifier.setLanguage(AppLanguage.tr),
                ),
                _buildLangPill(
                  key: const Key('onboarding_lang_en'),
                  label: strings.languageEN,
                  selected: currentLang == AppLanguage.en,
                  tokens: tokens,
                  onTap: () => langNotifier.setLanguage(AppLanguage.en),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // Independent System | Light | Dark Brightness Mode Bar
          const ThemeBrightnessModeBar(),
          const SizedBox(height: 12),

          // Live Compact Mini Player Preview Card
          Container(
            key: const Key('onboarding_preview_card'),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: tokens.surfaceColor,
              borderRadius: BorderRadius.circular(tokens.radiusMd),
              border: Border.all(
                color: tokens.accentColor.withValues(alpha: 0.35),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: tokens.elevatedSurfaceColor,
                          borderRadius: BorderRadius.circular(tokens.radiusSm),
                          border: Border.all(
                            color: tokens.accentColor.withValues(alpha: 0.45),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: SoneaLogoMark(
                          size: 28,
                          upperColor: tokens.textColor,
                          lowerColor: tokens.accentColor,
                        ),
                      ),
                      const SizedBox(width: 10),
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
                                    color: tokens.accentColor
                                        .withValues(alpha: 0.16),
                                    borderRadius: BorderRadius.circular(
                                      tokens.radiusSm,
                                    ),
                                  ),
                                  child: Text(
                                    activePalette.wadaNumber,
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w700,
                                      fontFeatures: kTabularFigures,
                                      color: tokens.accentColor,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    strings.themeName(activePalette.id),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: tokens.subtextColor,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              strings.onboardingPreviewTrack,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tokens.displayStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                                color: tokens.textColor,
                              ),
                            ),
                            Text(
                              strings.onboardingPreviewArtist,
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
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: tokens.accentColor,
                          borderRadius: BorderRadius.circular(tokens.radiusMd),
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: tokens.onAccentColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      flex: 62,
                      child: Container(height: 3, color: tokens.accentColor),
                    ),
                    Expanded(
                      flex: 38,
                      child: Container(
                        height: 3,
                        color: tokens.borderColor.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Compact Interactive 10 Sanzo Wada Palette Picker
          Text(
            strings.themePacksSection,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: tokens.subtextColor,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 120,
            child: ListView.builder(
              key: const Key('onboarding_wada_picker'),
              scrollDirection: Axis.horizontal,
              itemCount: SoneaThemePalette.all.length,
              itemBuilder: (itemContext, index) {
                final palette = SoneaThemePalette.all[index];
                final preview = palette.forBrightness(
                  Theme.of(itemContext).brightness,
                );
                final selected = palette.id == tokens.packId;
                return RepaintBoundary(
                  child: GestureDetector(
                    key: Key('onboarding_wada_card_${palette.id}'),
                    onTap: () => themeCtrl.selectPack(palette.id),
                    child: Container(
                      width: 132,
                      margin: const EdgeInsets.only(right: 10),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: preview.backgroundColor,
                        borderRadius: BorderRadius.circular(tokens.radiusMd),
                        border: Border.all(
                          color: selected
                              ? preview.accentColor
                              : preview.borderColor,
                          width: selected ? 2.2 : 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(5),
                            child: SizedBox(
                              height: 16,
                              child: Row(
                                children: [
                                  for (final swatch in preview.paletteSwatches)
                                    Expanded(child: Container(color: swatch)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                palette.wadaNumber,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: kTabularFigures,
                                  color: preview.accentColor,
                                ),
                              ),
                              if (selected)
                                Icon(
                                  Icons.check_circle_rounded,
                                  size: 16,
                                  color: preview.accentColor,
                                ),
                            ],
                          ),
                          const Spacer(),
                          Text(
                            strings.themeName(palette.id),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: preview.displayStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: preview.textColor,
                            ),
                          ),
                          Text(
                            palette.fontPairingLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9.5,
                              color: preview.subtextColor,
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
    );
  }

  Widget _buildLangPill({
    required Key key,
    required String label,
    required bool selected,
    required SoneaThemeTokens tokens,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(tokens.radiusSm),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected ? tokens.accentColor : Colors.transparent,
            borderRadius: BorderRadius.circular(tokens.radiusSm),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? tokens.onAccentColor : tokens.subtextColor,
            ),
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // STEP 2 — Music Permission & Smart Library Filter
  // ===========================================================================
  Widget _buildStep2PermissionFilter({
    required SoneaThemeTokens tokens,
    required AppStrings strings,
    required LibraryState? libraryState,
    required LibraryFilterState filterState,
    required LibraryFilterController filterCtrl,
    required ThemeController themeCtrl,
  }) {
    final hasPermission = libraryState?.permission == 'granted';
    final isScanning = libraryState?.scanning == true;
    final processed = libraryState?.processed ?? 0;
    final total = libraryState?.total ?? 0;
    final tracksCount = libraryState?.tracks.length ?? 0;
    final showLiveScanCard = isScanning || total > 0 || tracksCount > 0;

    return SingleChildScrollView(
      key: const Key('onboarding_step_1'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            strings.onboardingStep2Title,
            style: tokens.displayStyle(
              fontSize: 23,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: tokens.textColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            strings.onboardingStep2Subtitle,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: tokens.subtextColor,
            ),
          ),
          const SizedBox(height: 16),

          // Audio Permission Card
          Container(
            key: const Key('onboarding_permission_card'),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: tokens.surfaceColor,
              borderRadius: BorderRadius.circular(tokens.radiusMd),
              border: Border.all(
                color: hasPermission
                    ? tokens.accentColor.withValues(alpha: 0.45)
                    : tokens.borderColor,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      hasPermission
                          ? Icons.check_circle_rounded
                          : Icons.folder_open_rounded,
                      color: hasPermission
                          ? tokens.accentColor
                          : tokens.subtextColor,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        hasPermission
                            ? strings.onboardingPermissionGranted
                            : strings.onboardingPermissionPrompt,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: tokens.textColor,
                        ),
                      ),
                    ),
                    if (hasPermission)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: tokens.accentColor.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(tokens.radiusPill),
                        ),
                        child: Text(
                          strings.onboardingPermissionBadgeGranted,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: tokens.accentColor,
                          ),
                        ),
                      ),
                  ],
                ),
                if (!hasPermission) ...[
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const Key('onboarding_grant_permission_btn'),
                    style: FilledButton.styleFrom(
                      backgroundColor: tokens.accentColor,
                      foregroundColor: tokens.onAccentColor,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(tokens.radiusMd),
                      ),
                    ),
                    onPressed: () =>
                        ref.read(libraryProvider.notifier).requestPermission(),
                    icon: const Icon(Icons.lock_open_rounded, size: 18),
                    label: Text(
                      strings.onboardingGrantPermission,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ],
            ),
          ),

          if (showLiveScanCard) ...[
            const SizedBox(height: 12),
            _buildLiveScanCard(
              tokens: tokens,
              strings: strings,
              isScanning: isScanning,
              processed: processed,
              total: total,
              tracksCount: tracksCount,
            ),
          ],

          const SizedBox(height: 14),

          // Short-Audio Filter Segmented Card (Off | 15s | 30s | 60s)
          _buildCard(
            tokens: tokens,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.filter_alt_outlined,
                        size: 18,
                        color: tokens.accentColor,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          strings.onboardingShortAudioTitle,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: tokens.textColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    strings.onboardingShortAudioHint,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: tokens.subtextColor,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildSegmentedRow<int>(
                    tokens: tokens,
                    selected: filterState.minTrackDurationSec,
                    options: [
                      (
                        0,
                        strings.minDurationOff,
                        const Key('onboarding_filter_0'),
                      ),
                      (
                        15,
                        strings.secShort(15),
                        const Key('onboarding_filter_15'),
                      ),
                      (
                        30,
                        strings.secShort(30),
                        const Key('onboarding_filter_30'),
                      ),
                      (
                        60,
                        strings.secShort(60),
                        const Key('onboarding_filter_60'),
                      ),
                    ],
                    onSelected: filterCtrl.setMinDurationSec,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Alphabet Fast-Scroller (# A-Z) Switch
          _buildCard(
            tokens: tokens,
            child: SwitchListTile(
              key: const Key('onboarding_alphabet_switch'),
              title: Text(
                strings.alphabetScrollerTitle,
                style: TextStyle(
                  color: tokens.textColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                strings.alphabetScrollerSubtitle,
                style: TextStyle(color: tokens.subtextColor, fontSize: 12),
              ),
              value: tokens.showAlphabetScroller,
              activeThumbColor: tokens.accentColor,
              onChanged: themeCtrl.setShowAlphabetScroller,
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // STEP 3 — Audio, Visuals & Synced Lyrics
  // ===========================================================================
  Widget _buildStep3AudioLyrics({
    required SoneaThemeTokens tokens,
    required AppStrings strings,
    required AppSettings appSettings,
    required AppSettingsController settingsCtrl,
    required ReplayGainState rgState,
    required ReplayGainController rgCtrl,
    required ThemeController themeCtrl,
    required LyricsController lyricsNotifier,
  }) {
    return SingleChildScrollView(
      key: const Key('onboarding_step_2'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            strings.onboardingStep3Title,
            style: tokens.displayStyle(
              fontSize: 23,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: tokens.textColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            strings.onboardingStep3Subtitle,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: tokens.subtextColor,
            ),
          ),
          const SizedBox(height: 14),

          // Visuals Card: Progress Bar Style + Dynamic Cover Glow
          _buildCard(
            tokens: tokens,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.seekbarTitle,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: tokens.textColor,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildSegmentedRow<ProgressBarStyle>(
                        tokens: tokens,
                        selected: tokens.progressBarStyle,
                        options: [
                          (
                            ProgressBarStyle.thinLine,
                            strings.seekbarLineShort,
                            const Key('onboarding_seekbar_line'),
                          ),
                          (
                            ProgressBarStyle.waveform,
                            strings.seekbarWaveform,
                            const Key('onboarding_seekbar_wave'),
                          ),
                        ],
                        onSelected: themeCtrl.setProgressBarStyle,
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  indent: 14,
                  endIndent: 14,
                  color: tokens.borderColor.withValues(alpha: 0.5),
                ),
                SwitchListTile(
                  key: const Key('onboarding_glow_switch'),
                  title: Text(
                    strings.glowTitle,
                    style: TextStyle(
                      color: tokens.textColor,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    strings.dynamicGlowSubtitle,
                    style: TextStyle(color: tokens.subtextColor, fontSize: 12),
                  ),
                  value: tokens.useDynamicCoverGlow,
                  activeThumbColor: tokens.accentColor,
                  onChanged: (enabled) {
                    themeCtrl.setUseDynamicCoverGlow(enabled);
                    settingsCtrl.setNowPlayingBgEffect(
                      enabled
                          ? NowPlayingBgEffect.subtle
                          : NowPlayingBgEffect.off,
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Audio Card: Gapless Playback + ReplayGain
          _buildCard(
            tokens: tokens,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  key: const Key('onboarding_gapless_switch'),
                  title: Text(
                    strings.gaplessPlaybackTitle,
                    style: TextStyle(
                      color: tokens.textColor,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    strings.gaplessPlaybackSubtitle,
                    style: TextStyle(color: tokens.subtextColor, fontSize: 12),
                  ),
                  value: appSettings.gaplessPlayback,
                  activeThumbColor: tokens.accentColor,
                  onChanged: settingsCtrl.setGaplessPlayback,
                ),
                Divider(
                  height: 1,
                  indent: 14,
                  endIndent: 14,
                  color: tokens.borderColor.withValues(alpha: 0.5),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.replayGainTitle,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: tokens.textColor,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildSegmentedRow<ReplayGainMode>(
                        tokens: tokens,
                        selected: rgState.mode,
                        options: [
                          (
                            ReplayGainMode.off,
                            strings.replayGainOff,
                            const Key('onboarding_rg_off'),
                          ),
                          (
                            ReplayGainMode.track,
                            strings.replayGainTrack,
                            const Key('onboarding_rg_track'),
                          ),
                          (
                            ReplayGainMode.album,
                            strings.replayGainAlbum,
                            const Key('onboarding_rg_album'),
                          ),
                        ],
                        onSelected: rgCtrl.setMode,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Synced Lyrics & Romaji Card
          _buildCard(
            tokens: tokens,
            child: Column(
              children: [
                SwitchListTile(
                  key: const Key('onboarding_autofetch_lyrics_switch'),
                  title: Text(
                    strings.autoFetchLyricsTitle,
                    style: TextStyle(
                      color: tokens.textColor,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    strings.autoFetchLyricsSubtitle,
                    style: TextStyle(color: tokens.subtextColor, fontSize: 12),
                  ),
                  value: appSettings.autoFetchLyrics,
                  activeThumbColor: tokens.accentColor,
                  onChanged: settingsCtrl.setAutoFetchLyrics,
                ),
                Divider(
                  height: 1,
                  indent: 14,
                  endIndent: 14,
                  color: tokens.borderColor.withValues(alpha: 0.5),
                ),
                SwitchListTile(
                  key: const Key('onboarding_romaji_switch'),
                  title: Text(
                    strings.romajiTranslitTitle,
                    style: TextStyle(
                      color: tokens.textColor,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    strings.romajiTranslitSubtitle,
                    style: TextStyle(color: tokens.subtextColor, fontSize: 12),
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // STEP 4 — Ready to Listen (Visual Summary)
  // ===========================================================================
  Widget _buildStep4Summary({
    required SoneaThemeTokens tokens,
    required AppStrings strings,
    required AppSettings appSettings,
    required LibraryFilterState filterState,
    required ReplayGainState rgState,
    required LibraryState? libraryState,
  }) {
    final activePalette = SoneaThemePalette.findById(tokens.packId);
    final isScanning = libraryState?.scanning == true;
    final processed = libraryState?.processed ?? 0;
    final total = libraryState?.total ?? 0;
    final tracksCount = libraryState?.tracks.length ?? 0;
    final showLiveScanCard = isScanning || total > 0 || tracksCount > 0;

    final filterLabel = filterState.minTrackDurationSec == 0
        ? strings.minDurationOff
        : strings.secShort(filterState.minTrackDurationSec);
    final seekbarLabel = tokens.progressBarStyle == ProgressBarStyle.waveform
        ? strings.seekbarWaveform
        : strings.seekbarThinLine;
    final rgLabel = switch (rgState.mode) {
      ReplayGainMode.off => strings.replayGainOff,
      ReplayGainMode.track => strings.replayGainTrack,
      ReplayGainMode.album => strings.replayGainAlbum,
    };
    final audioSummary =
        '${appSettings.gaplessPlayback ? strings.gaplessBadge : strings.statusDisabled} · RG: $rgLabel';
    final lyricsSummary =
        '${appSettings.autoFetchLyrics ? strings.statusEnabled : strings.statusDisabled} · Romaji: ${appSettings.japaneseTransliteration ? strings.statusEnabled : strings.statusDisabled}';

    return SingleChildScrollView(
      key: const Key('onboarding_step_3'),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: tokens.accentColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(tokens.radiusLg),
                border: Border.all(
                  color: tokens.accentColor.withValues(alpha: 0.35),
                ),
              ),
              child: Icon(
                Icons.headphones_rounded,
                size: 34,
                color: tokens.accentColor,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            strings.onboardingStep4Title,
            textAlign: TextAlign.center,
            style: tokens.displayStyle(
              fontSize: 25,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: tokens.textColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            strings.onboardingStep4Subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: tokens.subtextColor,
            ),
          ),
          const SizedBox(height: 18),

          // Compact Visual Summary Card
          Container(
            key: const Key('onboarding_summary_card'),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: tokens.surfaceColor,
              borderRadius: BorderRadius.circular(tokens.radiusMd),
              border: Border.all(
                color: tokens.borderColor.withValues(alpha: 0.8),
              ),
            ),
            child: Column(
              children: [
                // Theme row with 4-color swatch strip
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: SizedBox(
                        width: 44,
                        height: 28,
                        child: Row(
                          children: [
                            for (final swatch in activePalette.paletteSwatches)
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
                          Text(
                            strings.onboardingSummaryTheme,
                            style: TextStyle(
                              fontSize: 11,
                              color: tokens.subtextColor,
                            ),
                          ),
                          Text(
                            '${strings.themeName(activePalette.id)} · ${strings.themeModeLabel(tokens.themeMode.name)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.displayStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: tokens.textColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Divider(
                    height: 1,
                    color: tokens.borderColor.withValues(alpha: 0.5),
                  ),
                ),
                _buildSummaryRow(
                  icon: Icons.filter_alt_outlined,
                  label: strings.onboardingSummaryFilter,
                  value: filterLabel,
                  tokens: tokens,
                ),
                const SizedBox(height: 8),
                _buildSummaryRow(
                  icon: Icons.linear_scale_rounded,
                  label: strings.onboardingSummarySeekbar,
                  value: seekbarLabel,
                  tokens: tokens,
                ),
                const SizedBox(height: 8),
                _buildSummaryRow(
                  icon: Icons.graphic_eq_rounded,
                  label: strings.onboardingSummaryAudio,
                  value: audioSummary,
                  tokens: tokens,
                ),
                const SizedBox(height: 8),
                _buildSummaryRow(
                  icon: Icons.lyrics_outlined,
                  label: strings.onboardingSummaryLyrics,
                  value: lyricsSummary,
                  tokens: tokens,
                ),
              ],
            ),
          ),

          if (showLiveScanCard) ...[
            const SizedBox(height: 12),
            _buildLiveScanCard(
              tokens: tokens,
              strings: strings,
              isScanning: isScanning,
              processed: processed,
              total: total,
              tracksCount: tracksCount,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSummaryRow({
    required IconData icon,
    required String label,
    required String value,
    required SoneaThemeTokens tokens,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: tokens.accentColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: tokens.subtextColor),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              fontFeatures: kTabularFigures,
              color: tokens.textColor,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLiveScanCard({
    required SoneaThemeTokens tokens,
    required AppStrings strings,
    required bool isScanning,
    required int processed,
    required int total,
    required int tracksCount,
  }) {
    return Container(
      key: const Key('onboarding_live_scan_card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.surfaceColor,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        border: Border.all(
          color: isScanning
              ? tokens.accentColor.withValues(alpha: 0.55)
              : tokens.borderColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isScanning)
                SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: tokens.accentColor,
                  ),
                )
              else
                Icon(
                  Icons.library_music_rounded,
                  size: 17,
                  color: tokens.accentColor,
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isScanning
                      ? strings.scanningLiveCounter(processed, total)
                      : strings.tracksReadyLabel(tracksCount),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFeatures: kTabularFigures,
                    color: tokens.textColor,
                  ),
                ),
              ),
              if (isScanning && total > 0)
                Text(
                  '${((processed / total) * 100).clamp(0, 100).round()}%',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFeatures: kTabularFigures,
                    color: tokens.accentColor,
                  ),
                ),
            ],
          ),
          if (isScanning) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(tokens.radiusPill),
              child: LinearProgressIndicator(
                minHeight: 5,
                value: total == 0 ? null : (processed / total).clamp(0.0, 1.0),
                backgroundColor: tokens.borderColor.withValues(alpha: 0.5),
                valueColor: AlwaysStoppedAnimation<Color>(tokens.accentColor),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCard({
    required SoneaThemeTokens tokens,
    required Widget child,
  }) {
    return Material(
      color: tokens.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        side: BorderSide(color: tokens.borderColor.withValues(alpha: 0.78)),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _buildSegmentedRow<T>({
    required SoneaThemeTokens tokens,
    required T selected,
    required List<(T, String, Key)> options,
    required ValueChanged<T> onSelected,
  }) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: tokens.elevatedSurfaceColor,
        borderRadius: BorderRadius.circular(tokens.radiusSm + 2),
        border: Border.all(color: tokens.borderColor.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          for (final (value, label, key) in options)
            Expanded(
              child: InkWell(
                key: key,
                borderRadius: BorderRadius.circular(tokens.radiusSm),
                onTap: () => onSelected(value),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 4,
                  ),
                  decoration: BoxDecoration(
                    color: value == selected
                        ? tokens.accentColor
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(tokens.radiusSm),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          value == selected ? FontWeight.w700 : FontWeight.w500,
                      color: value == selected
                          ? tokens.onAccentColor
                          : tokens.subtextColor,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
