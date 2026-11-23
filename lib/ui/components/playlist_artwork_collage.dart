import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';
import 'package:sonea/ui/components/artwork_thumbnail.dart';

/// Extracts up to [maxCount] unique, non-empty cover paths preserving order.
List<String> extractUniqueCovers(
  Iterable<String?> coverPaths, {
  int maxCount = 4,
}) {
  if (maxCount <= 0) return const [];
  final result = <String>[];
  final seen = <String>{};
  for (final raw in coverPaths) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) continue;
    if (seen.add(trimmed)) {
      result.add(trimmed);
      if (result.length >= maxCount) break;
    }
  }
  return result;
}

/// Memory-efficient 2x2 playlist artwork collage with custom cover override
/// and balanced fallbacks for 0, 1, 2, 3, and 4+ unique covers.
class PlaylistArtworkCollage extends StatelessWidget {
  const PlaylistArtworkCollage({
    super.key,
    required this.coverPaths,
    required this.size,
    required this.tokens,
    this.customCoverPath,
    this.cacheRevision = 0,
    this.radius,
    this.fallbackIcon = Icons.queue_music_rounded,
    this.fallbackIconColor,
  });

  final List<String> coverPaths;
  final double size;
  final SoneaThemeTokens tokens;
  final String? customCoverPath;
  final int cacheRevision;
  final double? radius;
  final IconData fallbackIcon;
  final Color? fallbackIconColor;

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = radius ?? tokens.radiusMd;
    final cellCacheDim = (size * 1.15).round().clamp(64, 192);
    final singleCacheDim = (size * 2.0).round().clamp(96, 320);
    final gapColor = tokens.backgroundColor;

    final hasCustom = ArtworkThumbnail.isValidCoverFile(customCoverPath);
    final unique = hasCustom
        ? <String>[customCoverPath!.trim()]
        : extractUniqueCovers(coverPaths, maxCount: 4);

    Widget content;
    switch (unique.length) {
      case 0:
        content = _buildPlaceholder(iconSize: (size * 0.42).clamp(20.0, 40.0));
        break;
      case 1:
        content = _buildImageTile(
          unique[0],
          cacheDim: singleCacheDim,
          revision: cacheRevision,
        );
        break;
      case 2:
        content = Row(
          children: [
            Expanded(child: _buildImageTile(unique[0], cacheDim: cellCacheDim)),
            Container(width: 1, color: gapColor),
            Expanded(child: _buildImageTile(unique[1], cacheDim: cellCacheDim)),
          ],
        );
        break;
      case 3:
        content = Row(
          children: [
            Expanded(child: _buildImageTile(unique[0], cacheDim: cellCacheDim)),
            Container(width: 1, color: gapColor),
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: _buildImageTile(unique[1], cacheDim: cellCacheDim),
                  ),
                  Container(height: 1, color: gapColor),
                  Expanded(
                    child: _buildImageTile(unique[2], cacheDim: cellCacheDim),
                  ),
                ],
              ),
            ),
          ],
        );
        break;
      default:
        content = Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _buildImageTile(unique[0], cacheDim: cellCacheDim),
                  ),
                  Container(width: 1, color: gapColor),
                  Expanded(
                    child: _buildImageTile(unique[1], cacheDim: cellCacheDim),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: gapColor),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _buildImageTile(unique[2], cacheDim: cellCacheDim),
                  ),
                  Container(width: 1, color: gapColor),
                  Expanded(
                    child: _buildImageTile(unique[3], cacheDim: cellCacheDim),
                  ),
                ],
              ),
            ),
          ],
        );
    }

    return RepaintBoundary(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: tokens.elevatedSurfaceColor,
          borderRadius: BorderRadius.circular(effectiveRadius),
          border: Border.all(
            color: tokens.borderColor.withValues(alpha: 0.65),
            width: 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            (effectiveRadius - 1).clamp(0.0, 32.0),
          ),
          child: content,
        ),
      ),
    );
  }

  Widget _buildImageTile(
    String path, {
    required int cacheDim,
    int revision = 0,
  }) {
    return SizedBox.expand(
      child: Image.file(
        File(path),
        key: ValueKey('collage_${path}_$revision'),
        cacheWidth: cacheDim,
        cacheHeight: cacheDim,
        filterQuality: FilterQuality.low,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _buildPlaceholder(iconSize: 16),
      ),
    );
  }

  Widget _buildPlaceholder({required double iconSize}) {
    return Container(
      color: tokens.elevatedSurfaceColor,
      alignment: Alignment.center,
      child: Icon(
        fallbackIcon,
        size: iconSize,
        color: fallbackIconColor ?? tokens.accentColor.withValues(alpha: 0.85),
      ),
    );
  }
}
