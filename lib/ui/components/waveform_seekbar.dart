import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/playback/playback_controller.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';

class IsolatedSeekBar extends ConsumerWidget {
  const IsolatedSeekBar({super.key});

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(
      playbackControllerProvider.select(
        (s) => s.value?.position ?? Duration.zero,
      ),
    );
    final duration = ref.watch(
      playbackControllerProvider.select(
        (s) => s.value?.duration ?? Duration.zero,
      ),
    );
    final controller = ref.read(playbackControllerProvider.notifier);
    final tokens = SoneaThemeTokens.of(context);

    final posMs = position.inMilliseconds.toDouble();
    final durMs = duration.inMilliseconds.toDouble();
    final maxMs = durMs > 0 && durMs >= posMs ? durMs : (posMs > 0 ? posMs : 1.0);
    final safePos = posMs.clamp(0.0, maxMs);
    final progress = (safePos / maxMs).clamp(0.0, 1.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tokens.progressBarStyle == ProgressBarStyle.waveform)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (details) {
              final box = context.findRenderObject() as RenderBox?;
              if (box != null) {
                final localX = details.localPosition.dx.clamp(0.0, box.size.width);
                final ratio = localX / box.size.width;
                controller.seek(Duration(milliseconds: (maxMs * ratio).toInt()));
              }
            },
            onTapDown: (details) {
              final box = context.findRenderObject() as RenderBox?;
              if (box != null) {
                final localX = details.localPosition.dx.clamp(0.0, box.size.width);
                final ratio = localX / box.size.width;
                controller.seek(Duration(milliseconds: (maxMs * ratio).toInt()));
              }
            },
            child: SizedBox(
              height: 36,
              width: double.infinity,
              child: CustomPaint(
                painter: WaveformPainter(
                  progress: progress,
                  activeColor: tokens.accentColor,
                  inactiveColor: tokens.subtextColor.withValues(alpha: 0.3),
                ),
              ),
            ),
          )
        else
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              activeTrackColor: tokens.accentColor,
              inactiveTrackColor: tokens.subtextColor.withValues(alpha: 0.25),
              thumbColor: tokens.accentColor,
            ),
            child: Slider(
              value: safePos,
              min: 0.0,
              max: maxMs,
              onChanged: (val) {
                controller.seek(Duration(milliseconds: val.toInt()));
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(position),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: tokens.subtextColor,
                  fontFeatures: kTabularFigures,
                ),
              ),
              Text(
                _formatDuration(duration),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: tokens.subtextColor,
                  fontFeatures: kTabularFigures,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  static final List<double> _seedHeights = List.generate(48, (i) {
    return 0.2 + 0.8 * math.sin((i * 0.4) + (i % 3) * 0.5).abs();
  });

  @override
  void paint(Canvas canvas, Size size) {
    const barWidth = 3.0;
    const gap = 3.0;
    final totalBars = (size.width / (barWidth + gap)).floor();
    if (totalBars <= 0) return;

    final activeCutoff = size.width * progress;
    final activePaint = Paint()
      ..color = activeColor
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;
    final inactivePaint = Paint()
      ..color = inactiveColor
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;

    for (int i = 0; i < totalBars; i++) {
      final x = i * (barWidth + gap) + gap / 2;
      final seedIdx = i % _seedHeights.length;
      final normalizedHeight = _seedHeights[seedIdx];
      final barHeight = (size.height * 0.75) * normalizedHeight;
      final yTop = (size.height - barHeight) / 2;

      canvas.drawLine(
        Offset(x, yTop),
        Offset(x, yTop + barHeight),
        x <= activeCutoff ? activePaint : inactivePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor;
  }
}
