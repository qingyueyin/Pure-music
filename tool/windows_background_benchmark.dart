import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:ffi/ffi.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/native/rust/frb_generated.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background.dart';
import 'package:pure_music/play_service/smtc_bridge.dart';

final Uint8List _blueCover = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEUAAACnej3aAAAAAXRSTlMAQObYZgAAAApJREFUCNdjYAAAAAIAAeIhvDMAAAAASUVORK5CYII=',
);

final Uint8List _redCover = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAANSURBVBhXY/jPwPAfAAUAAf+mXJtdAAAAAElFTkSuQmCC',
);

final SyncLyricLine _benchmarkLyric = SyncLyricLine(
  Duration.zero,
  const Duration(seconds: 8),
  <SyncLyricWord>[
    SyncLyricWord(Duration.zero, const Duration(milliseconds: 720), 'Flowing '),
    SyncLyricWord(
      const Duration(milliseconds: 720),
      const Duration(milliseconds: 780),
      'colors ',
    ),
    SyncLyricWord(
      const Duration(milliseconds: 1500),
      const Duration(milliseconds: 950),
      'follow ',
    ),
    SyncLyricWord(
      const Duration(milliseconds: 2450),
      const Duration(milliseconds: 680),
      'every ',
    ),
    SyncLyricWord(
      const Duration(milliseconds: 3130),
      const Duration(milliseconds: 1700),
      'heartbeat',
    ),
  ],
  '流动的色彩跟随每一次心跳',
  'Liu dong de se cai gen sui mei yi ci xin tiao',
)
  ..bgWords = <SyncLyricWord>[
    SyncLyricWord(
      const Duration(milliseconds: 3300),
      const Duration(milliseconds: 900),
      'Stay ',
    ),
    SyncLyricWord(
      const Duration(milliseconds: 4200),
      const Duration(milliseconds: 1300),
      'close',
    ),
  ]
  ..bgText = 'Stay close'
  ..bgTranslation = '靠近一些'
  ..bgStart = const Duration(milliseconds: 3300)
  ..bgEnd = const Duration(milliseconds: 5500);

const _benchmarkLyricConfig = LyricRenderConfig(
  textAlign: LyricTextAlign.left,
  baseFontSize: 32,
  translationBaseFontSize: 28,
  showTranslation: true,
  showRoman: true,
  fontWeight: 700,
  enableBlur: true,
  enableGlow: true,
  liftStyle: LyricLiftStyle.cosine,
  liftPeak: 2.5,
  liftDurationMs: 300,
  staggerStyle: LyricStaggerStyle.spring,
);

const _steadyPhaseDuration = Duration(seconds: 15);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const _BackgroundBenchmarkApp());
}

class _BackgroundBenchmarkApp extends StatefulWidget {
  const _BackgroundBenchmarkApp();

  @override
  State<_BackgroundBenchmarkApp> createState() =>
      _BackgroundBenchmarkAppState();
}

class _BackgroundBenchmarkAppState extends State<_BackgroundBenchmarkApp> {
  final _spectrumController = StreamController<Float32List>.broadcast();
  final _timings = <FrameTiming>[];
  final _cpuClock = _WindowsCpuClock();
  late final Timer _spectrumTimer;
  late final Timer _lyricTimer;
  final _lyricTime = ValueNotifier<double>(0);
  final _lyricClock = Stopwatch();
  var _mode = NowPlayingBackgroundMode.meshGradient;
  var _cover = _blueCover;
  var _enableAnimation = true;
  var _showBackground = true;
  var _showLyrics = false;
  var _spectrumStep = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_collectTimings);
    _spectrumTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _spectrumStep++;
      final pulse = _spectrumStep.isEven ? 0.82 : 0.24;
      _spectrumController.add(
        Float32List.fromList(<double>[
          pulse,
          pulse * 0.72,
          0.35,
          0.24,
          0.18,
          0.12,
          0.08,
          0.04,
        ]),
      );
    });
    _lyricClock.start();
    _lyricTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _lyricTime.value = (_lyricClock.elapsedMilliseconds % 8000).toDouble();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runBenchmark());
    });
  }

  void _collectTimings(List<FrameTiming> values) => _timings.addAll(values);

  Future<void> _runBenchmark() async {
    try {
      debugPrint('PERF_PHASE warmup');
      await Future<void>.delayed(const Duration(seconds: 2));
      final reports = <Map<String, Object?>>[];
      reports.add(
        await _measurePhase('mesh_active', _steadyPhaseDuration),
      );

      setState(() => _enableAnimation = false);
      reports.add(
        await _measurePhase('mesh_idle', const Duration(seconds: 3)),
      );

      setState(() {
        _enableAnimation = true;
        _mode = NowPlayingBackgroundMode.flowingCover;
      });
      await Future<void>.delayed(const Duration(seconds: 1));
      reports.add(
        await _measurePhase('flow_active', _steadyPhaseDuration),
      );

      _timings.clear();
      final switchRssBefore = ProcessInfo.currentRss;
      debugPrint('PERF_PHASE cover_switch');
      final switchCpuBefore = _cpuClock.readSeconds();
      final switchClock = Stopwatch()..start();
      for (var i = 0; i < 8; i++) {
        setState(() => _cover = i.isEven ? _redCover : _blueCover);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      switchClock.stop();
      final switchRssAfter = ProcessInfo.currentRss;
      final switchCpuSeconds = _cpuClock.readSeconds() - switchCpuBefore;
      reports.add(<String, Object?>{
        'phase': 'cover_switch',
        'frames': _timings.length,
        'rssBeforeMb': _toMb(switchRssBefore),
        'rssAfterMb': _toMb(switchRssAfter),
        'rssGrowthMb': _toMb(switchRssAfter - switchRssBefore),
        ..._cpuReport(switchCpuSeconds, switchClock.elapsed),
      });

      setState(() {
        _showBackground = false;
        _showLyrics = true;
      });
      await Future<void>.delayed(const Duration(seconds: 1));
      reports.add(
        await _measurePhase('lyrics_active', _steadyPhaseDuration),
      );

      setState(() {
        _showBackground = true;
        _mode = NowPlayingBackgroundMode.meshGradient;
      });
      await Future<void>.delayed(const Duration(seconds: 1));
      reports.add(
        await _measurePhase(
          'mesh_with_lyrics',
          _steadyPhaseDuration,
        ),
      );

      setState(() => _mode = NowPlayingBackgroundMode.flowingCover);
      await Future<void>.delayed(const Duration(seconds: 1));
      reports.add(
        await _measurePhase(
          'flow_with_lyrics',
          _steadyPhaseDuration,
        ),
      );
      reports.add(await _measureSmtcPhase());

      debugPrint('PERF_REPORT ${jsonEncode(reports)}');
      RustLib.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (error, stackTrace) {
      debugPrint('PERF_ERROR $error\n$stackTrace');
      RustLib.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(1);
    }
  }

  Future<Map<String, Object?>> _measureSmtcPhase() async {
    debugPrint('PERF_PHASE smtc_stress');
    final tempDir = await Directory.systemTemp.createTemp(
      'pure_music_smtc_benchmark_',
    );
    final audioFile = File('${tempDir.path}\\silent.wav');
    await audioFile.writeAsBytes(_silentWavBytes(), flush: true);
    final rssBefore = ProcessInfo.currentRss;
    final cpuBefore = _cpuClock.readSeconds();
    final wallClock = Stopwatch()..start();
    final createClock = Stopwatch()..start();
    final smtc = SmtcBridge.create();
    createClock.stop();

    try {
      await smtc.updateDisplay(
        title: 'Warmup',
        artist: 'Benchmark',
        album: 'Runtime',
        duration: 60000,
        path: audioFile.path,
      );
      await smtc.flush();

      final metadataClock = Stopwatch()..start();
      for (var index = 0; index < 100; index++) {
        unawaited(smtc.updateDisplay(
          title: 'Track $index',
          artist: 'Benchmark',
          album: 'Runtime',
          duration: 60000,
          path: audioFile.path,
        ));
      }
      await smtc.flush();
      metadataClock.stop();

      final stateClock = Stopwatch()..start();
      for (var index = 0; index < 200; index++) {
        unawaited(smtc.updateState(
          index.isEven ? SMTCState.playing : SMTCState.paused,
        ));
      }
      await smtc.flush();
      stateClock.stop();

      final timelineClock = Stopwatch()..start();
      for (var progress = 0; progress < 1000; progress++) {
        unawaited(smtc.updateTimeProperties(progress * 60));
      }
      await smtc.flush();
      timelineClock.stop();

      final sequentialLatenciesMs = <double>[];
      final sequentialClock = Stopwatch()..start();
      var sequentialCalls = 0;
      while (sequentialClock.elapsed < const Duration(seconds: 2)) {
        final callClock = Stopwatch()..start();
        await smtc.updateTimeProperties((sequentialCalls * 60) % 60000);
        callClock.stop();
        sequentialLatenciesMs.add(_milliseconds(callClock.elapsed));
        sequentialCalls++;
      }
      sequentialClock.stop();
      final rssAfterFirstStress = ProcessInfo.currentRss;
      await Future<void>.delayed(const Duration(seconds: 1));

      final repeatClock = Stopwatch()..start();
      var repeatCalls = 0;
      while (repeatClock.elapsed < const Duration(seconds: 2)) {
        await smtc.updateTimeProperties((repeatCalls * 60) % 60000);
        repeatCalls++;
      }
      repeatClock.stop();
      final rssAfterRepeatStress = ProcessInfo.currentRss;

      await smtc.clearDisplay();
      wallClock.stop();
      final cpuSeconds = _cpuClock.readSeconds() - cpuBefore;
      final rssAfter = ProcessInfo.currentRss;
      return <String, Object?>{
        'phase': 'smtc_stress',
        'createMs': _milliseconds(createClock.elapsed),
        'metadata100Ms': _milliseconds(metadataClock.elapsed),
        'state200Ms': _milliseconds(stateClock.elapsed),
        'timeline1000Ms': _milliseconds(timelineClock.elapsed),
        'timelineSequentialCalls': sequentialCalls,
        'timelineSequentialP95Ms': _percentile(sequentialLatenciesMs, 0.95),
        'timelineSequentialOpsPerSecond': double.parse(
          (sequentialCalls /
                  (sequentialClock.elapsed.inMicroseconds /
                      Duration.microsecondsPerSecond))
              .toStringAsFixed(1),
        ),
        'timelineRepeatCalls': repeatCalls,
        'rssAfterFirstStressMb': _toMb(rssAfterFirstStress),
        'rssAfterRepeatStressMb': _toMb(rssAfterRepeatStress),
        'rssRepeatGrowthMb': _toMb(
          rssAfterRepeatStress - rssAfterFirstStress,
        ),
        'rssBeforeMb': _toMb(rssBefore),
        'rssAfterMb': _toMb(rssAfter),
        'rssGrowthMb': _toMb(rssAfter - rssBefore),
        ..._cpuReport(cpuSeconds, wallClock.elapsed),
      };
    } finally {
      await smtc.close();
      await tempDir.delete(recursive: true);
    }
  }

  Future<Map<String, Object?>> _measurePhase(
    String name,
    Duration duration,
  ) async {
    debugPrint('PERF_PHASE $name');
    await SchedulerBinding.instance.endOfFrame;
    _timings.clear();
    final rssBefore = ProcessInfo.currentRss;
    final cpuBefore = _cpuClock.readSeconds();
    final wallClock = Stopwatch()..start();
    await Future<void>.delayed(duration);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    wallClock.stop();
    final cpuSeconds = _cpuClock.readSeconds() - cpuBefore;
    final values = List<FrameTiming>.from(_timings);
    final buildMs = values
        .map((timing) => timing.buildDuration.inMicroseconds / 1000)
        .toList(growable: false);
    final rasterMs = values
        .map((timing) => timing.rasterDuration.inMicroseconds / 1000)
        .toList(growable: false);
    final totalMs = values
        .map((timing) => timing.totalSpan.inMicroseconds / 1000)
        .toList(growable: false);
    return <String, Object?>{
      'phase': name,
      'frames': values.length,
      'buildP95Ms': _percentile(buildMs, 0.95),
      'rasterP95Ms': _percentile(rasterMs, 0.95),
      'totalP95Ms': _percentile(totalMs, 0.95),
      'over16ms': totalMs.where((value) => value > 16.67).length,
      'rssBeforeMb': _toMb(rssBefore),
      'rssAfterMb': _toMb(ProcessInfo.currentRss),
      ..._cpuReport(cpuSeconds, wallClock.elapsed),
    };
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_collectTimings);
    _spectrumTimer.cancel();
    _lyricTimer.cancel();
    _lyricClock.stop();
    _lyricTime.dispose();
    unawaited(_spectrumController.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const scheme = ColorScheme.dark();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Stack(
        fit: StackFit.expand,
        children: [
          if (_showBackground)
            NowPlayingBackground(
              mode: _mode,
              fallbackColor: const Color(0xFF171717),
              inputs: NowPlayingBackgroundInputs(
                albumCoverBytes: _cover,
                dominantColor: Colors.blueGrey,
                preExtractedColors: const <Color>[
                  Color(0xFF305C78),
                  Color(0xFF7F4B57),
                  Color(0xFF9A7A48),
                  Color(0xFF2F3038),
                ],
                spectrumStream: _spectrumController.stream,
                enableAnimation: _enableAnimation,
                isVisible: true,
                playerState: PlayerState.playing,
                flowSpeed: 1,
                intensity: 1,
                audioReactiveFlow: true,
              ),
            )
          else
            const ColoredBox(color: Color(0xFF171717)),
          if (_showLyrics)
            Align(
              alignment: Alignment.center,
              child: RepaintBoundary(
                child: SizedBox(
                  width: 720,
                  height: 260,
                  child: CustomPaint(
                    painter: LyricsLinePainter(
                      line: _benchmarkLyric,
                      currentTimeMs: 0,
                      currentTimeListenable: _lyricTime,
                      blurSigma: 0,
                      config: _benchmarkLyricConfig,
                      scheme: scheme,
                      isMainLine: true,
                      useMaterialYouColor: false,
                      lineMedianWordDuration: const Duration(milliseconds: 900),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

double? _percentile(List<double> values, double percentile) {
  if (values.isEmpty) return null;
  values.sort();
  final index = (values.length * percentile).ceil().clamp(1, values.length) - 1;
  return double.parse(values[index].toStringAsFixed(3));
}

double _toMb(int bytes) {
  return double.parse((bytes / (1024 * 1024)).toStringAsFixed(2));
}

double _milliseconds(Duration duration) {
  return double.parse(
    (duration.inMicroseconds / Duration.microsecondsPerMillisecond)
        .toStringAsFixed(3),
  );
}

Uint8List _silentWavBytes() {
  const sampleRate = 8000;
  const dataLength = sampleRate * 2;
  final bytes = ByteData(44 + dataLength);
  void writeAscii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  writeAscii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataLength, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  bytes.setUint32(40, dataLength, Endian.little);
  return bytes.buffer.asUint8List();
}

Map<String, double> _cpuReport(double cpuSeconds, Duration elapsed) {
  final wallSeconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  final singleCorePercent = cpuSeconds / wallSeconds * 100;
  return <String, double>{
    'cpuCorePercent': double.parse(singleCorePercent.toStringAsFixed(3)),
    'cpuTotalPercent': double.parse(
      (singleCorePercent / Platform.numberOfProcessors).toStringAsFixed(3),
    ),
  };
}

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();
typedef _GetProcessTimesNative = Int32 Function(
  IntPtr process,
  Pointer<Uint64> creationTime,
  Pointer<Uint64> exitTime,
  Pointer<Uint64> kernelTime,
  Pointer<Uint64> userTime,
);
typedef _GetProcessTimesDart = int Function(
  int process,
  Pointer<Uint64> creationTime,
  Pointer<Uint64> exitTime,
  Pointer<Uint64> kernelTime,
  Pointer<Uint64> userTime,
);

class _WindowsCpuClock {
  _WindowsCpuClock()
      : _getCurrentProcess = DynamicLibrary.open('kernel32.dll')
            .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
                'GetCurrentProcess'),
        _getProcessTimes = DynamicLibrary.open('kernel32.dll')
            .lookupFunction<_GetProcessTimesNative, _GetProcessTimesDart>(
                'GetProcessTimes');

  final _GetCurrentProcessDart _getCurrentProcess;
  final _GetProcessTimesDart _getProcessTimes;

  double readSeconds() {
    final creationTime = calloc<Uint64>();
    final exitTime = calloc<Uint64>();
    final kernelTime = calloc<Uint64>();
    final userTime = calloc<Uint64>();
    try {
      final succeeded = _getProcessTimes(
        _getCurrentProcess(),
        creationTime,
        exitTime,
        kernelTime,
        userTime,
      );
      if (succeeded == 0) {
        throw StateError('GetProcessTimes failed');
      }
      return (kernelTime.value + userTime.value) / 10000000;
    } finally {
      calloc.free(creationTime);
      calloc.free(exitTime);
      calloc.free(kernelTime);
      calloc.free(userTime);
    }
  }
}
