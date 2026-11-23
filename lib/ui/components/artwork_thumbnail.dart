import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/ui/components/sonea_logo_mark.dart';

/// Consistent, memory-bounded album artwork widget with dynamic corner radius
/// and resilient disk verification / fallback styling.
class ArtworkThumbnail extends StatelessWidget {
  const ArtworkThumbnail({
    super.key,
    required this.coverPath,
    required this.size,
    required this.tokens,
    this.radius,
    this.borderColor,
    this.borderWidth = 1.0,
    this.cacheWidth,
    this.cacheRevision = 0,
    this.heroTag,
  });

  final String? coverPath;
  final double size;
  final SoneaThemeTokens tokens;
  final double? radius;
  final Color? borderColor;
  final double borderWidth;
  final int? cacheWidth;
  final int cacheRevision;
  final Object? heroTag;

  static bool isValidCoverFile(String? path) {
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) return false;
    try {
      final f = File(trimmed);
      return f.existsSync() && f.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = radius ?? tokens.radiusSm;
    final effectiveBorder =
        borderColor ?? tokens.borderColor.withValues(alpha: 0.6);
    final trimmedPath = coverPath?.trim();
    final hasValidCover = isValidCoverFile(trimmedPath);
    final decodeDim = cacheWidth ?? (size * 2.0).round().clamp(72, 720);

    final fallback = Container(
      color: tokens.elevatedSurfaceColor,
      alignment: Alignment.center,
      child: SoneaLogoMark(
        size: (size * 0.52).clamp(20.0, 84.0),
        upperColor: tokens.textColor.withValues(alpha: 0.7),
        lowerColor: tokens.accentColor.withValues(alpha: 0.85),
      ),
    );

    final content = RepaintBoundary(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(effectiveRadius),
          border: Border.all(color: effectiveBorder, width: borderWidth),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            (effectiveRadius - borderWidth).clamp(0.0, 32.0),
          ),
          child: hasValidCover
              ? Image.file(
                  File(trimmedPath!),
                  key: ValueKey('art_${trimmedPath}_$cacheRevision'),
                  cacheWidth: decodeDim,
                  cacheHeight: decodeDim,
                  filterQuality: FilterQuality.low,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => fallback,
                )
              : fallback,
        ),
      ),
    );

    if (heroTag != null) {
      return Hero(tag: heroTag!, child: content);
    }
    return content;
  }
}
