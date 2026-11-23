import 'package:material_ui/material_ui.dart';

/// Vector CustomPainter implementation of the sharp-tipped, filled
/// Sonea Phase-S brand mark (viewBox 0 0 512 512).
class SoneaLogoMark extends StatelessWidget {
  const SoneaLogoMark({
    super.key,
    this.size = 32,
    this.upperColor = const Color(0xFFEAF4FA),
    this.lowerColor = const Color(0xFF7DD3FC),
    this.tight = false,
  });

  final double size;
  final Color upperColor;
  final Color lowerColor;
  final bool tight;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _SoneaLogoPainter(
            upperColor: upperColor,
            lowerColor: lowerColor,
            tight: tight,
          ),
        ),
      ),
    );
  }
}

class _SoneaLogoPainter extends CustomPainter {
  const _SoneaLogoPainter({
    required this.upperColor,
    required this.lowerColor,
    required this.tight,
  });

  final Color upperColor;
  final Color lowerColor;
  final bool tight;

  @override
  void paint(Canvas canvas, Size size) {
    final minDim = size.width < size.height ? size.width : size.height;
    final viewport = tight ? 256.0 : 512.0;
    final originOffset = tight ? 128.0 : 0.0;
    final scale = minDim / viewport;
    final dx = (size.width - viewport * scale) / 2.0 - originOffset * scale;
    final dy = (size.height - viewport * scale) / 2.0 - originOffset * scale;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale, scale);

    final upperPaint = Paint()
      ..color = upperColor
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final lowerPaint = Paint()
      ..color = lowerColor
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    // Upper ribbon:
    // M 154 202 C 150 256 184 282 220 266 L 198 302 L 278 214 C 302 188 320 186 332 194 L 354 164 C 316 128 272 142 238 186 C 210 222 178 242 154 202 Z
    final upperPath = Path()
      ..moveTo(154, 202)
      ..cubicTo(150, 256, 184, 282, 220, 266)
      ..lineTo(198, 302)
      ..lineTo(278, 214)
      ..cubicTo(302, 188, 320, 186, 332, 194)
      ..lineTo(354, 164)
      ..cubicTo(316, 128, 272, 142, 238, 186)
      ..cubicTo(210, 222, 178, 242, 154, 202)
      ..close();

    // Lower ribbon:
    // M 358 310 C 362 256 328 230 292 246 L 314 210 L 234 298 C 210 324 192 326 180 318 L 158 348 C 196 384 240 370 274 326 C 302 290 334 270 358 310 Z
    final lowerPath = Path()
      ..moveTo(358, 310)
      ..cubicTo(362, 256, 328, 230, 292, 246)
      ..lineTo(314, 210)
      ..lineTo(234, 298)
      ..cubicTo(210, 324, 192, 326, 180, 318)
      ..lineTo(158, 348)
      ..cubicTo(196, 384, 240, 370, 274, 326)
      ..cubicTo(302, 290, 334, 270, 358, 310)
      ..close();

    canvas.drawPath(upperPath, upperPaint);
    canvas.drawPath(lowerPath, lowerPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SoneaLogoPainter oldDelegate) {
    return oldDelegate.upperColor != upperColor ||
        oldDelegate.lowerColor != lowerColor ||
        oldDelegate.tight != tight;
  }
}
