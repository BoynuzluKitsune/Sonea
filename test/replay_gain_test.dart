import 'package:flutter_test/flutter_test.dart';
import 'package:sonea/playback/replay_gain_controller.dart';

void main() {
  group('ReplayGainState Unit Tests', () {
    test('Mode OFF always returns 1.0 multiplier', () {
      const state = ReplayGainState(
        mode: ReplayGainMode.off,
        preAmpGainDb: 3.0,
      );
      final mult = state.computeVolumeMultiplier(
        trackGainDb: -6.0,
        albumGainDb: -4.0,
        trackPeak: 1.0,
      );
      expect(mult, equals(1.0));
    });

    test('Track Gain mode computes correct decibel formula', () {
      const state = ReplayGainState(
        mode: ReplayGainMode.track,
        preAmpGainDb: 0.0,
        preventClipping: false,
      );
      // -6 dB => 10^(-6/20) ~ 0.501187
      final mult = state.computeVolumeMultiplier(trackGainDb: -6.0);
      expect(mult, closeTo(0.501, 0.01));
    });

    test('Album Gain mode uses album gain over track gain', () {
      const state = ReplayGainState(
        mode: ReplayGainMode.album,
        preAmpGainDb: 0.0,
        preventClipping: false,
      );
      // Album gain -3 dB => ~0.7079
      final mult = state.computeVolumeMultiplier(
        trackGainDb: -10.0,
        albumGainDb: -3.0,
      );
      expect(mult, closeTo(0.7079, 0.01));
    });

    test('Pre-amp gain modifies calculation', () {
      const state = ReplayGainState(
        mode: ReplayGainMode.track,
        preAmpGainDb: 6.0,
        preventClipping: false,
      );
      // Track gain -6 dB + Pre-amp +6 dB = 0 dB => 1.0 multiplier
      final mult = state.computeVolumeMultiplier(trackGainDb: -6.0);
      expect(mult, closeTo(1.0, 0.001));
    });

    test('Anti-clipping caps volume at 1.0 / peak', () {
      const state = ReplayGainState(
        mode: ReplayGainMode.track,
        preAmpGainDb: 6.0,
        preventClipping: true,
      );
      // +6 dB boost on peak 1.2 => max allowed is 1.0/1.2 = 0.8333
      final mult = state.computeVolumeMultiplier(
        trackGainDb: 0.0,
        trackPeak: 1.2,
      );
      expect(mult, closeTo(1.0 / 1.2, 0.001));
    });
  });
}
