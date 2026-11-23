import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';

enum ProgressBarStyle { thinLine, waveform }

enum SoneaCornerStyle { sharp, soft, rounded }

/// Reusable tabular figures font feature for timers, durations, bitrates, and lyric timestamps.
const List<ui.FontFeature> kTabularFigures = [ui.FontFeature.tabularFigures()];

/// Bundled local font families (used as zero-latency defaults & offline fallbacks).
const String kHeadingFontFamily = 'Plus Jakarta Sans';
const String kBodyFontFamily = 'Inter';

/// Multi-script fallback chain preserving crisp Turkish diacritics (ğ, ü, ş, ı, İ, ö, ç)
/// and CJK/Japanese glyphs across all themes even when completely offline.
const List<String> kSoneaFontFallback = [
  'Plus Jakarta Sans',
  'Inter',
  'Noto Sans',
  'Noto Sans CJK JP',
  'Roboto',
  'sans-serif',
];

bool get _isFlutterTestEnv {
  try {
    return Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false;
  }
}

/// Resolves a curated font family into a [TextStyle] with bundled & multi-script fallbacks.
/// Never throws when offline or inside Flutter widget/unit tests.
TextStyle resolveSoneaFont(
  String family, {
  TextStyle? base,
}) {
  final seed = (base ?? const TextStyle()).copyWith(
    fontFamilyFallback: kSoneaFontFallback,
  );
  if (family == kHeadingFontFamily || family == kBodyFontFamily) {
    return seed.copyWith(fontFamily: family);
  }
  if (_isFlutterTestEnv || !GoogleFonts.config.allowRuntimeFetching) {
    return seed.copyWith(fontFamily: family);
  }
  try {
    final resolved = GoogleFonts.getFont(family, textStyle: seed);
    unawaited(
      GoogleFonts.pendingFonts([resolved]).catchError((Object _) => <void>[]),
    );
    return resolved.copyWith(
      fontFamilyFallback: [
        ...?resolved.fontFamilyFallback,
        ...kSoneaFontFallback,
      ],
    );
  } catch (_) {
    return seed.copyWith(fontFamily: family);
  }
}

/// A dual-mode curated 4-color Sanzo Wada palette (*A Dictionary of Color Combinations*, 1933–34)
/// providing handcrafted Dark and Light editorial token sets with bespoke typography.
class SoneaThemePalette {
  const SoneaThemePalette({
    required this.id,
    required this.wadaNumber,
    required this.paletteSwatches,
    required this.displayFontFamily,
    required this.bodyFontFamily,
    required this.dark,
    required this.light,
  });

  final String id;
  final String wadaNumber;
  final List<Color> paletteSwatches;
  final String displayFontFamily;
  final String bodyFontFamily;
  final SoneaThemeTokens dark;
  final SoneaThemeTokens light;

  String get fontPairingLabel => displayFontFamily == bodyFontFamily
      ? displayFontFamily
      : '$displayFontFamily + $bodyFontFamily';

  /// Default dark token set (kept as convenience alias for call sites).
  SoneaThemeTokens get tokens => dark;

  SoneaThemeTokens forBrightness(Brightness brightness) =>
      brightness == Brightness.light ? light : dark;

  /// 1. No. 255 — Kuro & Asagi (Default)
  static const wada255 = SoneaThemePalette(
    id: 'wada_255',
    wadaNumber: 'No. 255',
    paletteSwatches: [
      Color(0xFF0B0C0E),
      Color(0xFF78C7C7),
      Color(0xFFC2B038),
      Color(0xFFB85A14),
    ],
    displayFontFamily: 'Plus Jakarta Sans',
    bodyFontFamily: 'Plus Jakarta Sans',
    dark: SoneaThemeTokens(
      packId: 'wada_255',
      wadaNumber: 'No. 255',
      backgroundColor: Color(0xFF0B0C0E),
      surfaceColor: Color(0xFF121518),
      elevatedSurfaceColor: Color(0xFF1A1E23),
      accentColor: Color(0xFF78C7C7),
      secondaryAccentColor: Color(0xFFC2B038),
      tertiaryAccentColor: Color(0xFFB85A14),
      paletteSwatches: [
        Color(0xFF0B0C0E),
        Color(0xFF78C7C7),
        Color(0xFFC2B038),
        Color(0xFFB85A14),
      ],
      onAccentColorOverride: Color(0xFF0B0C0E),
      textColor: Color(0xFFF2F5F5),
      subtextColor: Color(0xFF8FA3A3),
      borderColor: Color(0xFF242B30),
      displayFontFamily: 'Plus Jakarta Sans',
      bodyFontFamily: 'Plus Jakarta Sans',
      cornerRadius: 16.0,
      dockBlurSigma: 12.0,
      isLight: false,
    ),
    light: SoneaThemeTokens(
      packId: 'wada_255',
      wadaNumber: 'No. 255',
      backgroundColor: Color(0xFFF3F6F5),
      surfaceColor: Color(0xFFE7EEED),
      elevatedSurfaceColor: Color(0xFFFFFFFF),
      accentColor: Color(0xFF1F7A7A),
      secondaryAccentColor: Color(0xFF8A7918),
      tertiaryAccentColor: Color(0xFFB85A14),
      paletteSwatches: [
        Color(0xFF0B0C0E),
        Color(0xFF78C7C7),
        Color(0xFFC2B038),
        Color(0xFFB85A14),
      ],
      onAccentColorOverride: Color(0xFFFFFFFF),
      textColor: Color(0xFF12181A),
      subtextColor: Color(0xFF4F6366),
      borderColor: Color(0xFFCFDAD8),
      displayFontFamily: 'Plus Jakarta Sans',
      bodyFontFamily: 'Plus Jakarta Sans',
      cornerRadius: 16.0,
      dockBlurSigma: 10.0,
      isLight: true,
    ),
  );

  /// 2. No. 340 — Taisho Avant-Garde
  static const wada340 = SoneaThemePalette(
    id: 'wada_340',
    wadaNumber: 'No. 340',
    paletteSwatches: [
      Color(0xFF0B0C0E),
      Color(0xFF1EA67E),
      Color(0xFFE8451E),
      Color(0xFFB0B8B6),
    ],
    displayFontFamily: 'Space Grotesk',
    bodyFontFamily: 'Inter',
    dark: SoneaThemeTokens(
      packId: 'wada_340',
      wadaNumber: 'No. 340',
      backgroundColor: Color(0xFF0B0C0E),
      surfaceColor: Color(0xFF121615),
      elevatedSurfaceColor: Color(0xFF1A201E),
      accentColor: Color(0xFF1EA67E),
      secondaryAccentColor: Color(0xFFE8451E),
      tertiaryAccentColor: Color(0xFFB0B8B6),
      paletteSwatches: [
        Color(0xFF0B0C0E),
        Color(0xFF1EA67E),
        Color(0xFFE8451E),
        Color(0xFFB0B8B6),
      ],
      onAccentColorOverride: Color(0xFF061611),
      textColor: Color(0xFFF3F6F5),
      subtextColor: Color(0xFF9AA6A3),
      borderColor: Color(0xFF252E2B),
      displayFontFamily: 'Space Grotesk',
      bodyFontFamily: 'Inter',
      cornerRadius: 12.0,
      dockBlurSigma: 10.0,
      isLight: false,
    ),
    light: SoneaThemeTokens(
      packId: 'wada_340',
      wadaNumber: 'No. 340',
      backgroundColor: Color(0xFFF4F5F3),
      surfaceColor: Color(0xFFE8ECE9),
      elevatedSurfaceColor: Color(0xFFFFFFFF),
      accentColor: Color(0xFF137A5B),
      secondaryAccentColor: Color(0xFFC83412),
      tertiaryAccentColor: Color(0xFF5E6B68),
      paletteSwatches: [
        Color(0xFF0B0C0E),
        Color(0xFF1EA67E),
        Color(0xFFE8451E),
        Color(0xFFB0B8B6),
      ],
      onAccentColorOverride: Color(0xFFFFFFFF),
      textColor: Color(0xFF111615),
      subtextColor: Color(0xFF4E5C58),
      borderColor: Color(0xFFD0D8D4),
      displayFontFamily: 'Space Grotesk',
      bodyFontFamily: 'Inter',
      cornerRadius: 12.0,
      dockBlurSigma: 10.0,
      isLight: true,
    ),
  );

  /// 3. No. 303 — Showa Studio
  static const wada303 = SoneaThemePalette(
    id: 'wada_303',
    wadaNumber: 'No. 303',
    paletteSwatches: [
      Color(0xFF171C16),
      Color(0xFFE8451E),
      Color(0xFFEEE098),
      Color(0xFFB0B8B6),
    ],
    displayFontFamily: 'IBM Plex Sans',
    bodyFontFamily: 'IBM Plex Sans',
    dark: SoneaThemeTokens(
      packId: 'wada_303',
      wadaNumber: 'No. 303',
      backgroundColor: Color(0xFF171C16),
      surfaceColor: Color(0xFF1F261E),
      elevatedSurfaceColor: Color(0xFF283127),
      accentColor: Color(0xFFE8451E),
      secondaryAccentColor: Color(0xFFEEE098),
      tertiaryAccentColor: Color(0xFFB0B8B6),
      paletteSwatches: [
        Color(0xFF171C16),
        Color(0xFFE8451E),
        Color(0xFFEEE098),
        Color(0xFFB0B8B6),
      ],
      onAccentColorOverride: Color(0xFF0B0C0E),
      textColor: Color(0xFFF5F3E8),
      subtextColor: Color(0xFFA7B0A4),
      borderColor: Color(0xFF333E31),
      displayFontFamily: 'IBM Plex Sans',
      bodyFontFamily: 'IBM Plex Sans',
      cornerRadius: 10.0,
      dockBlurSigma: 10.0,
      isLight: false,
    ),
    light: SoneaThemeTokens(
      packId: 'wada_303',
      wadaNumber: 'No. 303',
      backgroundColor: Color(0xFFF4F2E8),
      surfaceColor: Color(0xFFE9E6D8),
      elevatedSurfaceColor: Color(0xFFFCFBF6),
      accentColor: Color(0xFFC73614),
      secondaryAccentColor: Color(0xFF8C7A1F),
      tertiaryAccentColor: Color(0xFF546152),
      paletteSwatches: [
        Color(0xFF171C16),
        Color(0xFFE8451E),
        Color(0xFFEEE098),
        Color(0xFFB0B8B6),
      ],
      onAccentColorOverride: Color(0xFFFFFFFF),
      textColor: Color(0xFF181E17),
      subtextColor: Color(0xFF556153),
      borderColor: Color(0xFFD4D0BE),
      displayFontFamily: 'IBM Plex Sans',
      bodyFontFamily: 'IBM Plex Sans',
      cornerRadius: 10.0,
      dockBlurSigma: 10.0,
      isLight: true,
    ),
  );

  /// 4. No. 288 — Kenpou Vinyl
  static const wada288 = SoneaThemePalette(
    id: 'wada_288',
    wadaNumber: 'No. 288',
    paletteSwatches: [
      Color(0xFF0B0C0E),
      Color(0xFFF59614),
      Color(0xFF5E2F42),
      Color(0xFF4A3316),
    ],
    displayFontFamily: 'Newsreader',
    bodyFontFamily: 'Inter',
    dark: SoneaThemeTokens(
      packId: 'wada_288',
      wadaNumber: 'No. 288',
      backgroundColor: Color(0xFF0B0C0E),
      surfaceColor: Color(0xFF16120E),
      elevatedSurfaceColor: Color(0xFF211A14),
      accentColor: Color(0xFFF59614),
      secondaryAccentColor: Color(0xFF5E2F42),
      tertiaryAccentColor: Color(0xFF4A3316),
      paletteSwatches: [
        Color(0xFF0B0C0E),
        Color(0xFFF59614),
        Color(0xFF5E2F42),
        Color(0xFF4A3316),
      ],
      onAccentColorOverride: Color(0xFF0B0C0E),
      textColor: Color(0xFFFAF3E8),
      subtextColor: Color(0xFFB5A08B),
      borderColor: Color(0xFF33271D),
      displayFontFamily: 'Newsreader',
      bodyFontFamily: 'Inter',
      cornerRadius: 16.0,
      dockBlurSigma: 10.0,
      isLight: false,
    ),
    light: SoneaThemeTokens(
      packId: 'wada_288',
      wadaNumber: 'No. 288',
      backgroundColor: Color(0xFFF7F1E8),
      surfaceColor: Color(0xFFECE2D4),
      elevatedSurfaceColor: Color(0xFFFDF9F4),
      accentColor: Color(0xFFC26B00),
      secondaryAccentColor: Color(0xFF6B344B),
      tertiaryAccentColor: Color(0xFF4A3316),
      paletteSwatches: [
        Color(0xFF0B0C0E),
        Color(0xFFF59614),
        Color(0xFF5E2F42),
        Color(0xFF4A3316),
      ],
      onAccentColorOverride: Color(0xFF120B04),
      textColor: Color(0xFF1F1711),
      subtextColor: Color(0xFF665344),
      borderColor: Color(0xFFDACBB9),
      displayFontFamily: 'Newsreader',
      bodyFontFamily: 'Inter',
      cornerRadius: 16.0,
      dockBlurSigma: 10.0,
      isLight: true,
    ),
  );

  /// 5. No. 331 — Kachi Indigo
  static const wada331 = SoneaThemePalette(
    id: 'wada_331',
    wadaNumber: 'No. 331',
    paletteSwatches: [
      Color(0xFF10102A),
      Color(0xFFC9265B),
      Color(0xFF8E5EB8),
      Color(0xFF3B248C),
    ],
    displayFontFamily: 'Outfit',
    bodyFontFamily: 'Outfit',
    dark: SoneaThemeTokens(
      packId: 'wada_331',
      wadaNumber: 'No. 331',
      backgroundColor: Color(0xFF10102A),
      surfaceColor: Color(0xFF171738),
      elevatedSurfaceColor: Color(0xFF21204C),
      accentColor: Color(0xFFC9265B),
      secondaryAccentColor: Color(0xFF8E5EB8),
      tertiaryAccentColor: Color(0xFF3B248C),
      paletteSwatches: [
        Color(0xFF10102A),
        Color(0xFFC9265B),
        Color(0xFF8E5EB8),
        Color(0xFF3B248C),
      ],
      onAccentColorOverride: Color(0xFFFFFFFF),
      textColor: Color(0xFFF4F1FA),
      subtextColor: Color(0xFFA7A1C4),
      borderColor: Color(0xFF2E2D63),
      displayFontFamily: 'Outfit',
      bodyFontFamily: 'Outfit',
      cornerRadius: 18.0,
      dockBlurSigma: 12.0,
      isLight: false,
    ),
    light: SoneaThemeTokens(
      packId: 'wada_331',
      wadaNumber: 'No. 331',
      backgroundColor: Color(0xFFF3F1F9),
      surfaceColor: Color(0xFFE7E3F3),
      elevatedSurfaceColor: Color(0xFFFCFBFF),
      accentColor: Color(0xFFB51D4F),
      secondaryAccentColor: Color(0xFF5E3894),
      tertiaryAccentColor: Color(0xFF3B248C),
      paletteSwatches: [
        Color(0xFF10102A),
        Color(0xFFC9265B),
        Color(0xFF8E5EB8),
        Color(0xFF3B248C),
      ],
      onAccentColorOverride: Color(0xFFFFFFFF),
      textColor: Color(0xFF161430),
      subtextColor: Color(0xFF585278),
      borderColor: Color(0xFFD1CAE4),
      displayFontFamily: 'Outfit',
      bodyFontFamily: 'Outfit',
      cornerRadius: 18.0,
      dockBlurSigma: 10.0,
      isLight: true,
    ),
  );

  /// 6. No. 271 — Tetsu Jade
  static const wada271 = SoneaThemePalette(
    id: 'wada_271',
    wadaNumber: 'No. 271',
    paletteSwatches: [
      Color(0xFF101E1B),
      Color(0xFF8CC7A1),
      Color(0xFF1E7E84),
      Color(0xFFB81D4E),
    ],
    displayFontFamily: 'DM Sans',
    bodyFontFamily: 'DM Sans',
    dark: SoneaThemeTokens(
      packId: 'wada_271',
      wadaNumber: 'No. 271',
      backgroundColor: Color(0xFF101E1B),
      surfaceColor: Color(0xFF162925),
      elevatedSurfaceColor: Color(0xFF1E3631),
      accentColor: Color(0xFF8CC7A1),
      secondaryAccentColor: Color(0xFF1E7E84),
      tertiaryAccentColor: Color(0xFFB81D4E),
      paletteSwatches: [
        Color(0xFF101E1B),
        Color(0xFF8CC7A1),
        Color(0xFF1E7E84),
        Color(0xFFB81D4E),
      ],
      onAccentColorOverride: Color(0xFF0B1714),
      textColor: Color(0xFFEDF6F2),
      subtextColor: Color(0xFF8FAEA5),
      borderColor: Color(0xFF28453F),
      displayFontFamily: 'DM Sans',
      bodyFontFamily: 'DM Sans',
      cornerRadius: 16.0,
      dockBlurSigma: 10.0,
      isLight: false,
    ),
    light: SoneaThemeTokens(
      packId: 'wada_271',
      wadaNumber: 'No. 271',
      backgroundColor: Color(0xFFEFF6F3),
      surfaceColor: Color(0xFFE1EDE8),
      elevatedSurfaceColor: Color(0xFFFAFDFA),
      accentColor: Color(0xFF186B70),
      secondaryAccentColor: Color(0xFF2E7A52),
      tertiaryAccentColor: Color(0xFFA81845),
      paletteSwatches: [
        Color(0xFF101E1B),
        Color(0xFF8CC7A1),
        Color(0xFF1E7E84),
        Color(0xFFB81D4E),
      ],
      onAccentColorOverride: Color(0xFFFFFFFF),
      textColor: Color(0xFF11221E),
      subtextColor: Color(0xFF4B665E),
      borderColor: Color(0xFFC6DAD2),
      displayFontFamily: 'DM Sans',
      bodyFontFamily: 'DM Sans',
      cornerRadius: 16.0,
      dockBlurSigma: 10.0,
      isLight: true,
    ),
  );

  /// 7. No. 329 — Kakitsubata Dusk
  static const wada329 = SoneaThemePalette(
    id: 'wada_329',
    wadaNumber: 'No. 329',
    paletteSwatches: [
      Color(0xFF1A2226),
      Color(0xFFF2B84B),
      Color(0xFFB5A3B8),
      Color(0xFF3D1236),
    ],
    displayFontFamily: 'Fraunces',
    bodyFontFamily: 'Inter',
    dark: SoneaThemeTokens(
      packId: 'wada_329',
      wadaNumber: 'No. 329',
      backgroundColor: Color(0xFF1A2226),
      surfaceColor: Color(0xFF222C31),
      elevatedSurfaceColor: Color(0xFF2C383E),
      accentColor: Color(0xFFF2B84B),
      secondaryAccentColor: Color(0xFFB5A3B8),
      tertiaryAccentColor: Color(0xFF3D1236),
      paletteSwatches: [
        Color(0xFF1A2226),
        Color(0xFFF2B84B),
        Color(0xFFB5A3B8),
        Color(0xFF3D1236),
      ],
      onAccentColorOverride: Color(0xFF161B1E),
      textColor: Color(0xFFF6F2F7),
      subtextColor: Color(0xFFA8A2AD),
      borderColor: Color(0xFF3B4950),
      displayFontFamily: 'Fraunces',
      bodyFontFamily: 'Inter',
      cornerRadius: 18.0,
      dockBlurSigma: 12.0,
      isLight: false,
    ),
    light: SoneaThemeTokens(
      packId: 'wada_329',
      wadaNumber: 'No. 329',
      backgroundColor: Color(0xFFF4F1F5),
      surfaceColor: Color(0xFFE9E3EC),
      elevatedSurfaceColor: Color(0xFFFCF9FD),
      accentColor: Color(0xFF7D266F),
      secondaryAccentColor: Color(0xFFB07B14),
      tertiaryAccentColor: Color(0xFF3D1236),
      paletteSwatches: [
        Color(0xFF1A2226),
        Color(0xFFF2B84B),
        Color(0xFFB5A3B8),
        Color(0xFF3D1236),
      ],
      onAccentColorOverride: Color(0xFFFFFFFF),
      textColor: Color(0xFF1B2126),
      subtextColor: Color(0xFF5B5663),
      borderColor: Color(0xFFD4CBD8),
      displayFontFamily: 'Fraunces',
      bodyFontFamily: 'Inter',
      cornerRadius: 18.0,
      dockBlurSigma: 10.0,
      isLight: true,
    ),
  );

  /// 8. No. 263 — Kuriume Ceramic
  static const wada263 = SoneaThemePalette(
    id: 'wada_263',
    wadaNumber: 'No. 263',
    paletteSwatches: [
      Color(0xFF1A2226),
      Color(0xFFE0A672),
      Color(0xFFB0DAC8),
      Color(0xFFA63A14),
    ],
    displayFontFamily: 'Manrope',
    bodyFontFamily: 'Manrope',
    dark: SoneaThemeTokens(
      packId: 'wada_263',
      wadaNumber: 'No. 263',
      backgroundColor: Color(0xFF1A2226),
      surfaceColor: Color(0xFF232B2F),
      elevatedSurfaceColor: Color(0xFF2E373C),
      accentColor: Color(0xFFE0A672),
      secondaryAccentColor: Color(0xFFB0DAC8),
      tertiaryAccentColor: Color(0xFFA63A14),
      paletteSwatches: [
        Color(0xFF1A2226),
        Color(0xFFE0A672),
        Color(0xFFB0DAC8),
        Color(0xFFA63A14),
      ],
      onAccentColorOverride: Color(0xFF161B1E),
      textColor: Color(0xFFF6F1EC),
      subtextColor: Color(0xFFABA49D),
      borderColor: Color(0xFF3E484D),
      displayFontFamily: 'Manrope',
      bodyFontFamily: 'Manrope',
      cornerRadius: 14.0,
      dockBlurSigma: 10.0,
      isLight: false,
    ),
    light: SoneaThemeTokens(
      packId: 'wada_263',
      wadaNumber: 'No. 263',
      backgroundColor: Color(0xFFF5F0EB),
      surfaceColor: Color(0xFFEAE1D8),
      elevatedSurfaceColor: Color(0xFFFDFBF8),
      accentColor: Color(0xFFA63A14),
      secondaryAccentColor: Color(0xFF2B7A63),
      tertiaryAccentColor: Color(0xFF784925),
      paletteSwatches: [
        Color(0xFF1A2226),
        Color(0xFFE0A672),
        Color(0xFFB0DAC8),
        Color(0xFFA63A14),
      ],
      onAccentColorOverride: Color(0xFFFFFFFF),
      textColor: Color(0xFF1E2428),
      subtextColor: Color(0xFF5E5750),
      borderColor: Color(0xFFD7CCC1),
      displayFontFamily: 'Manrope',
      bodyFontFamily: 'Manrope',
      cornerRadius: 14.0,
      dockBlurSigma: 10.0,
      isLight: true,
    ),
  );

  /// 9. No. 348 — Haishoku Finale
  static const wada348 = SoneaThemePalette(
    id: 'wada_348',
    wadaNumber: 'No. 348',
    paletteSwatches: [
      Color(0xFF171C16),
      Color(0xFFC4C18E),
      Color(0xFF2E5929),
      Color(0xFF3D1236),
    ],
    displayFontFamily: 'Playfair Display',
    bodyFontFamily: 'Inter',
    dark: SoneaThemeTokens(
      packId: 'wada_348',
      wadaNumber: 'No. 348',
      backgroundColor: Color(0xFF171C16),
      surfaceColor: Color(0xFF1F261E),
      elevatedSurfaceColor: Color(0xFF293228),
      accentColor: Color(0xFFC4C18E),
      secondaryAccentColor: Color(0xFF2E5929),
      tertiaryAccentColor: Color(0xFF3D1236),
      paletteSwatches: [
        Color(0xFF171C16),
        Color(0xFFC4C18E),
        Color(0xFF2E5929),
        Color(0xFF3D1236),
      ],
      onAccentColorOverride: Color(0xFF141813),
      textColor: Color(0xFFF4F3E9),
      subtextColor: Color(0xFFA7AA96),
      borderColor: Color(0xFF364234),
      displayFontFamily: 'Playfair Display',
      bodyFontFamily: 'Inter',
      cornerRadius: 16.0,
      dockBlurSigma: 10.0,
      isLight: false,
    ),
    light: SoneaThemeTokens(
      packId: 'wada_348',
      wadaNumber: 'No. 348',
      backgroundColor: Color(0xFFF3F2E9),
      surfaceColor: Color(0xFFE7E5D7),
      elevatedSurfaceColor: Color(0xFFFAF9F3),
      accentColor: Color(0xFF2E5929),
      secondaryAccentColor: Color(0xFF632158),
      tertiaryAccentColor: Color(0xFF6E6A3A),
      paletteSwatches: [
        Color(0xFF171C16),
        Color(0xFFC4C18E),
        Color(0xFF2E5929),
        Color(0xFF3D1236),
      ],
      onAccentColorOverride: Color(0xFFFFFFFF),
      textColor: Color(0xFF191E18),
      subtextColor: Color(0xFF585C4E),
      borderColor: Color(0xFFD2D0BE),
      displayFontFamily: 'Playfair Display',
      bodyFontFamily: 'Inter',
      cornerRadius: 16.0,
      dockBlurSigma: 10.0,
      isLight: true,
    ),
  );

  /// 10. No. 343 — Shiracha Editorial
  static const wada343 = SoneaThemePalette(
    id: 'wada_343',
    wadaNumber: 'No. 343',
    paletteSwatches: [
      Color(0xFFEFE8D4),
      Color(0xFF133F66),
      Color(0xFFA63A14),
      Color(0xFF524E2E),
    ],
    displayFontFamily: 'Lora',
    bodyFontFamily: 'IBM Plex Sans',
    dark: SoneaThemeTokens(
      packId: 'wada_343',
      wadaNumber: 'No. 343',
      backgroundColor: Color(0xFF14181C),
      surfaceColor: Color(0xFF1C2229),
      elevatedSurfaceColor: Color(0xFF252E38),
      accentColor: Color(0xFFE29A67),
      secondaryAccentColor: Color(0xFF6CA6D9),
      tertiaryAccentColor: Color(0xFFC4BE8B),
      paletteSwatches: [
        Color(0xFFEFE8D4),
        Color(0xFF133F66),
        Color(0xFFA63A14),
        Color(0xFF524E2E),
      ],
      onAccentColorOverride: Color(0xFF14181C),
      textColor: Color(0xFFF3EFE2),
      subtextColor: Color(0xFFA5A190),
      borderColor: Color(0xFF313C47),
      displayFontFamily: 'Lora',
      bodyFontFamily: 'IBM Plex Sans',
      cornerRadius: 14.0,
      dockBlurSigma: 10.0,
      isLight: false,
    ),
    light: SoneaThemeTokens(
      packId: 'wada_343',
      wadaNumber: 'No. 343',
      backgroundColor: Color(0xFFEFE8D4),
      surfaceColor: Color(0xFFE5DCBF),
      elevatedSurfaceColor: Color(0xFFFAF6EA),
      accentColor: Color(0xFF133F66),
      secondaryAccentColor: Color(0xFFA63A14),
      tertiaryAccentColor: Color(0xFF524E2E),
      paletteSwatches: [
        Color(0xFFEFE8D4),
        Color(0xFF133F66),
        Color(0xFFA63A14),
        Color(0xFF524E2E),
      ],
      onAccentColorOverride: Color(0xFFFAF6EA),
      textColor: Color(0xFF1D2326),
      subtextColor: Color(0xFF524E2E),
      borderColor: Color(0xFFD1C6A8),
      displayFontFamily: 'Lora',
      bodyFontFamily: 'IBM Plex Sans',
      cornerRadius: 14.0,
      dockBlurSigma: 10.0,
      isLight: true,
    ),
  );

  static const List<SoneaThemePalette> all = [
    wada255,
    wada340,
    wada303,
    wada288,
    wada331,
    wada271,
    wada329,
    wada263,
    wada348,
    wada343,
  ];

  /// Safely resolves a palette by ID; migrates any removed legacy theme IDs
  /// (e.g. `glacier`, `obsidian`, `midnight_oled`, etc.) cleanly to [wada255].
  static SoneaThemePalette findById(String? id) {
    if (id == null || id.isEmpty) return wada255;
    for (final p in all) {
      if (p.id == id) return p;
    }
    return wada255;
  }
}

class SoneaThemeTokens extends ThemeExtension<SoneaThemeTokens> {
  const SoneaThemeTokens({
    required this.packId,
    required this.wadaNumber,
    required this.backgroundColor,
    required this.surfaceColor,
    required this.elevatedSurfaceColor,
    required this.accentColor,
    required this.secondaryAccentColor,
    required this.tertiaryAccentColor,
    required this.paletteSwatches,
    required this.textColor,
    required this.subtextColor,
    required this.borderColor,
    required this.displayFontFamily,
    required this.bodyFontFamily,
    required this.cornerRadius,
    required this.dockBlurSigma,
    required this.isLight,
    this.onAccentColorOverride,
    this.themeMode = ThemeMode.system,
    this.progressBarStyle = ProgressBarStyle.thinLine,
    this.useDynamicCoverGlow = true,
    this.showFormatBadges = false,
    this.showTrackDuration = true,
    this.compactListMode = false,
    this.showAlphabetScroller = true,
    this.startupTab = 1,
  });

  final String packId;
  final String wadaNumber;
  final Color backgroundColor;
  final Color surfaceColor;
  final Color elevatedSurfaceColor;
  final Color accentColor;
  final Color secondaryAccentColor;
  final Color tertiaryAccentColor;
  final List<Color> paletteSwatches;
  final Color? onAccentColorOverride;
  final Color textColor;
  final Color subtextColor;
  final Color borderColor;
  final String displayFontFamily;
  final String bodyFontFamily;
  final double cornerRadius;
  final double dockBlurSigma;
  final bool isLight;

  final ThemeMode themeMode;
  final ProgressBarStyle progressBarStyle;
  final bool useDynamicCoverGlow;
  final bool showFormatBadges;
  final bool showTrackDuration;
  final bool compactListMode;
  final bool showAlphabetScroller;
  final int startupTab; // 0 = Library, 1 = Playlists (Home), 2 = Files

  double get listDensityHeight => compactListMode ? 52.0 : 64.0;
  bool get isDark => !isLight;

  String get fontPairingLabel => displayFontFamily == bodyFontFamily
      ? displayFontFamily
      : '$displayFontFamily + $bodyFontFamily';

  /// Active corner style derived from [cornerRadius]:
  /// Sharp (<= 6), Soft (6..18), Rounded (>= 18).
  SoneaCornerStyle get cornerStyle {
    if (cornerRadius <= 6.0) return SoneaCornerStyle.sharp;
    if (cornerRadius >= 18.0) return SoneaCornerStyle.rounded;
    return SoneaCornerStyle.soft;
  }

  /// Small radius for compact artwork thumbnails, format badges, and chips.
  double get radiusSm => switch (cornerStyle) {
        SoneaCornerStyle.sharp => 2.0,
        SoneaCornerStyle.soft => 8.0,
        SoneaCornerStyle.rounded => 14.0,
      };

  /// Medium radius for cards, playlist rows, album tiles, mini player, and buttons.
  double get radiusMd => switch (cornerStyle) {
        SoneaCornerStyle.sharp => 4.0,
        SoneaCornerStyle.soft => 12.0,
        SoneaCornerStyle.rounded => 20.0,
      };

  /// Large radius for Now Playing artwork, dialogs, bottom sheets, and nav dock.
  double get radiusLg => switch (cornerStyle) {
        SoneaCornerStyle.sharp => 4.0,
        SoneaCornerStyle.soft => 16.0,
        SoneaCornerStyle.rounded => 26.0,
      };

  /// Pill radius for search inputs, segmented switches, and floating containers.
  double get radiusPill => switch (cornerStyle) {
        SoneaCornerStyle.sharp => 4.0,
        SoneaCornerStyle.soft => 14.0,
        SoneaCornerStyle.rounded => 26.0,
      };

  static SoneaThemeTokens get defaultFallback => SoneaThemePalette.wada255.dark;

  static SoneaThemeTokens of(BuildContext context) {
    final ext = Theme.of(context).extension<SoneaThemeTokens>();
    if (ext != null) return ext;
    final brightness = Theme.of(context).brightness;
    return SoneaThemePalette.wada255.forBrightness(brightness);
  }

  /// Resolves the active [SoneaThemeTokens] for [platformBrightness] honoring [themeMode].
  SoneaThemeTokens resolveForPlatform(Brightness platformBrightness) {
    final effectiveBrightness = switch (themeMode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system => platformBrightness,
    };
    return withBrightness(effectiveBrightness);
  }

  /// Returns this palette's Light or Dark token variant preserving all user preferences.
  SoneaThemeTokens withBrightness(Brightness brightness) {
    final palette = SoneaThemePalette.findById(packId);
    final base = palette.forBrightness(brightness);
    return base.copyWith(
      cornerRadius: cornerRadius,
      themeMode: themeMode,
      progressBarStyle: progressBarStyle,
      useDynamicCoverGlow: useDynamicCoverGlow,
      showFormatBadges: showFormatBadges,
      showTrackDuration: showTrackDuration,
      compactListMode: compactListMode,
      showAlphabetScroller: showAlphabetScroller,
      startupTab: startupTab,
    );
  }

  /// Builds a display-font [TextStyle] using this theme's bespoke display typography.
  TextStyle displayStyle({
    double? fontSize,
    FontWeight? fontWeight,
    double? letterSpacing,
    double? height,
    Color? color,
    List<ui.FontFeature>? fontFeatures,
  }) {
    return resolveSoneaFont(
      displayFontFamily,
      base: TextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        letterSpacing: letterSpacing,
        height: height,
        color: color ?? textColor,
        fontFeatures: fontFeatures,
      ),
    );
  }

  /// Builds a body-font [TextStyle] using this theme's bespoke body typography.
  TextStyle bodyStyle({
    double? fontSize,
    FontWeight? fontWeight,
    double? letterSpacing,
    double? height,
    Color? color,
    List<ui.FontFeature>? fontFeatures,
  }) {
    return resolveSoneaFont(
      bodyFontFamily,
      base: TextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        letterSpacing: letterSpacing,
        height: height,
        color: color ?? textColor,
        fontFeatures: fontFeatures,
      ),
    );
  }

  /// High-contrast foreground color suitable for text/icons placed on [accentColor].
  Color get onAccentColor {
    final custom = onAccentColorOverride;
    if (custom != null) return custom;
    final lum = accentColor.computeLuminance();
    final contrastWithWhite = (1.0 + 0.05) / (lum + 0.05);
    final contrastWithBlack = (lum + 0.05) / 0.05;
    return contrastWithWhite >= contrastWithBlack ? Colors.white : Colors.black;
  }

  @override
  SoneaThemeTokens copyWith({
    String? packId,
    String? wadaNumber,
    Color? backgroundColor,
    Color? surfaceColor,
    Color? elevatedSurfaceColor,
    Color? accentColor,
    Color? secondaryAccentColor,
    Color? tertiaryAccentColor,
    List<Color>? paletteSwatches,
    Color? onAccentColorOverride,
    Color? textColor,
    Color? subtextColor,
    Color? borderColor,
    String? displayFontFamily,
    String? bodyFontFamily,
    double? cornerRadius,
    double? dockBlurSigma,
    bool? isLight,
    ThemeMode? themeMode,
    ProgressBarStyle? progressBarStyle,
    bool? useDynamicCoverGlow,
    bool? showFormatBadges,
    bool? showTrackDuration,
    bool? compactListMode,
    bool? showAlphabetScroller,
    int? startupTab,
  }) {
    return SoneaThemeTokens(
      packId: packId ?? this.packId,
      wadaNumber: wadaNumber ?? this.wadaNumber,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      surfaceColor: surfaceColor ?? this.surfaceColor,
      elevatedSurfaceColor: elevatedSurfaceColor ?? this.elevatedSurfaceColor,
      accentColor: accentColor ?? this.accentColor,
      secondaryAccentColor: secondaryAccentColor ?? this.secondaryAccentColor,
      tertiaryAccentColor: tertiaryAccentColor ?? this.tertiaryAccentColor,
      paletteSwatches: paletteSwatches ?? this.paletteSwatches,
      onAccentColorOverride:
          onAccentColorOverride ?? this.onAccentColorOverride,
      textColor: textColor ?? this.textColor,
      subtextColor: subtextColor ?? this.subtextColor,
      borderColor: borderColor ?? this.borderColor,
      displayFontFamily: displayFontFamily ?? this.displayFontFamily,
      bodyFontFamily: bodyFontFamily ?? this.bodyFontFamily,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      dockBlurSigma: dockBlurSigma ?? this.dockBlurSigma,
      isLight: isLight ?? this.isLight,
      themeMode: themeMode ?? this.themeMode,
      progressBarStyle: progressBarStyle ?? this.progressBarStyle,
      useDynamicCoverGlow: useDynamicCoverGlow ?? this.useDynamicCoverGlow,
      showFormatBadges: showFormatBadges ?? this.showFormatBadges,
      showTrackDuration: showTrackDuration ?? this.showTrackDuration,
      compactListMode: compactListMode ?? this.compactListMode,
      showAlphabetScroller: showAlphabetScroller ?? this.showAlphabetScroller,
      startupTab: startupTab ?? this.startupTab,
    );
  }

  @override
  SoneaThemeTokens lerp(ThemeExtension<SoneaThemeTokens>? other, double t) {
    if (other is! SoneaThemeTokens) return this;
    return SoneaThemeTokens(
      packId: t < 0.5 ? packId : other.packId,
      wadaNumber: t < 0.5 ? wadaNumber : other.wadaNumber,
      backgroundColor: Color.lerp(backgroundColor, other.backgroundColor, t)!,
      surfaceColor: Color.lerp(surfaceColor, other.surfaceColor, t)!,
      elevatedSurfaceColor:
          Color.lerp(elevatedSurfaceColor, other.elevatedSurfaceColor, t)!,
      accentColor: Color.lerp(accentColor, other.accentColor, t)!,
      secondaryAccentColor:
          Color.lerp(secondaryAccentColor, other.secondaryAccentColor, t)!,
      tertiaryAccentColor:
          Color.lerp(tertiaryAccentColor, other.tertiaryAccentColor, t)!,
      paletteSwatches: t < 0.5 ? paletteSwatches : other.paletteSwatches,
      onAccentColorOverride:
          Color.lerp(onAccentColorOverride, other.onAccentColorOverride, t),
      textColor: Color.lerp(textColor, other.textColor, t)!,
      subtextColor: Color.lerp(subtextColor, other.subtextColor, t)!,
      borderColor: Color.lerp(borderColor, other.borderColor, t)!,
      displayFontFamily: t < 0.5 ? displayFontFamily : other.displayFontFamily,
      bodyFontFamily: t < 0.5 ? bodyFontFamily : other.bodyFontFamily,
      cornerRadius: lerpDouble(cornerRadius, other.cornerRadius, t)!,
      dockBlurSigma: lerpDouble(dockBlurSigma, other.dockBlurSigma, t)!,
      isLight: t < 0.5 ? isLight : other.isLight,
      themeMode: t < 0.5 ? themeMode : other.themeMode,
      progressBarStyle: t < 0.5 ? progressBarStyle : other.progressBarStyle,
      useDynamicCoverGlow:
          t < 0.5 ? useDynamicCoverGlow : other.useDynamicCoverGlow,
      showFormatBadges: t < 0.5 ? showFormatBadges : other.showFormatBadges,
      showTrackDuration: t < 0.5 ? showTrackDuration : other.showTrackDuration,
      compactListMode: t < 0.5 ? compactListMode : other.compactListMode,
      showAlphabetScroller:
          t < 0.5 ? showAlphabetScroller : other.showAlphabetScroller,
      startupTab: t < 0.5 ? startupTab : other.startupTab,
    );
  }

  static double? lerpDouble(double? a, double? b, double t) {
    if (a == null && b == null) return null;
    a ??= 0.0;
    b ??= 0.0;
    return a + (b - a) * t;
  }

  /// Bespoke per-theme typography hierarchy pairing [displayFontFamily] for headings
  /// and [bodyFontFamily] for body/UI with Turkish & CJK fallbacks.
  TextTheme _buildTextTheme() {
    return TextTheme(
      displayLarge: displayStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
        height: 1.15,
        color: textColor,
      ),
      displayMedium: displayStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        height: 1.18,
        color: textColor,
      ),
      displaySmall: displayStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.5,
        height: 1.2,
        color: textColor,
      ),
      headlineLarge: displayStyle(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        height: 1.2,
        color: textColor,
      ),
      headlineMedium: displayStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
        height: 1.25,
        color: textColor,
      ),
      headlineSmall: displayStyle(
        fontSize: 19,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
        height: 1.25,
        color: textColor,
      ),
      titleLarge: displayStyle(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        height: 1.25,
        color: textColor,
      ),
      titleMedium: displayStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.15,
        height: 1.3,
        color: textColor,
      ),
      titleSmall: bodyStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        height: 1.3,
        color: textColor,
      ),
      bodyLarge: bodyStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        height: 1.4,
        color: textColor,
      ),
      bodyMedium: bodyStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.4,
        color: textColor,
      ),
      bodySmall: bodyStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.35,
        color: subtextColor,
      ),
      labelLarge: bodyStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        color: textColor,
      ),
      labelMedium: bodyStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: subtextColor,
      ),
      labelSmall: bodyStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        fontFeatures: kTabularFigures,
        color: subtextColor,
      ),
    );
  }

  ThemeData toThemeDataFor(Brightness brightness) =>
      withBrightness(brightness).toThemeData();

  ThemeData toThemeData() {
    final brightness = isLight ? Brightness.light : Brightness.dark;
    final baseScheme =
        isLight ? const ColorScheme.light() : const ColorScheme.dark();
    final textTheme = _buildTextTheme();
    final primaryFontFamily = textTheme.bodyMedium?.fontFamily ?? bodyFontFamily;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: primaryFontFamily,
      fontFamilyFallback: kSoneaFontFallback,
      scaffoldBackgroundColor: backgroundColor,
      textTheme: textTheme,
      colorScheme: baseScheme.copyWith(
        primary: accentColor,
        onPrimary: onAccentColor,
        secondary: secondaryAccentColor,
        tertiary: tertiaryAccentColor,
        surface: surfaceColor,
        surfaceContainerHigh: elevatedSurfaceColor,
        onSurface: textColor,
        onSurfaceVariant: subtextColor,
        outline: borderColor,
      ),
      cardTheme: CardThemeData(
        color: surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          side: BorderSide(color: borderColor.withValues(alpha: 0.7)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
        ),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: subtextColor),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaceColor,
        modalBackgroundColor: surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusLg)),
        ),
      ),
      extensions: [this],
    );
  }
}
