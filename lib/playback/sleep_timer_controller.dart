import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sonea/playback/playback_controller.dart';

class SleepTimerState {
  const SleepTimerState({
    this.remainingSeconds,
    this.isEndOfTrack = false,
  });

  final int? remainingSeconds;
  final bool isEndOfTrack;

  bool get isActive => remainingSeconds != null || isEndOfTrack;
}

final sleepTimerControllerProvider =
    NotifierProvider<SleepTimerController, SleepTimerState>(
  SleepTimerController.new,
);

class SleepTimerController extends Notifier<SleepTimerState> {
  Timer? _timer;
  bool _expiring = false;

  @override
  SleepTimerState build() {
    ref.listen<int?>(
      playbackControllerProvider.select((s) => s.value?.currentIndex),
      (prev, next) {
        if (state.isEndOfTrack &&
            prev != null &&
            next != null &&
            next != prev) {
          unawaited(_executeTimerExpiry());
        }
      },
    );
    ref.onDispose(() => _timer?.cancel());
    return const SleepTimerState();
  }

  void startTimer(int minutes) {
    _timer?.cancel();
    final totalSec = minutes * 60;
    state = SleepTimerState(remainingSeconds: totalSec);

    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      final rem = state.remainingSeconds;
      if (rem == null || rem <= 1) {
        _timer?.cancel();
        unawaited(_executeTimerExpiry());
      } else {
        state = SleepTimerState(remainingSeconds: rem - 1);
      }
    });
  }

  void setEndOfTrack() {
    _timer?.cancel();
    state = const SleepTimerState(isEndOfTrack: true);
  }

  void cancelTimer() {
    _timer?.cancel();
    state = const SleepTimerState();
  }

  Future<void> _executeTimerExpiry() async {
    if (_expiring) return;
    _expiring = true;
    try {
      final controller = ref.read(playbackControllerProvider.notifier);
      final playbackState = ref.read(playbackControllerProvider).value;
      final savedVolume = playbackState?.volume ?? 1.0;
      final wasMuted = playbackState?.isMuted ?? false;

      if (!wasMuted && savedVolume > 0) {
        // Smooth 2.5-second volume fade-out relative to user's volume
        for (int i = 10; i >= 0; i--) {
          if (!state.isActive) break;
          await controller.setVolume(savedVolume * (i / 10.0));
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }

      await controller.pause();
      await controller.setVolume(savedVolume);
      if (wasMuted) {
        await controller.setMuted(true);
      }
      state = const SleepTimerState();
    } finally {
      _expiring = false;
    }
  }
}
