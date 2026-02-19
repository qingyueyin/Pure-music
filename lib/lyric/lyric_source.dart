import 'dart:convert';
import 'dart:io';

import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:sqlite3/sqlite3.dart';

enum LyricSourceType {
  qq("qq"),
  kugou("kugou"),
  netease("netease"),
  local("local");

  final String name;
  const LyricSourceType(this.name);
}

/// 默认歌词来源
class LyricSource {
  LyricSourceType source;
  int? qqSongId;
  String? kugouSongHash;
  String? neteaseSongId;

  LyricSource(this.source,
      {this.qqSongId, this.kugouSongHash, this.neteaseSongId});

  static LyricSource fromMap(Map map) {
    if (map["source"] == "qq") {
      return LyricSource(LyricSourceType.qq, qqSongId: map["id"]);
    } else if (map["source"] == "kugou") {
      return LyricSource(LyricSourceType.kugou, kugouSongHash: map["id"]);
    } else if (map["source"] == "netease") {
      return LyricSource(LyricSourceType.netease, neteaseSongId: map["id"]);
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
      case LyricSourceType.netease:
        return {"source": source.name, "id": neteaseSongId};
      case LyricSourceType.local:
        return {"source": source.name, "id": null};
    }
  }
}

Map<String, LyricSource> LYRIC_SOURCES = {};

Future<void> readLyricSources() async {
  LYRIC_SOURCES = {};
  try {
    final dir = await getAppDataDir();
    final jsonFile = File("${dir.path}\\lyric_source.json");

    final db = await AppDb.instance.db();
    final count = db.select("SELECT COUNT(1) AS c FROM lyric_sources").first["c"] as int;
    if (count == 0 && jsonFile.existsSync()) {
      final fromJson = _readLyricSourcesFromJson(jsonFile);
      _writeLyricSourcesToDb(db, fromJson);
      LYRIC_SOURCES = fromJson;
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
    LYRIC_SOURCES = result;
  } catch (err, trace) {
    LOGGER.e(err, stackTrace: trace);
  }
}

Future<void> saveLyricSources() async {
  try {
    final db = await AppDb.instance.db();
    _writeLyricSourcesToDb(db, LYRIC_SOURCES);
  } catch (err, trace) {
    LOGGER.e(err, stackTrace: trace);
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
    case LyricSourceType.netease:
      return s.neteaseSongId;
    case LyricSourceType.local:
      return null;
  }
}

LyricSource? _lyricSourceFromDb(String source, String? id) {
  if (source == LyricSourceType.qq.name) {
    return LyricSource(
      LyricSourceType.qq,
      qqSongId: id == null ? null : int.tryParse(id),
    );
  }
  if (source == LyricSourceType.kugou.name) {
    return LyricSource(LyricSourceType.kugou, kugouSongHash: id);
  }
  if (source == LyricSourceType.netease.name) {
    return LyricSource(LyricSourceType.netease, neteaseSongId: id);
  }
  return LyricSource(LyricSourceType.local);
}
