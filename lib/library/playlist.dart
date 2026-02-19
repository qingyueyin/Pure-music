// ignore_for_file: non_constant_identifier_names

import 'dart:convert';
import 'dart:io';

import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/core/utils.dart';
import 'package:sqlite3/sqlite3.dart';

List<Playlist> PLAYLISTS = [];

Future<void> readPlaylists() async {
  PLAYLISTS = [];
  try {
    final dir = await getAppDataDir();
    final jsonFile = File("${dir.path}\\playlists.json");

    final db = await AppDb.instance.db();
    final playlistCount = db.select("SELECT COUNT(1) AS c FROM playlists").first["c"] as int;
    if (playlistCount == 0 && jsonFile.existsSync()) {
      final fromJson = _readPlaylistsFromJson(jsonFile);
      _writePlaylistsToDb(db, fromJson);
      PLAYLISTS = fromJson;
      return;
    }

    final playlists = <Playlist>[];
    final rows = db.select("SELECT id, name FROM playlists ORDER BY name");
    for (final row in rows) {
      final id = row["id"] as int;
      final name = row["name"] as String;
      final audios = <String, Audio>{};
      final items = db.select(
        "SELECT path, audio_json FROM playlist_items WHERE playlist_id = ? ORDER BY path",
        [id],
      );
      for (final item in items) {
        final p = item["path"] as String;
        final raw = item["audio_json"] as String;
        final decoded = json.decode(raw);
        if (decoded is Map) {
          final audio = Audio.fromMap(decoded);
          audios[p] = audio;
        }
      }
      playlists.add(Playlist(name, audios));
    }
    PLAYLISTS = playlists;
  } catch (err, trace) {
    LOGGER.e(err, stackTrace: trace);
  }
}

Future<void> savePlaylists() async {
  try {
    final db = await AppDb.instance.db();
    _writePlaylistsToDb(db, PLAYLISTS);
  } catch (err, trace) {
    LOGGER.e(err, stackTrace: trace);
  }
}

List<Playlist> _readPlaylistsFromJson(File jsonFile) {
  final playlists = <Playlist>[];
  final playlistsStr = jsonFile.readAsStringSync();
  final decoded = json.decode(playlistsStr);
  if (decoded is! List) return playlists;
  for (final item in decoded) {
    if (item is Map) {
      playlists.add(Playlist.fromMap(item));
    }
  }
  return playlists;
}

void _writePlaylistsToDb(Database db, List<Playlist> playlists) {
  db.execute("BEGIN");
  try {
    db.execute("DELETE FROM playlist_items");
    db.execute("DELETE FROM playlists");
    for (final pl in playlists) {
      db.execute("INSERT INTO playlists(name) VALUES(?)", [pl.name]);
      final playlistId = db.lastInsertRowId;
      for (final e in pl.audios.entries) {
        db.execute(
          "INSERT INTO playlist_items(playlist_id, path, audio_json) VALUES(?, ?, ?)",
          [playlistId, e.key, json.encode(e.value.toMap())],
        );
      }
    }
    db.execute("COMMIT");
  } catch (_) {
    db.execute("ROLLBACK");
    rethrow;
  }
}

class Playlist {
  String name;

  /// path, audio
  Map<String, Audio> audios;

  Playlist(this.name, this.audios);

  Map toMap() {
    final List<Map> audioMaps = [];
    for (var item in audios.values) {
      audioMaps.add(item.toMap());
    }
    return {"name": name, "audios": audioMaps};
  }

  factory Playlist.fromMap(Map map) {
    final Map<String, Audio> audios = {};
    final List audioMaps = map["audios"];
    for (var item in audioMaps) {
      final audio = Audio.fromMap(item);
      audios[audio.path] = audio;
    }
    return Playlist(map["name"], audios);
  }
}
