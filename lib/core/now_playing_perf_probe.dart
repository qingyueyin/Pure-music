import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:pure_music/core/utils.dart';

/// 播放页性能探针：记下封面、前后段帧时间、20/50/80 首内存。
class NowPlayingPerfProbe {
  static final instance = NowPlayingPerfProbe._();
  NowPlayingPerfProbe._();

  static bool get _enabled => kDebugMode || kProfileMode;

  static const autoSwitches = int.fromEnvironment(
    'PERF_AUTO_SONG_SWITCHES',
    defaultValue: 0,
  );

  int _songChanges = 0;
  int _coverGen = 0;
  int _coverReportedGen = -1;
  Stopwatch? _coverWatch;
  int? _warmupRss;
  int _firstFrames = 0;
  int _firstJank = 0;
  int _firstMicros = 0;
  int _lastFrames = 0;
  int _lastJank = 0;
  int _lastMicros = 0;
  _FramePhase _framePhase = _FramePhase.idle;
  final List<Map<String, Object?>> _coverSamples = [];
  Map<String, Object?>? _song10;
  Map<String, Object?>? _songLast10;
  Map<String, Object?>? _rss20;
  Map<String, Object?>? _rss50;
  Map<String, Object?>? _rss80;

  int get _switchTarget => autoSwitches >= 80 ? autoSwitches : 80;
  int get _last10Start => _switchTarget - 9;

  int get songChanges => _songChanges;
  Map<String, Object?>? get song10 => _song10;
  Map<String, Object?>? get songLast10 => _songLast10;
  Map<String, Object?>? get rss80 => _rss80;

  Map<String, Object?> snapshot() {
    return {
      'songChanges': _songChanges,
      'coverVisible': List<Map<String, Object?>>.from(_coverSamples),
      'song10': _song10,
      'songLast10': _songLast10,
      'rss20': _rss20,
      'rss50': _rss50,
      'rss80': _rss80,
    };
  }

  /// 切歌帧探针开关：PURE_MUSIC_SWITCH_FRAME_LOG=1 时 release 也记录。
  static final bool _switchFrameLog =
      Platform.environment['PURE_MUSIC_SWITCH_FRAME_LOG'] == '1';
  static const _switchFrameWindow = Duration(milliseconds: 320);
  List<FrameTiming>? _switchFrames;
  Timer? _switchFrameTimer;
  String _switchReason = '';
  String _switchTitle = '';
  int _switchDurationSec = 0;

  void onSongChanged() {
    if (!_enabled) return;
    _songChanges++;
    _coverGen++;
    _coverWatch = Stopwatch()..start();
    if (_songChanges == 1) {
      _startFramePhase(_FramePhase.first10);
    }
    if (_songChanges == 10) {
      Future<void>.delayed(const Duration(seconds: 2), _finishFirst10);
    }
    if (_songChanges == _last10Start) {
      _startFramePhase(_FramePhase.last10);
    }
    if (_songChanges == 20) _captureRss(20);
    if (_songChanges == 50) _captureRss(50);
    if (_songChanges == 80) _captureRss(80);
    if (_songChanges == _switchTarget) {
      Future<void>.delayed(const Duration(seconds: 2), _finishLast10);
    }
  }

  void noteSongSwitch({
    required String reason,
    required String title,
    required int durationSec,
  }) {
    if (!_switchFrameLog) return;
    // 320ms 内连切时先落上一窗口，别把它的帧数据丢掉。
    _finishSwitchFrames();
    _switchReason = reason;
    _switchTitle = title;
    _switchDurationSec = durationSec;
    _switchFrames = [];
    SchedulerBinding.instance.addTimingsCallback(_onSwitchTimings);
    _switchFrameTimer = Timer(_switchFrameWindow, _finishSwitchFrames);
  }

  void _onSwitchTimings(List<FrameTiming> timings) {
    _switchFrames?.addAll(timings);
  }

  void _finishSwitchFrames() {
    _switchFrameTimer?.cancel();
    _switchFrameTimer = null;
    final frames = _switchFrames;
    if (frames == null) return;
    _switchFrames = null;
    SchedulerBinding.instance.removeTimingsCallback(_onSwitchTimings);
    if (frames.isEmpty) return;
    var maxMicros = 0;
    var totalMicros = 0;
    var over33 = 0;
    for (final timing in frames) {
      final micros =
          timing.buildDuration.inMicroseconds + timing.rasterDuration.inMicroseconds;
      totalMicros += micros;
      if (micros > maxMicros) maxMicros = micros;
      if (micros > 33000) over33++;
    }
    log.app.info(
      'legacy',
      '[perf] switchFrames reason=$_switchReason title=$_switchTitle '
          'dur=${_switchDurationSec}s n=${frames.length} '
          'avgMs=${(totalMicros / frames.length / 1000).toStringAsFixed(1)} '
          'maxMs=${(maxMicros / 1000).toStringAsFixed(1)} over33=$over33',
    );
  }

  void onCoverVisible({required bool fromCache}) {
    if (!_enabled) return;
    if (_coverReportedGen == _coverGen) return;
    final watch = _coverWatch;
    if (watch == null) return;
    _coverReportedGen = _coverGen;
    watch.stop();
    final ms = watch.elapsedMilliseconds;
    _coverSamples.add({'ms': ms, 'cache': fromCache});
    log.app.info('legacy', '[perf] coverVisible ms=$ms cache=$fromCache');
  }

  void writeReportIfRequested() {
    final path = Platform.environment['PURE_MUSIC_PERF_REPORT'];
    if (path == null || path.isEmpty) return;
    try {
      File(path).writeAsStringSync('${jsonEncode(snapshot())}\n');
    } catch (error, trace) {
      log.app.warn(
        'legacy',
        '[perf] write report failed: $error',
        stackTrace: trace,
      );
    }
  }

  void _captureRss(int mark) {
    final rss = ProcessInfo.currentRss;
    if (mark == 20) {
      _warmupRss = rss;
    }
    final warmup = _warmupRss ?? rss;
    final point = <String, Object?>{
      'rssMB': (rss / (1024 * 1024)).round(),
      'deltaMB': double.parse(
        ((rss - warmup) / (1024 * 1024)).toStringAsFixed(1),
      ),
    };
    if (mark == 20) {
      _rss20 = point;
    } else if (mark == 50) {
      _rss50 = point;
    } else if (mark == 80) {
      _rss80 = point;
    }
    log.app.info(
      'legacy',
      '[perf] rss$mark rssMB=${point['rssMB']} deltaMB=${point['deltaMB']}',
    );
    writeReportIfRequested();
  }

  void _startFramePhase(_FramePhase phase) {
    if (_framePhase == phase) return;
    _stopFrameListen();
    if (phase == _FramePhase.first10) {
      _firstFrames = 0;
      _firstJank = 0;
      _firstMicros = 0;
    } else {
      _lastFrames = 0;
      _lastJank = 0;
      _lastMicros = 0;
    }
    _framePhase = phase;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _stopFrameListen() {
    if (_framePhase == _FramePhase.idle) return;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _framePhase = _FramePhase.idle;
  }

  void _finishFirst10() {
    if (_framePhase != _FramePhase.first10) return;
    _stopFrameListen();
    final avgMs = _firstFrames <= 0 ? 0.0 : (_firstMicros / _firstFrames) / 1000;
    _song10 = {
      'frames': _firstFrames,
      'avgFrameMs': double.parse(avgMs.toStringAsFixed(1)),
      'jank': _firstJank,
    };
    log.app.info(
      'legacy',
      '[perf] song10 frames=$_firstFrames avgFrameMs=${avgMs.toStringAsFixed(1)} jank=$_firstJank',
    );
    writeReportIfRequested();
  }

  void _finishLast10() {
    if (_framePhase != _FramePhase.last10) return;
    _stopFrameListen();
    final avgMs = _lastFrames <= 0 ? 0.0 : (_lastMicros / _lastFrames) / 1000;
    _songLast10 = {
      'frames': _lastFrames,
      'avgFrameMs': double.parse(avgMs.toStringAsFixed(1)),
      'jank': _lastJank,
    };
    log.app.info(
      'legacy',
      '[perf] songLast10 frames=$_lastFrames avgFrameMs=${avgMs.toStringAsFixed(1)} jank=$_lastJank',
    );
    writeReportIfRequested();
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final total = timing.buildDuration + timing.rasterDuration;
      final isJank = total > const Duration(milliseconds: 18);
      if (_framePhase == _FramePhase.first10) {
        _firstFrames++;
        _firstMicros += total.inMicroseconds;
        if (isJank) _firstJank++;
      } else if (_framePhase == _FramePhase.last10) {
        _lastFrames++;
        _lastMicros += total.inMicroseconds;
        if (isJank) _lastJank++;
      }
    }
  }
}

enum _FramePhase { idle, first10, last10 }
