import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:pure_music/core/cache.dart';

/// 统一性能探针：组件重建计数、帧耗时（build/raster）、事件流、分层开关。
///
/// 默认在 debug/profile 生效；release 需要 `--dart-define=PERF_PROBE=true`。
/// 事件以 JSONL 写入 `PURE_MUSIC_PERF_PROBE_LOG` 指定的文件（默认
/// `build/performance/perf-probe-<pid>.jsonl`）。
class PerfProbe {
  PerfProbe._();

  static const bool _compileEnabled = bool.fromEnvironment(
    'PERF_PROBE',
    defaultValue: false,
  );

  static bool get enabled => _compileEnabled || kDebugMode || kProfileMode;

  // ---------------------------------------------------------------- 重建计数

  static final Map<String, int> _buildCounts = <String, int>{};

  /// 在组件 build 开头调用。关闭时是一个空调用，release 可被裁剪。
  static void countBuild(String name) {
    if (!enabled) return;
    _buildCounts[name] = (_buildCounts[name] ?? 0) + 1;
  }

  static Map<String, int> get buildCounts =>
      Map<String, int>.unmodifiable(_buildCounts);

  static void resetBuildCounts() {
    _buildCounts.clear();
  }

  // ---------------------------------------------------------------- 帧耗时

  static const int _maxFrameSamples = 200000;
  static final List<int> _buildMicros = <int>[];
  static final List<int> _rasterMicros = <int>[];
  static final List<int> _totalMicros = <int>[];
  static bool _timingsHooked = false;
  static String _frameLabel = '';
  static Timer? _reportTimer;
  static final List<Map<String, Object?>> _slowFrames = <Map<String, Object?>>[];
  static int _reportTicks = 0;
  static int _buildMaxMicros = 0;
  static int _rasterMaxMicros = 0;
  static int _jankFrames = 0;

  static void startFrameCapture(String label) {
    if (!enabled) return;
    _frameLabel = label;
    _buildMicros.clear();
    _rasterMicros.clear();
    _totalMicros.clear();
    _buildMaxMicros = 0;
    _rasterMaxMicros = 0;
    _jankFrames = 0;
    _reportTicks = 0;
    _slowFrames.clear();
    if (!_timingsHooked) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _timingsHooked = true;
    }
    // 自动切歌脚本用 exit(0) 结束，dispose 不会触发；周期落盘保证有结果。
    // 每 5 秒只写轻量统计，每 60 秒才算一次分位，避免探针自己拖慢帧。
    _reportTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      _reportTicks++;
      writeReportIfRequested(full: _reportTicks % 12 == 0);
    });
    event('frame_capture_start', {'label': label});
  }

  static void stopFrameCapture() {
    if (!enabled) return;
    _reportTimer?.cancel();
    _reportTimer = null;
    if (_timingsHooked) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _timingsHooked = false;
    }
    event('frame_capture_stop', frameStats());
    writeReportIfRequested(full: true);
  }

  static void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      if (_buildMicros.length >= _maxFrameSamples) break;
      final build = timing.buildDuration.inMicroseconds;
      final raster = timing.rasterDuration.inMicroseconds;
      final work = build + raster;
      _buildMicros.add(build);
      _rasterMicros.add(raster);
      _totalMicros.add(work);
      if (build > _buildMaxMicros) _buildMaxMicros = build;
      if (raster > _rasterMaxMicros) _rasterMaxMicros = raster;
      // 用 build+raster 判卡顿：totalSpan 包含等 vsync/排队，会把空闲也算成 jank。
      if (work > 16700) _jankFrames++;
      // 记录慢帧，区分是 build 还是 raster 拖慢（上限 200 条，写进报告，避免 UI 线程 I/O）。
      if (work >= 50000 && _slowFrames.length < 200) {
        _slowFrames.add({
          'buildMs': build / 1000,
          'rasterMs': raster / 1000,
          'workMs': work / 1000,
          // 收到该帧的时间戳，用来和封面解码等事件对齐。
          'tsMs': DateTime.now().millisecondsSinceEpoch,
          // 该帧在会话中的序号，用来区分首帧引擎开销和后续负载。
          'frameIndex': _buildMicros.length,
        });
      }
    }
  }

  static Map<String, Object?> frameStats({bool full = true}) {
    return {
      'label': _frameLabel,
      'frames': _buildMicros.length,
      'buildP50Ms': full ? _ms(_percentile(_buildMicros, 50)) : null,
      'buildP95Ms': full ? _ms(_percentile(_buildMicros, 95)) : null,
      'buildMaxMs': _ms(_buildMaxMicros.toDouble()),
      'rasterP50Ms': full ? _ms(_percentile(_rasterMicros, 50)) : null,
      'rasterP95Ms': full ? _ms(_percentile(_rasterMicros, 95)) : null,
      'rasterMaxMs': _ms(_rasterMaxMicros.toDouble()),
      'workP95Ms': full ? _ms(_percentile(_totalMicros, 95)) : null,
      'jankFrames': _jankFrames,
    };
  }

  static double _ms(double micros) =>
      double.parse((micros / 1000).toStringAsFixed(2));

  static Map<String, Object?> _imageCacheStats() {
    try {
      final cache = PaintingBinding.instance.imageCache;
      return {
        'count': cache.currentSize,
        'bytes': cache.currentSizeBytes,
        'maxBytes': cache.maximumSizeBytes,
      };
    } catch (_) {
      return const {};
    }
  }

  static Map<String, Object?> _coverCacheStats() {
    try {
      final stats = CoverImageCache.instance.stats;
      return {
        'small': stats.smallEntries,
        'medium': stats.mediumEntries,
        'large': stats.largeEntries,
        'bytes': stats.totalBytes,
        'hits': stats.hits,
        'misses': stats.misses,
      };
    } catch (_) {
      return const {};
    }
  }

  /// 返回该分位的值（微秒）。列表会被复制排序，只在停止采集时调用。
  static double _percentile(List<int> values, int percentile) {
    if (values.isEmpty) return 0;
    final sorted = List<int>.of(values)..sort();
    final index = ((sorted.length - 1) * percentile / 100).round();
    return sorted[index].toDouble();
  }

  // ---------------------------------------------------------------- 事件流

  static String? _logPath;

  static String? get logPath => _logPath;

  static void event(String name, [Map<String, Object?> data = const {}]) {
    if (!enabled) return;
    try {
      final path = _logPath ?? _resolveLogPath();
      if (path == null) return;
      final line = jsonEncode({
        'ts': DateTime.now().toIso8601String(),
        'event': name,
        if (data.isNotEmpty) 'data': data,
      });
      File(path).writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {
      // 探针自身不能影响主流程。
    }
  }

  static String? _resolveLogPath() {
    final configured = Platform.environment['PURE_MUSIC_PERF_PROBE_LOG'];
    final path = (configured == null || configured.isEmpty)
        ? 'build/performance/perf-probe-$pid.jsonl'
        : configured;
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      _logPath = file.path;
      return file.path;
    } catch (_) {
      return null;
    }
  }

  static Future<void> flush() async {}

  /// 写一份汇总报告到 `PURE_MUSIC_PERF_PROBE_REPORT`，供脚本读取。
  static void writeReportIfRequested({bool full = false}) {
    if (!enabled) return;
    if (full) {
      // 最终报告写完后停掉周期写，避免 5 秒后又被轻量报告覆盖。
      _reportTimer?.cancel();
      _reportTimer = null;
    }
    final path = Platform.environment['PURE_MUSIC_PERF_PROBE_REPORT'];
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'buildCounts': buildCounts,
          'frameStats': frameStats(full: full),
          'slowFrames': List<Map<String, Object?>>.unmodifiable(_slowFrames),
          'imageCache': _imageCacheStats(),
          'coverCache': _coverCacheStats(),
          'rssMB': ProcessInfo.currentRss ~/ (1024 * 1024),
        }),
      );
    } catch (_) {}
  }
}

/// 歌词渲染的分层开关，用于定位 GPU 开销来自哪一层。
///
/// 通过环境变量 `PERF_LAYERS` 指定要关闭的层，逗号分隔：
/// `glow,shadow,blur,mask,spectrum,background`。
class PerfLayers {
  PerfLayers._();

  static final Set<String> disabled = _parse(
    Platform.environment['PERF_LAYERS'],
  );

  static Set<String> _parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <String>{};
    return raw
        .split(',')
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  static bool get glow => !disabled.contains('glow');
  static bool get shadow => !disabled.contains('shadow');
  static bool get blur => !disabled.contains('blur');
  static bool get mask => !disabled.contains('mask');
  static bool get spectrum => !disabled.contains('spectrum');
  static bool get background => !disabled.contains('background');
  static bool get lyrics => !disabled.contains('lyrics');
  static bool get theme => !disabled.contains('theme');
  static bool get cover => !disabled.contains('cover');
}

/// 运行态浮层：重建计数 + 帧耗时。用 `PERF_OVERLAY=1` 打开。
class PerfOverlay extends StatefulWidget {
  const PerfOverlay({super.key, required this.child});

  final Widget child;

  static bool get enabled =>
      Platform.environment['PERF_OVERLAY'] == '1' &&
      (PerfProbe.enabled);

  @override
  State<PerfOverlay> createState() => _PerfOverlayState();
}

class _PerfOverlayState extends State<PerfOverlay> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (!PerfProbe.enabled) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!PerfProbe.enabled) return widget.child;
    final counts = PerfProbe.buildCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final stats = PerfProbe.frameStats();
    final lines = <String>[
      'builds: ${counts.take(5).map((e) => '${e.key}=${e.value}').join(' ')}',
      'frame p50/p95: ${stats['buildP50Ms']}/${stats['buildP95Ms']}ms '
          '(raster ${stats['rasterP50Ms']}/${stats['rasterP95Ms']}ms)',
      'jank: ${stats['jankFrames']}/${stats['frames']}',
      'layers off: ${PerfLayers.disabled.join(',')}',
    ];
    return Stack(
      children: [
        widget.child,
        Positioned(
          left: 12,
          top: 12,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.62),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: DefaultTextStyle(
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontFamily: 'Consolas',
                    height: 1.35,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final line in lines) Text(line),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
