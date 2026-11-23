import 'dart:math';
import 'package:sonea/src/rust/api/library.dart';

enum RepeatMode { off, all, one }

class QueueManager {
  QueueManager({
    List<Track>? tracks,
    int initialIndex = 0,
    bool isShuffleEnabled = false,
    RepeatMode repeatMode = RepeatMode.off,
    Random? random,
  })  : _random = random ?? Random(),
        _originalQueue = List<Track>.from(tracks ?? const []) {
    _isShuffleEnabled = isShuffleEnabled;
    _repeatMode = repeatMode;
    if (_originalQueue.isNotEmpty) {
      final safeIndex = initialIndex.clamp(0, _originalQueue.length - 1);
      if (_isShuffleEnabled) {
        _generateShuffledIndices(startingOriginalIndex: safeIndex);
        _currentIndex = 0;
      } else {
        _currentIndex = safeIndex;
      }
    } else {
      _currentIndex = 0;
    }
  }

  final Random _random;
  List<Track> _originalQueue;
  List<int> _shuffledIndices = [];
  int _currentIndex = 0;
  bool _isShuffleEnabled = false;
  RepeatMode _repeatMode = RepeatMode.off;

  List<Track> get originalQueue => List.unmodifiable(_originalQueue);
  bool get isShuffleEnabled => _isShuffleEnabled;
  RepeatMode get repeatMode => _repeatMode;
  int get currentIndex => _currentIndex;

  List<Track> get effectiveQueue {
    if (_originalQueue.isEmpty) return const [];
    if (!_isShuffleEnabled) return List.unmodifiable(_originalQueue);
    return List.unmodifiable(
      _shuffledIndices.map((i) => _originalQueue[i]),
    );
  }

  Track? get currentTrack {
    final queue = effectiveQueue;
    if (queue.isEmpty || _currentIndex < 0 || _currentIndex >= queue.length) {
      return null;
    }
    return queue[_currentIndex];
  }

  void setQueue(
    List<Track> tracks, {
    int initialIndex = 0,
    bool? shuffle,
    bool pickRandomStart = false,
  }) {
    _originalQueue = List<Track>.from(tracks);
    if (shuffle != null) {
      _isShuffleEnabled = shuffle;
    }

    if (_originalQueue.isEmpty) {
      _currentIndex = 0;
      _shuffledIndices = [];
      return;
    }

    if (_isShuffleEnabled) {
      if (pickRandomStart) {
        _generateFullShuffledIndices();
      } else {
        final safeIndex = initialIndex.clamp(0, _originalQueue.length - 1);
        _generateShuffledIndices(startingOriginalIndex: safeIndex);
      }
      _currentIndex = 0;
    } else {
      final safeIndex = initialIndex.clamp(0, _originalQueue.length - 1);
      _currentIndex = safeIndex;
      _shuffledIndices = [];
    }
  }

  void setShuffleMode(bool enabled) {
    if (_isShuffleEnabled == enabled) return;
    if (_originalQueue.isEmpty) {
      _isShuffleEnabled = enabled;
      return;
    }

    final currentItem = currentTrack;
    _isShuffleEnabled = enabled;

    if (enabled) {
      final currentOriginalIndex = currentItem != null
          ? _originalQueue.indexOf(currentItem)
          : 0;
      final safeIndex = currentOriginalIndex < 0 ? 0 : currentOriginalIndex;
      _generateShuffledIndices(startingOriginalIndex: safeIndex);
      _currentIndex = 0;
    } else {
      if (currentItem != null) {
        final originalIdx = _originalQueue.indexOf(currentItem);
        _currentIndex = originalIdx < 0 ? 0 : originalIdx;
      } else {
        _currentIndex = 0;
      }
      _shuffledIndices = [];
    }
  }

  void setRepeatMode(RepeatMode mode) {
    _repeatMode = mode;
  }

  int? getNextIndex() {
    final queue = effectiveQueue;
    if (queue.isEmpty) return null;

    if (_repeatMode == RepeatMode.one) {
      return _currentIndex;
    }

    if (_currentIndex + 1 < queue.length) {
      return _currentIndex + 1;
    }

    if (_repeatMode == RepeatMode.all) {
      return 0;
    }

    return null;
  }

  int? next() {
    final idx = getNextIndex();
    if (idx != null) {
      _currentIndex = idx;
    }
    return idx;
  }

  int? getPreviousIndex() {
    final queue = effectiveQueue;
    if (queue.isEmpty) return null;

    if (_repeatMode == RepeatMode.one) {
      return _currentIndex;
    }

    if (_currentIndex - 1 >= 0) {
      return _currentIndex - 1;
    }

    if (_repeatMode == RepeatMode.all) {
      return queue.length - 1;
    }

    return null;
  }

  int? previous() {
    final idx = getPreviousIndex();
    if (idx != null) {
      _currentIndex = idx;
    }
    return idx;
  }

  bool jumpToIndex(int index) {
    final queue = effectiveQueue;
    if (queue.isEmpty || index < 0 || index >= queue.length) {
      return false;
    }
    _currentIndex = index;
    return true;
  }

  void playNext(Track track) {
    if (_originalQueue.isEmpty) {
      setQueue([track], initialIndex: 0);
      return;
    }

    final queue = effectiveQueue;
    final insertEffectiveIdx = (_currentIndex + 1).clamp(0, queue.length);

    if (!_isShuffleEnabled) {
      _originalQueue.insert(insertEffectiveIdx, track);
    } else {
      final newOrigIdx = _originalQueue.length;
      _originalQueue.add(track);
      _shuffledIndices.insert(insertEffectiveIdx, newOrigIdx);
    }
  }

  void addToQueue(Track track) {
    if (_originalQueue.isEmpty) {
      setQueue([track], initialIndex: 0);
      return;
    }

    if (!_isShuffleEnabled) {
      _originalQueue.add(track);
    } else {
      final newOrigIdx = _originalQueue.length;
      _originalQueue.add(track);
      _shuffledIndices.add(newOrigIdx);
    }
  }

  void addAllToQueue(List<Track> tracks) {
    for (final t in tracks) {
      addToQueue(t);
    }
  }

  void reorderQueue(int oldIndex, int newIndex) {
    final queue = effectiveQueue;
    if (oldIndex < 0 || oldIndex >= queue.length || newIndex < 0 || newIndex >= queue.length) {
      return;
    }

    if (!_isShuffleEnabled) {
      final item = _originalQueue.removeAt(oldIndex);
      _originalQueue.insert(newIndex, item);
    } else {
      final item = _shuffledIndices.removeAt(oldIndex);
      _shuffledIndices.insert(newIndex, item);
    }

    if (oldIndex == _currentIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex -= 1;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex += 1;
    }
  }

  void removeFromQueue(int index) {
    final queue = effectiveQueue;
    if (queue.isEmpty || index < 0 || index >= queue.length) return;

    if (!_isShuffleEnabled) {
      _originalQueue.removeAt(index);
    } else {
      final origIdx = _shuffledIndices.removeAt(index);
      if (origIdx < _originalQueue.length) {
        _originalQueue.removeAt(origIdx);
        for (int i = 0; i < _shuffledIndices.length; i++) {
          if (_shuffledIndices[i] > origIdx) {
            _shuffledIndices[i] -= 1;
          }
        }
      }
    }

    if (_originalQueue.isEmpty) {
      _currentIndex = 0;
    } else if (index < _currentIndex) {
      _currentIndex -= 1;
    } else if (_currentIndex >= effectiveQueue.length) {
      _currentIndex = effectiveQueue.length - 1;
    }
  }

  void _generateShuffledIndices({required int startingOriginalIndex}) {
    final indices = List<int>.generate(_originalQueue.length, (i) => i);
    indices.remove(startingOriginalIndex);
    indices.shuffle(_random);
    _shuffledIndices = [startingOriginalIndex, ...indices];
  }

  void _generateFullShuffledIndices() {
    final indices = List<int>.generate(_originalQueue.length, (i) => i);
    indices.shuffle(_random);
    _shuffledIndices = indices;
  }
}
