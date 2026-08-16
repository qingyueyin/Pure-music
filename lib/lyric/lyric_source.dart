import 'dart:convert';
import 'dart:io';

import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:sqlite3/sqlite3.dart';

enum LyricSourceType {
  qq('qq'),
  kugou('kugou'),
  ne('ne'),
  amll('amll'),
  local('local');

  final String name;
  const LyricSourceType(this.name);
}

class LyricSource {
  LyricSourceType source;
  String? qqSongId;
  String? kugouSongHash;
  int? neSongId;
  String? amllTtmlFile;
  String? localLyricPath;

  LyricSource(
    this.source, {
    this.qqSongId,
    this.kugouSongHash,
    this.neSongId,
    this.amllTtmlFile,
    this.localLyricPath,
  });

  static LyricSource? fromMap(Map? map) {
    if (map == null) return null;
    final source = _normalizedSourceName(map['source']);
    if (source == 'qq') {
      return LyricSource(
        LyricSourceType.qq,
        qqSongId: _normalizedTextSongId(map['id']),
      );
    } else if (source == 'kugou') {
      return LyricSource(
        LyricSourceType.kugou,
        kugouSongHash: _normalizedTextSongId(map['id']),
      );
    } else if (source == 'ne') {
      final rawId = map['id'];
      int? neSongId;
      if (rawId is int) {
        neSongId = _normalizedNeSongId(rawId);
      } else if (rawId is num) {
        neSongId = _normalizedNeSongId(rawId);
      } else if (rawId is String) {
        neSongId = _normalizedNeSongId(rawId);
      }
      return LyricSource(LyricSourceType.ne, neSongId: neSongId);
    } else if (source == 'amll') {
      return LyricSource(
        LyricSourceType.amll,
        amllTtmlFile: _normalizedTextSongId(map['id']),
      );
    } else if (source == 'local') {
      return LyricSource(
        LyricSourceType.local,
        localLyricPath: _normalizedLocalLyricPath(map['id']),
      );
    } else {
      return LyricSource(LyricSourceType.local);
    }
  }

  Map toMap() {
    switch (source) {
      case LyricSourceType.qq:
        return {'source': source.name, 'id': qqSongId};
      case LyricSourceType.kugou:
        return {'source': source.name, 'id': kugouSongHash};
      case LyricSourceType.ne:
        return {'source': source.name, 'id': neSongId};
      case LyricSourceType.amll:
        return {'source': source.name, 'id': amllTtmlFile};
      case LyricSourceType.local:
        return {'source': source.name, 'id': localLyricPath};
    }
  }
}

Map<String, LyricSource> lyricSources = {};

Future<void> readLyricSources() async {
  final stopwatch = Stopwatch()..start();
  lyricSources = {};
  try {
    final dir = await getAppDataDir();
    final jsonFile = File(
      '${dir.path}${Platform.pathSeparator}lyric_source.json',
    );

    final db = await AppDb.instance.db();
    final count =
        db.select('SELECT COUNT(1) AS c FROM lyric_sources').first['c'] as int;
    if (count == 0 && jsonFile.existsSync()) {
      final fromJson = _readLyricSourcesFromJson(jsonFile);
      _writeLyricSourcesToDb(db, fromJson);
      lyricSources = fromJson;
      logger.i(
        '[perf] lyric sources load=${stopwatch.elapsedMilliseconds}ms '
        'count=${lyricSources.length} migrated=true',
      );
      return;
    }

    final result = <String, LyricSource>{};
    final rows = db.select('SELECT path, source, id FROM lyric_sources');
    for (final row in rows) {
      final p = row['path'] as String;
      final source = row['source'] as String;
      final id = row['id'] as String?;
      final ls = _lyricSourceFromDb(source, id);
      if (ls != null) {
        result[p] = ls;
      }
    }
    lyricSources = result;
    logger.i(
      '[perf] lyric sources load=${stopwatch.elapsedMilliseconds}ms '
      'count=${lyricSources.length} migrated=false',
    );
  } catch (err, trace) {
    logger.e(err, stackTrace: trace);
  }
}

void pruneLyricSourcesWhereMissing(bool Function(String path) containsPath) {
  lyricSources.removeWhere((path, _) => !containsPath(path));
}

Future<void> saveLyricSources() async {
  try {
    final db = await AppDb.instance.db();
    _writeLyricSourcesToDb(db, lyricSources);
  } catch (err, trace) {
    logger.e(err, stackTrace: trace);
    rethrow;
  }
}

Future<void> persistLyricSource(
  String audioPath,
  LyricSource source, {
  Future<void> Function()? persist,
}) async {
  final hadPrevious = lyricSources.containsKey(audioPath);
  final previous = lyricSources[audioPath];
  lyricSources[audioPath] = source;
  try {
    await (persist?.call() ?? saveLyricSources());
  } catch (_) {
    if (hadPrevious) {
      lyricSources[audioPath] = previous!;
    } else {
      lyricSources.remove(audioPath);
    }
    rethrow;
  }
}

Map<String, LyricSource> _readLyricSourcesFromJson(File jsonFile) {
  final result = <String, LyricSource>{};
  final lyricSourceStr = jsonFile.readAsStringSync();
  final decoded = json.decode(lyricSourceStr);
  if (decoded is! Map) return result;

  for (final item in decoded.entries) {
    if (item.key is! String || item.value is! Map) continue;
    final p = item.key as String;
    final source = LyricSource.fromMap(item.value as Map);
    if (source != null) {
      result[p] = source;
    }
  }
  return result;
}

void _writeLyricSourcesToDb(Database db, Map<String, LyricSource> sources) {
  db.execute('BEGIN');
  try {
    db.execute('DELETE FROM lyric_sources');
    for (final e in sources.entries) {
      final p = e.key;
      final s = e.value.source.name;
      final id = _lyricSourceId(e.value);
      db.execute(
        'INSERT INTO lyric_sources(path, source, id) VALUES(?, ?, ?)',
        [p, s, id],
      );
    }
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

String? _lyricSourceId(LyricSource s) {
  switch (s.source) {
    case LyricSourceType.qq:
      return s.qqSongId?.toString();
    case LyricSourceType.kugou:
      return s.kugouSongHash;
    case LyricSourceType.ne:
      return s.neSongId?.toString();
    case LyricSourceType.amll:
      return s.amllTtmlFile;
    case LyricSourceType.local:
      return s.localLyricPath;
  }
}

LyricSource? _lyricSourceFromDb(String source, String? id) {
  final normalizedSource = _normalizedSourceName(source);
  if (normalizedSource == LyricSourceType.qq.name) {
    return LyricSource(LyricSourceType.qq, qqSongId: id);
  }
  if (normalizedSource == LyricSourceType.kugou.name) {
    return LyricSource(LyricSourceType.kugou, kugouSongHash: id);
  }
  if (normalizedSource == LyricSourceType.ne.name) {
    return LyricSource(
      LyricSourceType.ne,
      neSongId: id == null ? null : _normalizedNeSongId(id),
    );
  }
  if (normalizedSource == LyricSourceType.amll.name) {
    return LyricSource(LyricSourceType.amll, amllTtmlFile: id);
  }
  if (normalizedSource == LyricSourceType.local.name) {
    return LyricSource(
      LyricSourceType.local,
      localLyricPath: _normalizedLocalLyricPath(id),
    );
  }
  return LyricSource(LyricSourceType.local);
}

String? _normalizedSourceName(Object? value) {
  final normalized = value?.toString().trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return null;
  final separator = normalized.lastIndexOf('.');
  return separator < 0 ? normalized : normalized.substring(separator + 1);
}

int? _normalizedNeSongId(Object value) {
  if (value is int) return value <= 0 ? null : value;
  final number = switch (value) {
    num() => value.toDouble(),
    String() => double.tryParse(value.trim()),
    _ => null,
  };
  if (number == null || !number.isFinite) return null;
  if (number != number.truncateToDouble()) return null;
  final id = number.toInt();
  return id <= 0 ? null : id;
}

String? _normalizedTextSongId(Object? value) {
  if (value == null) return null;
  if (value is int) return value <= 0 ? null : value.toString();
  if (value is num) {
    if (!value.isFinite) return null;
    if (value <= 0) return null;
    if (value == value.truncateToDouble()) {
      return value.toInt().toString();
    }
    return null;
  }
  final normalized = value.toString().trim();
  return normalized.isEmpty ? null : normalized;
}

String? _normalizedLocalLyricPath(Object? value) {
  final normalized = value?.toString().trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
