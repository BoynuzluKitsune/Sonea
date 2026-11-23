import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/l10n/app_strings.dart';
import 'package:sonea/playback/equalizer_controller.dart';
import 'package:sonea/theme/sonea_theme_tokens.dart';

class EqualizerDialog extends ConsumerWidget {
  const EqualizerDialog({super.key});

  static const List<String> _bandLabels = [
    '60Hz',
    '230Hz',
    '910Hz',
    '3.6kHz',
    '14kHz'
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eqState = ref.watch(equalizerControllerProvider);
    final eqController = ref.read(equalizerControllerProvider.notifier);
    final strings = ref.watch(stringsProvider);
    final tokens = SoneaThemeTokens.of(context);

    return AlertDialog(
      backgroundColor: tokens.surfaceColor,
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              strings.equalizerTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.displayStyle(color: tokens.textColor),
            ),
          ),
          Switch(
            value: eqState.enabled,
            activeTrackColor: tokens.accentColor,
            onChanged: eqController.setEnabled,
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Preset Dropdown
            Text(
              strings.isTurkish ? 'Hazır Ayarlar' : 'Presets',
              style: TextStyle(fontSize: 12, color: tokens.subtextColor),
            ),
            const SizedBox(height: 4),
            DropdownButton<String>(
              value: EqualizerController.presets.containsKey(eqState.presetName)
                  ? eqState.presetName
                  : null,
              hint: Text(
                eqState.presetName,
                style: TextStyle(color: tokens.accentColor),
              ),
              dropdownColor: tokens.surfaceColor,
              isExpanded: true,
              items: EqualizerController.presets.keys.map((p) {
                return DropdownMenuItem<String>(
                  value: p,
                  child: Text(p, style: TextStyle(color: tokens.textColor)),
                );
              }).toList(),
              onChanged: (val) {
                if (val != null) eqController.selectPreset(val);
              },
            ),
            const SizedBox(height: 16),

            // 5 Band Gain Sliders
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(5, (index) {
                final gainDb = eqState.bandGains[index];
                return Expanded(
                  child: Column(
                    children: [
                      Text(
                        '${gainDb > 0 ? "+" : ""}${gainDb.toStringAsFixed(0)}dB',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          fontFeatures: kTabularFigures,
                          color: eqState.enabled
                              ? tokens.accentColor
                              : tokens.subtextColor,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 140,
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: Slider(
                            value: gainDb,
                            min: -12.0,
                            max: 12.0,
                            activeColor: tokens.accentColor,
                            inactiveColor:
                                tokens.subtextColor.withValues(alpha: 0.2),
                            onChanged: eqState.enabled
                                ? (val) => eqController.setBandGain(index, val)
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _bandLabels[index],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          fontFeatures: kTabularFigures,
                          color: tokens.subtextColor,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.close),
        ),
      ],
    );
  }
}
