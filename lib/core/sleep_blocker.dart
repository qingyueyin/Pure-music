import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';

typedef _SetThreadExecutionStateNative = ffi.Uint32 Function(ffi.Uint32 esFlags);
typedef _SetThreadExecutionStateDart = int Function(int esFlags);

class SleepBlocker {
  static SleepBlocker? _instance;
  SleepBlocker._();
  static SleepBlocker get instance => _instance ??= SleepBlocker._();

  _SetThreadExecutionStateDart? _setThreadExecutionState;
  bool _blocked = false;
  bool _pageVisible = false;
  bool _playerPlaying = false;

  static const int _esContinuous = 0x80000000;
  static const int _esSystemRequired = 0x00000001;
  static const int _esDisplayRequired = 0x00000002;

  bool get _shouldBlock =>
      _pageVisible &&
      _playerPlaying &&
      AppSettings.instance.preventSleepOnNowPlaying;

  void _load() {
    if (_setThreadExecutionState != null) return;
    try {
      final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
      _setThreadExecutionState = kernel32
          .lookupFunction<_SetThreadExecutionStateNative, _SetThreadExecutionStateDart>(
            'SetThreadExecutionState',
          );
      logger.i('[sleep_blocker] loaded SetThreadExecutionState');
    } catch (e, trace) {
      logger.w('[sleep_blocker] failed to load SetThreadExecutionState: $e\n$trace');
    }
  }

  void setPageVisible(bool visible) {
    logger.i('[sleep_blocker] setPageVisible: $visible (was: $_pageVisible)');
    _pageVisible = visible;
  }

  void setPlayerPlaying(bool playing) {
    logger.i('[sleep_blocker] setPlayerPlaying: $playing (was: $_playerPlaying)');
    _playerPlaying = playing;
  }

  void block() {
    if (!_shouldBlock) return;
    if (_blocked) return;
    if (!Platform.isWindows) return;
    _load();
    final fn = _setThreadExecutionState;
    if (fn == null) return;
    try {
      fn(_esContinuous | _esSystemRequired | _esDisplayRequired);
      _blocked = true;
    } catch (e) {
      logger.w('[sleep_blocker] block failed: $e');
    }
  }

  void unblock() {
    if (!_blocked) return;
    if (!Platform.isWindows) return;
    _load();
    final fn = _setThreadExecutionState;
    if (fn == null) return;
    try {
      fn(_esContinuous);
      _blocked = false;
    } catch (e) {
      logger.w('[sleep_blocker] unblock failed: $e');
    }
  }

  /// 页面可见性、播放状态或设置变更时调用，重新评估是否需要阻止
  void reevaluate() {
    logger.i('[sleep_blocker] reevaluate: _pageVisible=$_pageVisible, _playerPlaying=$_playerPlaying, preventSleep=${AppSettings.instance.preventSleepOnNowPlaying}, _shouldBlock=$_shouldBlock, _blocked=$_blocked');
    if (_shouldBlock) {
      block();
    } else {
      unblock();
    }
  }
}
