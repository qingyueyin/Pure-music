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
    final jsonFile = File('${dir.path}\\playlists.json');

    final db = await AppDb.instance.db();
    final playlistCount =
        db.select('SELECT COUNT(1) AS c FROM playlists').first['c'] as int;
    if (playlistCount == 0 && jsonFile.existsSync()) {
      final fromJson = _readPlaylistsFromJson(jsonFile);
      _writePlaylistsToDb(db, fromJson);
      PLAYLISTS = fromJson;
      return;
    }

    final playlists = <Playlist>[];
    final rows = db.select('SELECT id, name FROM playlists ORDER BY name');
    for (final row in rows) {
      final id = row['id'] as int;
      final name = row['name'] as String;
      final paths = <String>[];
      final items = db.select(
        'SELECT path FROM playlist_items WHERE playlist_id = ? ORDER BY path',
        [id],
      );
      for (final item in items) {
        paths.add(item['path'] as String);
      }
      playlists.add(Playlist(name, paths));
    }
    PLAYLISTS = playlists;
  } catch (err, trace) {
    logger.e(err, stackTrace: trace);
  }
}

Future<void> savePlaylists() async {
  try {
    final db = await AppDb.instance.db();
    _writePlaylistsToDb(db, PLAYLISTS);
  } catch (err, trace) {
    logger.e(err, stackTrace: trace);
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
  db.execute('BEGIN');
  try {
    db.execute('DELETE FROM playlist_items');
    db.execute('DELETE FROM playlists');
    for (final pl in playlists) {
      db.execute('INSERT INTO playlists(name) VALUES(?)', [pl.name]);
      final playlistId = db.lastInsertRowId;
      for (final p in pl.paths) {
        db.execute(
          'INSERT INTO playlist_items(playlist_id, path) VALUES(?, ?)',
          [playlistId, p],
        );
      }
    }
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

class Playlist {
  String name;

  List<String> paths;

  Playlist(this.name, this.paths);

  List<Audio> get audios => paths
      .map((p) => AudioLibrary.instance.audioCollection
          .firstWhere((a) => a.path == p))
      .whereType<Audio>()
      .toList();

  bool containsPath(String path) => paths.contains(path);

  void addPath(String path) {
    if (!paths.contains(path)) {
      paths.add(path);
    }
  }

  void removeByPath(String path) {
    paths.remove(path);
  }

  Map toMap() => {'name': name, 'audios': paths};

  factory Playlist.fromMap(Map map) {
    final paths = <String>[];
    final rawAudios = map['audios'];
    if (rawAudios is List) {
      for (var item in rawAudios) {
        if (item is Map) {
          final p = item['path'];
          if (p is String) paths.add(p);
        } else if (item is String) {
          paths.add(item);
        }
      }
    }
    return Playlist(map['name'] ?? '', paths);
  }
}
