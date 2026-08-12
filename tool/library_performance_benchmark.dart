import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/component/artist_tile.dart';
import 'package:pure_music/core/page_sort.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/core/workload_policy.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as library_db;
import 'package:pure_music/native/rust/frb_generated.dart';
import 'package:pure_music/page/albums_page.dart';
import 'package:pure_music/page/artists_page.dart';
import 'package:pure_music/page/audios_page.dart';
import 'package:pure_music/page/folders_page.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

const _largeLibraryOnly = bool.fromEnvironment(
  'PURE_MUSIC_BENCHMARK_LARGE_ONLY',
);
const _externalScenario = String.fromEnvironment(
  'PURE_MUSIC_BENCHMARK_SCENARIO',
);
const _externalDirectory = String.fromEnvironment(
  'PURE_MUSIC_BENCHMARK_DIRECTORY',
);
const _librarySizes = _largeLibraryOnly
    ? <int>[50000]
    : <int>[1000, 10000, 50000];
const _tracksPerFolder = 250;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const _LibraryBenchmarkApp());
}

class _LibraryBenchmarkApp extends StatelessWidget {
  const _LibraryBenchmarkApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const _LibraryBenchmarkDriver(),
    );
  }
}

class _LibraryBenchmarkDriver extends StatefulWidget {
  const _LibraryBenchmarkDriver();

  @override
  State<_LibraryBenchmarkDriver> createState() =>
      _LibraryBenchmarkDriverState();
}

class _LibraryBenchmarkDriverState extends State<_LibraryBenchmarkDriver> {
  final _cpuClock = _WindowsCpuClock();
  final _frameTimings = <FrameTiming>[];
  final _pages = <int, Widget>{};
  final _sortPhaseTotals = <String, int>{};
  final _sortPhaseMax = <String, int>{};
  final _sortPhaseCount = <String, int>{};
  var _activePage = 0;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    pageSortPhaseObserver = _collectSortPhase;
    SchedulerBinding.instance.addTimingsCallback(_collectFrameTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_run());
    });
  }

  void _collectSortPhase(String phase, Duration elapsed) {
    final micros = elapsed.inMicroseconds;
    _sortPhaseTotals.update(
      phase,
      (value) => value + micros,
      ifAbsent: () => micros,
    );
    _sortPhaseMax.update(
      phase,
      (value) => micros > value ? micros : value,
      ifAbsent: () => micros,
    );
    _sortPhaseCount.update(phase, (value) => value + 1, ifAbsent: () => 1);
  }

  void _resetDiagnostics() {
    _sortPhaseTotals.clear();
    _sortPhaseMax.clear();
    _sortPhaseCount.clear();
    artistTileBuildMicros = 0;
    uniPageBuildMicros = 0;
    uniPageContentAreaMicros = 0;
  }

  Map<String, Object?> _sortPhaseReport() => {
    for (final entry in _sortPhaseCount.entries)
      'sortPhase${entry.key}Count': entry.value,
    for (final entry in _sortPhaseTotals.entries)
      'sortPhase${entry.key}TotalMs': _microsToMs(entry.value),
    for (final entry in _sortPhaseMax.entries)
      'sortPhase${entry.key}MaxMs': _microsToMs(entry.value),
  };

  void _collectFrameTimings(List<FrameTiming> timings) {
    _frameTimings.addAll(timings);
  }

  Future<void> _run() async {
    final reports = <Map<String, Object?>>[];
    try {
      if (_externalScenario.isNotEmpty) {
        await _runExternalScenario(reports);
      } else {
        for (final size in _librarySizes) {
          await _resetPages();
          final cold = await _loadDataset(size, scenario: 'cold');
          reports.add(cold.report);
          await _measurePages(reports, size, scenario: 'cold');
          await AudioLibrary.instance.waitForPreferredPageOrderCacheWrite();

          await _resetPages();
          final warm = await _loadDataset(
            size,
            scenario: 'warm',
            directory: cold.directory,
          );
          reports.add(warm.report);
          await _measurePages(reports, size, scenario: 'warm');
          reports.add(
            await _measureLibraryRefresh(size, changeAudioMetadata: false),
          );
          reports.add(
            await _measureLibraryRefresh(size, changeAudioMetadata: true),
          );
          await warm.directory.delete(recursive: true);
        }
      }
      debugPrint('LIBRARY_PERF_REPORT ${jsonEncode(reports)}');
      await PlayService.instance.close();
      RustLib.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      exit(0);
    } catch (error, stackTrace) {
      debugPrint('LIBRARY_PERF_ERROR $error\n$stackTrace');
      RustLib.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      exit(1);
    }
  }

  Future<void> _runExternalScenario(List<Map<String, Object?>> reports) async {
    if (_externalScenario != 'cold' && _externalScenario != 'warm') {
      throw ArgumentError.value(_externalScenario, 'benchmark scenario');
    }
    if (_externalDirectory.isEmpty) {
      throw ArgumentError('PURE_MUSIC_BENCHMARK_DIRECTORY is required');
    }
    final directory = Directory(_externalDirectory);
    const cold = _externalScenario == 'cold';
    if (cold) {
      if (await directory.exists() && !await directory.list().isEmpty) {
        throw StateError(
          'Benchmark directory must be empty: ${directory.path}',
        );
      }
      await directory.create(recursive: true);
    } else if (!await directory.exists()) {
      throw StateError('Benchmark directory is missing: ${directory.path}');
    }

    await _resetPages();
    final dataset = await _loadDataset(
      50000,
      scenario: _externalScenario,
      directory: directory,
      initialize: cold,
    );
    reports.add(dataset.report);
    await _measurePages(reports, 50000, scenario: _externalScenario);
    if (!cold) {
      reports.add(
        await _measureLibraryRefresh(50000, changeAudioMetadata: false),
      );
      reports.add(
        await _measureLibraryRefresh(50000, changeAudioMetadata: true),
      );
    }
    await AudioLibrary.instance.waitForPreferredPageOrderCacheWrite();
    if (!cold) await directory.delete(recursive: true);
  }

  Future<void> _resetPages() async {
    if (!mounted) return;
    setState(() {
      _generation++;
      _pages.clear();
      _activePage = 0;
    });
    await SchedulerBinding.instance.endOfFrame;
  }

  Future<void> _measurePages(
    List<Map<String, Object?>> reports,
    int size, {
    required String scenario,
  }) async {
    for (var page = 0; page < 4; page++) {
      reports.add(
        await _measureUiPhase(
          'page_first',
          size,
          scenario: scenario,
          page: _pageName(page),
          action: () => _showPage(page),
        ),
      );
    }
    reports.add(
      await _measureUiPhase(
        'page_repeat_switch',
        size,
        scenario: scenario,
        action: () async {
          for (var cycle = 0; cycle < 3; cycle++) {
            for (var page = 0; page < 4; page++) {
              await _showPage(page);
            }
          }
        },
      ),
    );
  }

  Future<_LoadedDataset> _loadDataset(
    int size, {
    required String scenario,
    Directory? directory,
    bool initialize = false,
  }) async {
    debugPrint('LIBRARY_PERF_PHASE dataset_${scenario}_$size');
    final targetDirectory =
        directory ??
        await Directory.systemTemp.createTemp('pure_music_library_benchmark_');
    if (directory == null || initialize) {
      _createBenchmarkDatabase(targetDirectory, size);
      File(
        '${targetDirectory.path}${Platform.pathSeparator}index.json',
      ).writeAsStringSync('{"version":1,"size":$size}', flush: true);
    }

    final rssBefore = ProcessInfo.currentRss;
    final cpuBefore = _cpuClock.readSeconds();
    final totalClock = Stopwatch()..start();
    final sqliteClock = Stopwatch()..start();
    final dbFolders = await library_db.readIndexFromSqlite(
      indexPath: targetDirectory.path,
    );
    sqliteClock.stop();

    final conversionClock = Stopwatch()..start();
    final folders = <AudioFolder>[];
    var converted = 0;
    for (final folder in dbFolders) {
      final audios = <Audio>[];
      for (final audio in folder.audios) {
        audios.add(
          Audio(
            audio.title,
            audio.artist,
            audio.album,
            audio.albumArtist,
            audio.track,
            audio.duration.toInt(),
            audio.bitrate,
            audio.sampleRate,
            audio.path,
            audio.modified.toInt(),
            audio.created.toInt(),
            audio.by,
            disc: audio.disc,
            playCount: audio.playCount,
          ),
        );
        converted++;
        if (converted % 2048 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      folders.add(
        AudioFolder(
          audios,
          folder.path,
          folder.modified.toInt(),
          folder.latest.toInt(),
        ),
      );
    }
    conversionClock.stop();

    AudioLibrary.instance.dispose();
    final collectionClock = Stopwatch()..start();
    AudioLibrary.instance.replaceFolders(folders);
    collectionClock.stop();
    final pagePreparationClock = Stopwatch()..start();
    final cacheHit = await AudioLibrary.instance
        .preparePreferredPageSnapshotsUsingCache(
          sourcePath:
              '${targetDirectory.path}${Platform.pathSeparator}index.json',
          cachePath:
              '${targetDirectory.path}${Platform.pathSeparator}library_page_orders.bin',
        );
    pagePreparationClock.stop();
    final secondaryPagesReady =
        AudioLibrary.instance.preparedArtistsPage != null &&
        AudioLibrary.instance.preparedAlbumsPage != null;
    AudioLibrary.libraryVersion.value++;
    totalClock.stop();

    final cpuSeconds = _cpuClock.readSeconds() - cpuBefore;
    final report = <String, Object?>{
      'phase': 'dataset_load',
      'scenario': scenario,
      'pageOrderCacheHit': cacheHit,
      'size': size,
      'folders': folders.length,
      'artists': AudioLibrary.instance.artistCollection.length,
      'albums': AudioLibrary.instance.albumCollection.length,
      'sqliteReadMs': _milliseconds(sqliteClock.elapsed),
      'conversionMs': _milliseconds(conversionClock.elapsed),
      'collectionsMs': _milliseconds(collectionClock.elapsed),
      'pagePreparationMs': _milliseconds(pagePreparationClock.elapsed),
      'secondaryPagesReadyAtReturn': secondaryPagesReady,
      'logicalProcessors': Platform.numberOfProcessors,
      'dartProcessorBudget': applicationProcessorBudget,
      'totalMs': _milliseconds(totalClock.elapsed),
      'rssBeforeMb': _toMb(rssBefore),
      'rssAfterMb': _toMb(ProcessInfo.currentRss),
      'rssGrowthMb': _toMb(ProcessInfo.currentRss - rssBefore),
      ..._sortPhaseReport(),
      ..._cpuReport(cpuSeconds, totalClock.elapsed),
    };
    return _LoadedDataset(targetDirectory, report);
  }

  Future<void> _showPage(int page) async {
    setState(() {
      _activePage = page;
      _pages.putIfAbsent(page, () => _buildPage(page));
    });
    await SchedulerBinding.instance.endOfFrame;
  }

  Future<Map<String, Object?>> _measureLibraryRefresh(
    int size, {
    required bool changeAudioMetadata,
  }) async {
    final scenario = changeAudioMetadata
        ? 'audio_changed'
        : 'folder_metadata_only';
    debugPrint('LIBRARY_PERF_PHASE library_refresh_${scenario}_$size');
    final rssBefore = ProcessInfo.currentRss;
    final cpuBefore = _cpuClock.readSeconds();
    final totalClock = Stopwatch()..start();
    final cloneClock = Stopwatch()..start();
    final refreshedFolders = AudioLibrary.instance.folders
        .map(
          (folder) => AudioFolder(
            folder.audios.map(_copyAudio).toList(growable: false),
            folder.path,
            folder.modified,
            folder.latest,
          ),
        )
        .toList(growable: false);
    if (refreshedFolders.isNotEmpty) {
      if (changeAudioMetadata && refreshedFolders.first.audios.isNotEmpty) {
        final audio = refreshedFolders.first.audios.first;
        audio.title = '${audio.title} [refresh]';
      } else {
        refreshedFolders.first.modified++;
      }
    }
    cloneClock.stop();
    final rssAfterClone = ProcessInfo.currentRss;
    final retainedAudio = AudioLibrary.instance.audioCollection.isEmpty
        ? null
        : AudioLibrary.instance.audioCollection.first;
    final retainedPath = retainedAudio?.path;

    _frameTimings.clear();
    _resetDiagnostics();
    final collectionClock = Stopwatch()..start();
    AudioLibrary.instance.replaceFolders(refreshedFolders);
    collectionClock.stop();
    final pagePreparationClock = Stopwatch()..start();
    await AudioLibrary.instance.preparePreferredPageSnapshots();
    pagePreparationClock.stop();
    AudioLibrary.libraryVersion.value++;
    await SchedulerBinding.instance.endOfFrame;
    totalClock.stop();

    final cpuSeconds = _cpuClock.readSeconds() - cpuBefore;
    final timings = List<FrameTiming>.from(_frameTimings);
    final frameMetrics = _frameMetrics(timings);
    return <String, Object?>{
      'phase': 'library_refresh',
      'scenario': scenario,
      'size': size,
      'cloneMs': _milliseconds(cloneClock.elapsed),
      'collectionsMs': _milliseconds(collectionClock.elapsed),
      'pagePreparationMs': _milliseconds(pagePreparationClock.elapsed),
      'totalMs': _milliseconds(totalClock.elapsed),
      'preservedAudioIdentity':
          retainedAudio != null &&
          retainedPath != null &&
          identical(
            retainedAudio,
            AudioLibrary.instance.audioByPath(retainedPath),
          ),
      'secondaryPagesReadyAtReturn':
          AudioLibrary.instance.preparedArtistsPage != null &&
          AudioLibrary.instance.preparedAlbumsPage != null,
      ...frameMetrics,
      'rssBeforeMb': _toMb(rssBefore),
      'rssAfterCloneMb': _toMb(rssAfterClone),
      'rssAfterMb': _toMb(ProcessInfo.currentRss),
      'rssGrowthMb': _toMb(ProcessInfo.currentRss - rssBefore),
      'logicalProcessors': Platform.numberOfProcessors,
      'dartProcessorBudget': applicationProcessorBudget,
      ..._sortPhaseReport(),
      ..._cpuReport(cpuSeconds, totalClock.elapsed),
    };
  }

  Widget _buildPage(int page) {
    final key = ValueKey('$_generation-$page');
    return switch (page) {
      0 => AudiosPage(key: key),
      1 => ArtistsPage(key: key),
      2 => AlbumsPage(key: key),
      _ => FoldersPage(key: key),
    };
  }

  Future<Map<String, Object?>> _measureUiPhase(
    String phase,
    int size, {
    required String scenario,
    String? page,
    required Future<void> Function() action,
  }) async {
    debugPrint(
      'LIBRARY_PERF_PHASE ${phase}_${scenario}_$size${page == null ? '' : '_$page'}',
    );
    final pagePreparedAtActionStart = _pagePrepared(page);
    _frameTimings.clear();
    _resetDiagnostics();
    final rssBefore = ProcessInfo.currentRss;
    final cpuBefore = _cpuClock.readSeconds();
    final clock = Stopwatch()..start();
    await action();
    final actionElapsed = clock.elapsed;
    final pagePreparedAfterAction = _pagePrepared(page);
    final actionTimingCount = _frameTimings.length;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final pagePreparedAfterSettle = _pagePrepared(page);
    clock.stop();
    final cpuSeconds = _cpuClock.readSeconds() - cpuBefore;
    final timings = List<FrameTiming>.from(_frameTimings);
    final actionTimings = timings
        .take(actionTimingCount)
        .toList(growable: false);
    final settleTimings = timings
        .skip(actionTimingCount)
        .toList(growable: false);
    final overallMetrics = _frameMetrics(timings);
    final actionMetrics = _frameMetrics(actionTimings);
    final settleMetrics = _frameMetrics(settleTimings);
    return <String, Object?>{
      'phase': phase,
      'scenario': scenario,
      'size': size,
      'page': ?page,
      'pagePreparedAtActionStart': pagePreparedAtActionStart,
      'pagePreparedAfterAction': pagePreparedAfterAction,
      'pagePreparedAfterSettle': pagePreparedAfterSettle,
      'frames': overallMetrics['frames'],
      'actionMs': _milliseconds(actionElapsed),
      'wallMs': _milliseconds(clock.elapsed),
      'buildP95Ms': overallMetrics['buildP95Ms'],
      'frameP95Ms': overallMetrics['frameP95Ms'],
      'over16ms': overallMetrics['over16ms'],
      'actionFrameMetrics': actionMetrics,
      'settleFrameMetrics': settleMetrics,
      'rssBeforeMb': _toMb(rssBefore),
      'rssAfterMb': _toMb(ProcessInfo.currentRss),
      'rssGrowthMb': _toMb(ProcessInfo.currentRss - rssBefore),
      'artistTileBuildMs': _microsToMs(artistTileBuildMicros),
      'uniPageBuildMs': _microsToMs(uniPageBuildMicros),
      'uniPageContentAreaMs': _microsToMs(uniPageContentAreaMicros),
      ..._sortPhaseReport(),
      ..._cpuReport(cpuSeconds, clock.elapsed),
    };
  }

  bool? _pagePrepared(String? page) => switch (page) {
    'audios' => AudioLibrary.instance.preparedAudiosPage != null,
    'artists' => AudioLibrary.instance.preparedArtistsPage != null,
    'albums' => AudioLibrary.instance.preparedAlbumsPage != null,
    _ => null,
  };

  @override
  void dispose() {
    pageSortPhaseObserver = null;
    SchedulerBinding.instance.removeTimingsCallback(_collectFrameTimings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_pages.isEmpty) {
      return const ColoredBox(color: Color(0xFF121212));
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final entry in _pages.entries)
          Offstage(
            offstage: entry.key != _activePage,
            child: TickerMode(
              enabled: entry.key == _activePage,
              child: entry.value,
            ),
          ),
      ],
    );
  }
}

class _LoadedDataset {
  const _LoadedDataset(this.directory, this.report);

  final Directory directory;
  final Map<String, Object?> report;
}

Audio _copyAudio(Audio audio) => Audio(
  audio.title,
  audio.artist,
  audio.album,
  audio.albumArtist,
  audio.track,
  audio.duration,
  audio.bitrate,
  audio.sampleRate,
  audio.path,
  audio.modified,
  audio.created,
  audio.by,
  disc: audio.disc,
  playCount: audio.playCount,
);

void _createBenchmarkDatabase(Directory directory, int size) {
  final database = sqlite.sqlite3.open('${directory.path}\\library.sqlite');
  try {
    database.execute('''
      PRAGMA auto_vacuum = INCREMENTAL;
      PRAGMA journal_mode = OFF;
      CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE folders (
        path TEXT PRIMARY KEY,
        modified INTEGER NOT NULL,
        latest INTEGER NOT NULL
      );
      CREATE TABLE audios (
        path TEXT PRIMARY KEY,
        folder_path TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        album TEXT NOT NULL,
        album_artist TEXT,
        track INTEGER,
        disc INTEGER,
        duration INTEGER NOT NULL,
        bitrate INTEGER,
        sample_rate INTEGER,
        modified INTEGER NOT NULL,
        created INTEGER NOT NULL,
        by TEXT,
        play_count INTEGER NOT NULL DEFAULT 0,
        media_id TEXT,
        metadata_key TEXT
      );
      CREATE INDEX idx_audios_folder_path_path ON audios(folder_path, path);
      CREATE INDEX idx_audios_title ON audios(title);
      CREATE INDEX idx_audios_artist ON audios(artist);
      CREATE INDEX idx_audios_album ON audios(album);
      CREATE INDEX idx_audios_media_id ON audios(media_id);
      CREATE INDEX idx_audios_metadata_key ON audios(metadata_key);
      CREATE TABLE cover_thumbnails (
        path TEXT NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        source_modified INTEGER NOT NULL,
        source_size INTEGER NOT NULL,
        last_accessed INTEGER NOT NULL DEFAULT 0,
        png BLOB NOT NULL,
        PRIMARY KEY (path, width, height)
      );
      INSERT INTO meta(key, value) VALUES('version', '110');
      INSERT INTO meta(key, value) VALUES('identity_backfill_v1', '1');
      INSERT INTO meta(key, value) VALUES('database_layout_version', '2');
      BEGIN IMMEDIATE;
    ''');
    final folderStatement = database.prepare(
      'INSERT INTO folders(path, modified, latest) VALUES(?1, ?2, ?3)',
    );
    final audioStatement = database.prepare('''
      INSERT INTO audios(
        path, folder_path, title, artist, album, album_artist, track, disc,
        duration, bitrate, sample_rate, modified, created, by, play_count,
        media_id, metadata_key
      ) VALUES(
        ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
        ?15, ?16, ?17
      )
    ''');
    try {
      final folderCount = (size + _tracksPerFolder - 1) ~/ _tracksPerFolder;
      final roots = <String>{};
      for (var folder = 0; folder < folderCount; folder++) {
        final root = 'C:/Benchmark/Root${folder % 10}';
        if (roots.add(root)) {
          folderStatement.execute([root, 1, 1]);
        }
        folderStatement.execute([
          '$root/Folder$folder',
          folder + 2,
          folder + 2,
        ]);
      }

      final artistCount = (size * 0.4).round().clamp(1, size);
      final albumCount = (size * 0.67).round().clamp(1, size);
      for (var index = 0; index < size; index++) {
        final folder = index ~/ _tracksPerFolder;
        final root = 'C:/Benchmark/Root${folder % 10}';
        final folderPath = '$root/Folder$folder';
        final path = '$folderPath/Track$index.flac';
        final artist = index.isEven
            ? '艺术家 ${index % artistCount}'
            : 'Artist ${index % artistCount}';
        final album = 'Album ${index % albumCount}';
        audioStatement.execute([
          path,
          folderPath,
          index.isEven ? '歌曲 $index' : 'Track $index',
          artist,
          album,
          artist,
          (index % 24) + 1,
          (index % 3) + 1,
          180 + (index % 120),
          320,
          44100,
          index + 10,
          index + 5,
          'Benchmark',
          index % 20,
          'benchmark:$index',
          'benchmark-metadata:$index',
        ]);
      }
      database.execute('COMMIT;');
    } catch (_) {
      database.execute('ROLLBACK;');
      rethrow;
    } finally {
      folderStatement.dispose();
      audioStatement.dispose();
    }
  } finally {
    database.dispose();
  }
}

String _pageName(int page) => switch (page) {
  0 => 'audios',
  1 => 'artists',
  2 => 'albums',
  _ => 'folders',
};

Map<String, Object?> _frameMetrics(Iterable<FrameTiming> timings) {
  final values = timings.toList(growable: false);
  final buildMs = values
      .map((timing) => timing.buildDuration.inMicroseconds / 1000)
      .toList(growable: false);
  final rasterMs = values
      .map((timing) => timing.rasterDuration.inMicroseconds / 1000)
      .toList(growable: false);
  final totalMs = values
      .map((timing) => timing.totalSpan.inMicroseconds / 1000)
      .toList(growable: false);
  final maxFrameMs = totalMs.isEmpty
      ? null
      : totalMs.reduce((a, b) => a > b ? a : b);
  final maxBuildMs = buildMs.isEmpty
      ? null
      : buildMs.reduce((a, b) => a > b ? a : b);
  final maxRasterMs = rasterMs.isEmpty
      ? null
      : rasterMs.reduce((a, b) => a > b ? a : b);
  var slowestIndex = -1;
  var slowestTotal = -1.0;
  for (var index = 0; index < totalMs.length; index++) {
    if (totalMs[index] > slowestTotal) {
      slowestTotal = totalMs[index];
      slowestIndex = index;
    }
  }
  final slowestVsyncOverheadMs = slowestIndex < 0
      ? null
      : values[slowestIndex].vsyncOverhead.inMicroseconds / 1000;
  return {
    'frames': values.length,
    'buildP95Ms': _percentile(buildMs, 0.95),
    'rasterP95Ms': _percentile(rasterMs, 0.95),
    'frameP95Ms': _percentile(totalMs, 0.95),
    'maxFrameMs': maxFrameMs,
    'maxBuildMs': maxBuildMs,
    'maxRasterMs': maxRasterMs,
    'slowestFrameVsyncOverheadMs': slowestVsyncOverheadMs,
    'over16ms': totalMs.where((value) => value > 16.67).length,
  };
}

double _microsToMs(int micros) => double.parse(
  (micros / Duration.microsecondsPerMillisecond).toStringAsFixed(3),
);

double? _percentile(List<double> values, double percentile) {
  if (values.isEmpty) return null;
  values.sort();
  final index = (values.length * percentile).ceil().clamp(1, values.length) - 1;
  return double.parse(values[index].toStringAsFixed(3));
}

double _toMb(int bytes) =>
    double.parse((bytes / (1024 * 1024)).toStringAsFixed(2));

double _milliseconds(Duration duration) => double.parse(
  (duration.inMicroseconds / Duration.microsecondsPerMillisecond)
      .toStringAsFixed(3),
);

Map<String, double> _cpuReport(double cpuSeconds, Duration elapsed) {
  final wallSeconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  final coreEquivalent = cpuSeconds / wallSeconds;
  final singleCorePercent = coreEquivalent * 100;
  final reservedCores = Platform.numberOfProcessors - coreEquivalent;
  return <String, double>{
    'cpuCoreEquivalent': double.parse(coreEquivalent.toStringAsFixed(3)),
    'cpuCorePercent': double.parse(singleCorePercent.toStringAsFixed(3)),
    'cpuTotalPercent': double.parse(
      (singleCorePercent / Platform.numberOfProcessors).toStringAsFixed(3),
    ),
    'reservedLogicalCores': double.parse(
      (reservedCores < 0 ? 0.0 : reservedCores).toStringAsFixed(3),
    ),
  };
}

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();
typedef _GetProcessTimesNative =
    Int32 Function(
      IntPtr process,
      Pointer<Uint64> creationTime,
      Pointer<Uint64> exitTime,
      Pointer<Uint64> kernelTime,
      Pointer<Uint64> userTime,
    );
typedef _GetProcessTimesDart =
    int Function(
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
            'GetCurrentProcess',
          ),
      _getProcessTimes = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<_GetProcessTimesNative, _GetProcessTimesDart>(
            'GetProcessTimes',
          );

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
      if (succeeded == 0) throw StateError('GetProcessTimes failed');
      return (kernelTime.value + userTime.value) / 10000000;
    } finally {
      calloc.free(creationTime);
      calloc.free(exitTime);
      calloc.free(kernelTime);
      calloc.free(userTime);
    }
  }
}
