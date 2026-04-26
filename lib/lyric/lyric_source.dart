import 'dart:convert';
import 'dart:io';

import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:sqlite3/sqlite3.dart';

enum LyricSourceType {
  qq("qq"),
  kugou("kugou"),
  ne("ne"),
  local("local");

  final String name;
  const LyricSourceType(this.name);
}

/// 默认歌词来源
class LyricSource {
  LyricSourceType source;
  String? qqSongId;
  String? kugouSongHash;
  int? neSongId;

  LyricSource(this.source, {this.qqSongId, this.kugouSongHash, this.neSongId});

  static LyricSource fromMap(Map map) {
    if (map["source"] == "qq") {
      return LyricSource(LyricSourceType.qq, qqSongId: map["id"]?.toString());
    } else if (map["source"] == "kugou") {
      return LyricSource(LyricSourceType.kugou, kugouSongHash: map["id"]);
    } else if (map["source"] == "ne") {
      return LyricSource(LyricSourceType.ne, neSongId: map["id"]);
    } else {
      return LyricSource(LyricSourceType.local);
    }
  }

  Map toMap() {
    switch (source) {
      case LyricSourceType.qq:
        return {"source": source.name, "id": qqSongId};
      case LyricSourceType.kugou:
        return {"source": source.name, "id": kugouSongHash};
      case LyricSourceType.ne:
        return {"source": source.name, "id": neSongId};
      case LyricSourceType.local:
        return {"source": source.name, "id": null};
    }
  }
}

Map<String, LyricSource> lyricSources = {};

Future<void> readLyricSources() async {
  lyricSources = {};
  try {
    final dir = await getAppDataDir();
    final jsonFile =
        File('${dir.path}${Platform.pathSeparator}lyric_source.json');

    final db = await AppDb.instance.db();
    final count =
        db.select("SELECT COUNT(1) AS c FROM lyric_sources").first["c"] as int;
    if (count == 0 && jsonFile.existsSync()) {
      final fromJson = _readLyricSourcesFromJson(jsonFile);
      _writeLyricSourcesToDb(db, fromJson);
      lyricSources = fromJson;
      return;
    }

    final result = <String, LyricSource>{};
    final rows = db.select("SELECT path, source, id FROM lyric_sources");
    for (final row in rows) {
      final p = row["path"] as String;
      if (!File(p).existsSync()) continue;
      final source = row["source"] as String;
      final id = row["id"] as String?;
      final ls = _lyricSourceFromDb(source, id);
      if (ls != null) {
        result[p] = ls;
      }
    }
    lyricSources = result;
  } catch (err, trace) {
    logger.e(err, stackTrace: trace);
  }
}

Future<void> saveLyricSources() async {
  try {
    final db = await AppDb.instance.db();
    _writeLyricSourcesToDb(db, lyricSources);
  } catch (err, trace) {
    logger.e(err, stackTrace: trace);
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
    if (!File(p).existsSync()) continue;
    result[p] = LyricSource.fromMap(item.value as Map);
  }
  return result;
}

void _writeLyricSourcesToDb(Database db, Map<String, LyricSource> sources) {
  db.execute("BEGIN");
  try {
    db.execute("DELETE FROM lyric_sources");
    for (final e in sources.entries) {
      final p = e.key;
      final s = e.value.source.name;
      final id = _lyricSourceId(e.value);
      db.execute(
        "INSERT INTO lyric_sources(path, source, id) VALUES(?, ?, ?)",
        [p, s, id],
      );
    }
    db.execute("COMMIT");
  } catch (_) {
    db.execute("ROLLBACK");
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
    case LyricSourceType.local:
      return null;
  }
}

LyricSource? _lyricSourceFromDb(String source, String? id) {
  if (source == LyricSourceType.qq.name) {
    return LyricSource(
      LyricSourceType.qq,
      qqSongId: id,
    );
  }
  if (source == LyricSourceType.kugou.name) {
    return LyricSource(LyricSourceType.kugou, kugouSongHash: id);
  }
  if (source == LyricSourceType.ne.name) {
    return LyricSource(LyricSourceType.ne,
        neSongId: id == null ? null : int.tryParse(id));
  }
  return LyricSource(LyricSourceType.local);
}
