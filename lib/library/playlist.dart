import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/painting.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/core/utils.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as p;

List<Playlist> PLAYLISTS = [];

Future<void> readPlaylists() async {
  PLAYLISTS = [];
  try {
    final dir = await getAppDataDir();
    final jsonFile = File(p.join(dir.path, 'playlists.json'));

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
    final rows = db.select('SELECT id, name, cover_source FROM playlists ORDER BY name');
    for (final row in rows) {
      final id = row['id'] as int;
      final name = row['name'] as String;
      final coverSource = row['cover_source'] as String?;
      final paths = <String>[];
      final items = db.select(
        'SELECT path FROM playlist_items WHERE playlist_id = ? ORDER BY sort_order, path',
        [id],
      );
      for (final item in items) {
        paths.add(item['path'] as String);
      }
      playlists.add(Playlist(name, paths)..id = id..coverSource = coverSource);
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
    final existing = db.select('SELECT id, name FROM playlists');
    final existingByName = <String, int>{};
    final existingIds = <int>{};
    for (final row in existing) {
      final id = row['id'] as int;
      final name = row['name'] as String;
      existingByName[name] = id;
      existingIds.add(id);
    }

    final keptIds = <int>{};
    for (final pl in playlists) {
      final existingId = existingByName[pl.name];
      int playlistId;
      if (existingId != null) {
        playlistId = existingId;
        keptIds.add(playlistId);
        db.execute('UPDATE playlists SET cover_source = ? WHERE id = ?',
            [pl.coverSource, playlistId]);
        db.execute('DELETE FROM playlist_items WHERE playlist_id = ?',
            [playlistId]);
      } else {
        db.execute('INSERT INTO playlists(name, cover_source) VALUES(?, ?)',
            [pl.name, pl.coverSource]);
        playlistId = db.lastInsertRowId;
        keptIds.add(playlistId);
      }
      pl.id = playlistId;
      for (int i = 0; i < pl.paths.length; i++) {
        db.execute(
          'INSERT INTO playlist_items(playlist_id, path, sort_order) VALUES(?, ?, ?)',
          [playlistId, pl.paths[i], i],
        );
      }
    }

    for (final id in existingIds.difference(keptIds)) {
      db.execute('DELETE FROM playlist_items WHERE playlist_id = ?', [id]);
      db.execute('DELETE FROM playlists WHERE id = ?', [id]);
    }

    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

Future<Playlist?> importPlaylistFromFile() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['m3u', 'm3u8', 'pls', 'txt'],
    allowMultiple: false,
  );
  if (result == null || result.files.isEmpty) return null;
  final file = File(result.files.single.path!);
  final content = await file.readAsString();
  final ext = p.extension(file.path).toLowerCase();

  List<String> rawPaths;
  if (ext == '.pls') {
    rawPaths = _parsePls(content);
  } else {
    rawPaths = _parsePathList(content);
  }

  final resolved = <String>[];
  final collection = AudioLibrary.instance.audioCollection;
  for (final raw in rawPaths) {
    if (File(raw).existsSync()) {
      resolved.add(raw);
      continue;
    }
    final fileName = p.basename(raw);
    final match = collection.where((a) => p.basename(a.path) == fileName);
    if (match.isNotEmpty) resolved.add(match.first.path);
  }
  if (resolved.isEmpty) return null;
  final basename = p.basenameWithoutExtension(file.path);
  return Playlist(basename, resolved);
}

Future<void> exportPlaylistToFile(Playlist playlist) async {
  final result = await FilePicker.platform.saveFile(
    dialogTitle: '导出歌单 - ${playlist.name}',
    fileName: '${playlist.name}.m3u8',
    type: FileType.custom,
    allowedExtensions: ['m3u8', 'm3u', 'txt'],
  );
  if (result == null) return;
  final ext = p.extension(result).toLowerCase();
  final isTxt = ext == '.txt';
  final sb = StringBuffer();
  if (!isTxt) sb.writeln('#EXTM3U');
  for (final path in playlist.paths) {
    sb.writeln(path);
  }
  await File(result).writeAsString(sb.toString(), encoding: utf8);
}

List<String> _parsePathList(String content) {
  final paths = <String>[];
  for (final line in content.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    paths.add(trimmed);
  }
  return paths;
}

List<String> _parsePls(String content) {
  final paths = <String>[];
  final fileRegex = RegExp(r'^File(\d+)=(.*)', caseSensitive: false);
  for (final line in content.split('\n')) {
    final match = fileRegex.firstMatch(line.trim());
    if (match != null) {
      paths.add(match.group(2)!.trim());
    }
  }
  return paths;
}

class Playlist {
  int? id;
  String name;
  List<String> paths;
  String? coverSource;

  Playlist(this.name, this.paths);

  Future<Uint8List?> resolveCoverBytes() async {
    if (coverSource == null || coverSource!.isEmpty) return null;
    if (coverSource!.startsWith('file:')) {
      final file = File(coverSource!.substring(5));
      if (file.existsSync()) return file.readAsBytes();
      return null;
    }
    Audio? target;
    if (coverSource!.startsWith('album:')) {
      final album =
          AudioLibrary.instance.albumCollection[coverSource!.substring(6)];
      if (album != null && album.works.isNotEmpty) target = album.works.first;
    } else if (coverSource!.startsWith('artist:')) {
      final artist =
          AudioLibrary.instance.artistCollection[coverSource!.substring(7)];
      if (artist != null && artist.works.isNotEmpty) target = artist.works.first;
    }
    if (target != null) return target.loadSmallCoverBytes();
    return null;
  }

  Future<ImageProvider?> resolveCoverProvider() async {
    if (coverSource == null || coverSource!.isEmpty) return null;
    if (coverSource!.startsWith('file:')) {
      final file = File(coverSource!.substring(5));
      if (file.existsSync()) return FileImage(file);
      return null;
    }
    if (coverSource!.startsWith('album:')) {
      final album =
          AudioLibrary.instance.albumCollection[coverSource!.substring(6)];
      if (album != null) return album.cover;
      return null;
    }
    if (coverSource!.startsWith('artist:')) {
      final artist =
          AudioLibrary.instance.artistCollection[coverSource!.substring(7)];
      if (artist != null) return artist.picture;
      return null;
    }
    return null;
  }

  List<Audio> get audios {
    final collection = AudioLibrary.instance.audioCollection;
    return paths
        .map((p) {
          final i = collection.indexWhere((a) => a.path == p);
          return i >= 0 ? collection[i] : null;
        })
        .whereType<Audio>()
        .toList();
  }

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
