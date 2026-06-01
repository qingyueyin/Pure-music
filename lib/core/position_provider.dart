import 'dart:async';
import 'package:flutter/foundation.dart';

import 'package:pure_music/play_service/play_service.dart';

/// A throttled position provider that listens to the playback service's
/// position stream and exposes the current position as a value notifier.
/// This avoids excessive rebuilds by decoupling position updates from
/// the raw stream events.
///
/// 使用引用计数管理 Stream 订阅：当有监听器时自动订阅，无监听器时自动取消。
/// 避免全局单例永久持有 Stream subscription 导致的内存泄漏。
class ThrottledPositionProvider extends ChangeNotifier {
  ThrottledPositionProvider._();

  static final ThrottledPositionProvider instance = ThrottledPositionProvider._();

  double _position = 0.0;
  double get position => _position;

  StreamSubscription<double>? _sub;
  int _listenerCount = 0;

  @override
  void addListener(VoidCallback listener) {
    final wasEmpty = _listenerCount == 0;
    super.addListener(listener);
    _listenerCount++;
    if (wasEmpty) {
      _subscribe();
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _listenerCount--;
    if (_listenerCount <= 0) {
      _listenerCount = 0;
      _unsubscribe();
    }
  }

  void _subscribe() {
    if (_sub != null) return;
    // 退出时 PlayService 可能已被销毁，防御性检查
    try {
      final service = PlayService.instance;
      _sub = service.playbackService.positionStream.listen((pos) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastUpdateMs < 16) return;
        _lastUpdateMs = now;
        _position = pos;
        notifyListeners();
      });
    } catch (_) {
      // PlayService 已关闭，不再订阅
      _sub = null;
    }
  }

  void _unsubscribe() {
    _sub?.cancel();
    _sub = null;
  }

  int _lastUpdateMs = 0;

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }
}
