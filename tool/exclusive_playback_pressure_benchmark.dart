import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/workload_policy.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/native/rust/frb_generated.dart';

const _scanFileCount = 1000;
const _pressureDuration = Duration(seconds: 6);
const _samplePeriod = Duration(milliseconds: 50);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const SizedBox.shrink());
  await WidgetsBinding.instance.endOfFrame;
  final root = await Directory.systemTemp.createTemp(
    'pure_music_exclusive_pressure_',
  );
  _markPhase(root, 'started');
  BassPlayer? player;
  var exitStatus = 1;
  try {
    final musicDirectory = await Directory(
      '${root.path}${Platform.pathSeparator}music',
    ).create();
    final playbackFile = File(
      '${musicDirectory.path}${Platform.pathSeparator}playback.wav',
    );
    playbackFile.writeAsBytesSync(
      _silentWav(const Duration(seconds: 30)),
      flush: true,
    );
    final scanBytes = _silentWav(const Duration(milliseconds: 50));
    final scanPaths = <String>[];
    for (var index = 0; index < _scanFileCount; index++) {
      final file = File(
        '${musicDirectory.path}${Platform.pathSeparator}scan_$index.wav',
      );
      file.writeAsBytesSync(scanBytes);
      scanPaths.add(file.path);
    }
    _markPhase(root, 'fixtures_ready');

    await _consumeIndex(
      buildIndexFromFoldersRecursively(
        folders: [musicDirectory.path],
        indexPath: root.path,
      ),
    );
    _markPhase(root, 'initial_index_ready');

    player = BassPlayer();
    _markPhase(root, 'player_ready');
    player.setSource(playbackFile.path);
    _markPhase(root, 'source_ready');
    player.start();
    _markPhase(root, 'shared_playback_started');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final exclusiveRequested = player.useExclusiveMode(true);
    _markPhase(root, 'exclusive_requested=$exclusiveRequested');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final exclusiveActive = player.wasapiExclusive;
    final initialState = player.playerState.name;
    final startPosition = player.position;
    final rssBefore = ProcessInfo.currentRss;
    final pressureClock = Stopwatch()..start();
    var lastPosition = startPosition;
    var lastAdvanceMs = 0;
    var maxAdvanceGapMs = 0;
    var regressionCount = 0;
    var stalledSamples = 0;
    var nonPlayingSamples = 0;
    var sampleCount = 0;
    final sampler = Timer.periodic(_samplePeriod, (_) {
      sampleCount++;
      final nowMs = pressureClock.elapsedMilliseconds;
      final position = player!.position;
      if (position > lastPosition + 0.002) {
        final gap = nowMs - lastAdvanceMs;
        if (gap > maxAdvanceGapMs) maxAdvanceGapMs = gap;
        lastAdvanceMs = nowMs;
      } else if (position < lastPosition - 0.05) {
        regressionCount++;
      }
      lastPosition = position;
      final state = player.playerState;
      if (state == PlayerState.stalled) stalledSamples++;
      if (state != PlayerState.playing) nonPlayingSamples++;
    });

    var scanCycles = 0;
    var indexEvents = 0;
    var coverRequests = 0;
    while (pressureClock.elapsed < _pressureDuration) {
      indexEvents += await _consumeIndex(
        updateIndex(indexPath: root.path, forceMetadataCheck: true),
      );
      final offset = (scanCycles * 64) % scanPaths.length;
      final paths = List<String>.generate(
        64,
        (index) => scanPaths[(offset + index) % scanPaths.length],
        growable: false,
      );
      await Future.wait(
        paths.map(
          (path) => CoverImageCache.instance.loadBytes(
            path: path,
            width: 48,
            height: 48,
          ),
        ),
      );
      coverRequests += paths.length;
      scanCycles++;
    }
    sampler.cancel();
    pressureClock.stop();
    final trailingGap = pressureClock.elapsedMilliseconds - lastAdvanceMs;
    if (trailingGap > maxAdvanceGapMs) maxAdvanceGapMs = trailingGap;
    final endPosition = player.position;
    final advancedSeconds = endPosition - startPosition;
    final expectedSeconds = pressureClock.elapsedMilliseconds / 1000.0;
    final passed =
        exclusiveRequested &&
        exclusiveActive &&
        player.playerState == PlayerState.playing &&
        advancedSeconds >= expectedSeconds * 0.8 &&
        maxAdvanceGapMs < 250 &&
        regressionCount == 0 &&
        stalledSamples == 0;
    final report = <String, Object?>{
      'exclusiveRequested': exclusiveRequested,
      'exclusiveActive': exclusiveActive,
      'initialState': initialState,
      'finalState': player.playerState.name,
      'debugState': player.debugStateLine,
      'logicalProcessors': Platform.numberOfProcessors,
      'dartProcessorBudget': applicationProcessorBudget,
      'coverLoadConcurrency': backgroundWorkerConcurrencyFor(
        applicationProcessorBudget,
      ),
      'scanFiles': _scanFileCount,
      'scanCycles': scanCycles,
      'indexEvents': indexEvents,
      'coverRequests': coverRequests,
      'pressureMs': pressureClock.elapsedMilliseconds,
      'positionStart': _rounded(startPosition),
      'positionEnd': _rounded(endPosition),
      'positionAdvanced': _rounded(advancedSeconds),
      'maxAdvanceGapMs': maxAdvanceGapMs,
      'regressions': regressionCount,
      'stalledSamples': stalledSamples,
      'nonPlayingSamples': nonPlayingSamples,
      'samples': sampleCount,
      'rssBeforeMb': _megabytes(rssBefore),
      'rssAfterMb': _megabytes(ProcessInfo.currentRss),
      'passed': passed,
    };
    final encodedReport = jsonEncode(report);
    debugPrint('EXCLUSIVE_PRESSURE_REPORT $encodedReport');
    File(
      '${root.path}${Platform.pathSeparator}report.json',
    ).writeAsStringSync(encodedReport, flush: true);
    _markPhase(root, 'completed passed=$passed');
    exitStatus = passed ? 0 : 2;
  } catch (error, stackTrace) {
    debugPrint('EXCLUSIVE_PRESSURE_ERROR $error\n$stackTrace');
  } finally {
    _markPhase(root, 'cleanup_player_started');
    try {
      player?.free();
    } catch (_) {}
    _markPhase(root, 'cleanup_player_finished');
    CoverImageCache.instance.clear();
    _markPhase(root, 'cleanup_cache_finished');
    RustLib.dispose();
    _markPhase(root, 'cleanup_rust_finished');
    final cleanupError = await _deleteTempDirectory(root);
    if (cleanupError != null) {
      debugPrint('EXCLUSIVE_PRESSURE_CLEANUP_ERROR $cleanupError');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(exitStatus);
  }
}

Future<Object?> _deleteTempDirectory(Directory root) async {
  Object? lastError;
  for (var attempt = 0; attempt < 3; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    try {
      await root.delete(recursive: true);
      return null;
    } catch (error) {
      lastError = error;
    }
  }
  return lastError;
}

void _markPhase(Directory root, String phase) {
  final message = '${DateTime.now().toIso8601String()} $phase';
  debugPrint('EXCLUSIVE_PRESSURE_PHASE $message');
  File(
    '${root.path}${Platform.pathSeparator}phase.log',
  ).writeAsStringSync('$message\n', mode: FileMode.append, flush: true);
}

Future<int> _consumeIndex(Stream<IndexActionState> stream) async {
  var events = 0;
  await for (final _ in stream) {
    events++;
  }
  return events;
}

Uint8List _silentWav(Duration duration) {
  const sampleRate = 44100;
  const channels = 2;
  const bitsPerSample = 16;
  const bytesPerSample = bitsPerSample ~/ 8;
  const blockAlign = channels * bytesPerSample;
  final sampleCount =
      (sampleRate * duration.inMicroseconds) ~/ Duration.microsecondsPerSecond;
  final dataSize = sampleCount * blockAlign;
  final bytes = Uint8List(44 + dataSize);
  final data = ByteData.sublistView(bytes);
  _writeAscii(bytes, 0, 'RIFF');
  data.setUint32(4, 36 + dataSize, Endian.little);
  _writeAscii(bytes, 8, 'WAVE');
  _writeAscii(bytes, 12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * blockAlign, Endian.little);
  data.setUint16(32, blockAlign, Endian.little);
  data.setUint16(34, bitsPerSample, Endian.little);
  _writeAscii(bytes, 36, 'data');
  data.setUint32(40, dataSize, Endian.little);
  return bytes;
}

void _writeAscii(Uint8List bytes, int offset, String value) {
  for (var index = 0; index < value.length; index++) {
    bytes[offset + index] = value.codeUnitAt(index);
  }
}

double _rounded(double value) => double.parse(value.toStringAsFixed(3));

double _megabytes(int bytes) =>
    double.parse((bytes / (1024 * 1024)).toStringAsFixed(2));
