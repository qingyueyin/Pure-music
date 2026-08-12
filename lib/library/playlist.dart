import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/painting.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/core/utils.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as p;

final List<Playlist> playlists = [];

String _playlistPathKey(String value) {
  var normalized = value.trim().replaceAll('\\', '/');
  while (normalized.endsWith('/') && normalized.length > 1) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized.toLowerCase();
}

List<String> _uniquePlaylistPaths(Iterable<String> paths) {
  final result = <String>[];
  final seen = <String>{};
  for (final path in paths) {
    final key = _playlistPathKey(path);
    if (key.isEmpty || !seen.add(key)) continue;
    result.add(path);
  }
  return result;
}

String importedPlaylistFileNameKey(String value) {
  return p.basename(value.trim()).toLowerCase();
}

String? findImportedPlaylistLibraryPath({
  required String rawPath,
  required Iterable<String> libraryPaths,
}) {
  final fileNameKey = importedPlaylistFileNameKey(rawPath);
  if (fileNameKey.isEmpty) return null;
  for (final libraryPath in libraryPaths) {
    if (importedPlaylistFileNameKey(libraryPath) == fileNameKey) {
      return libraryPath;
    }
  }
  return null;
}

Future<void> readPlaylists() async {
  final stopwatch = Stopwatch()..start();
  playlists.clear();
  try {
    final dir = await getAppDataDir();
    final jsonFile = File(p.join(dir.path, 'playlists.json'));

    final db = await AppDb.instance.db();
    final playlistCount =
        db.select('SELECT COUNT(1) AS c FROM playlists').first['c'] as int;
    if (playlistCount == 0 && jsonFile.existsSync()) {
      final fromJson = _readPlaylistsFromJson(jsonFile);
      _writePlaylistsToDb(db, fromJson);
      playlists.addAll(fromJson);
      logger.i(
        '[perf] playlists load=${stopwatch.elapsedMilliseconds}ms '
        'count=${playlists.length} migrated=true',
      );
      return;
    }

    playlists.addAll(readPlaylistsFromDatabase(db));
    logger.i(
      '[perf] playlists load=${stopwatch.elapsedMilliseconds}ms '
      'count=${playlists.length} migrated=false',
    );
  } catch (err, trace) {
    logger.e(err, stackTrace: trace);
  }
}

List<Playlist> readPlaylistsFromDatabase(Database db) {
  final playlistRows = db.select(
    'SELECT id, name, cover_source FROM playlists ORDER BY name',
  );
  if (playlistRows.isEmpty) return <Playlist>[];

  final pathsByPlaylistId = <int, List<String>>{};
  final addedAtByPlaylistId = <int, Map<String, DateTime>>{};
  final itemRows = db.select(
    'SELECT playlist_id, path, added_at FROM playlist_items '
    'ORDER BY playlist_id, sort_order, path',
  );
  for (final item in itemRows) {
    final playlistId = item['playlist_id'] as int;
    final path = item['path'] as String;
    pathsByPlaylistId.putIfAbsent(playlistId, () => <String>[]).add(path);
    final addedAt = DateTime.tryParse(item['added_at'] as String? ?? '');
    if (addedAt != null) {
      addedAtByPlaylistId.putIfAbsent(
        playlistId,
        () => <String, DateTime>{},
      )[_playlistPathKey(path)] = addedAt;
    }
  }

  return playlistRows
      .map((row) {
        final id = row['id'] as int;
        return Playlist(
            row['name'] as String,
            pathsByPlaylistId[id] ?? const [],
          )
          ..id = id
          ..coverSource = row['cover_source'] as String?
          .._addedAt.addAll(addedAtByPlaylistId[id] ?? const {});
      })
      .toList();
}

Future<bool> savePlaylists() async {
  try {
    final db = await AppDb.instance.db();
    _writePlaylistsToDb(db, playlists);
    return true;
  } catch (err, trace) {
    logger.e(err, stackTrace: trace);
    return false;
  }
}

final class PlaylistAlreadyExistsException implements Exception {
  const PlaylistAlreadyExistsException();
}

bool _isTransientPlaylistWriteError(SqliteException error) {
  return error.resultCode == SqlError.SQLITE_BUSY ||
      error.resultCode == SqlError.SQLITE_LOCKED;
}

Playlist createPlaylistInDatabase(Database db, String name) {
  final playlist = Playlist(name.trim(), const []);
  try {
    final inserted = db.select(
      'INSERT INTO playlists(name, cover_source) VALUES(?, NULL) RETURNING id',
      [playlist.name],
    );
    playlist.id = inserted.single['id'] as int;
    return playlist;
  } on SqliteException catch (err) {
    if (err.resultCode == SqlError.SQLITE_CONSTRAINT) {
      throw const PlaylistAlreadyExistsException();
    }
    rethrow;
  }
}

Future<Playlist> createPlaylist(String name) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    final db = await AppDb.instance.db();
    try {
      return createPlaylistInDatabase(db, name);
    } on SqliteException catch (err) {
      if (attempt == 0 && _isTransientPlaylistWriteError(err)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        continue;
      }
      rethrow;
    }
  }
  throw StateError('Playlist creation retry exhausted');
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
        db.execute(
            'DELETE FROM playlist_items WHERE playlist_id = ?', [playlistId]);
      } else {
        db.execute('INSERT INTO playlists(name, cover_source) VALUES(?, ?)',
            [pl.name, pl.coverSource]);
        playlistId = db.lastInsertRowId;
        keptIds.add(playlistId);
      }
      pl.id = playlistId;
      for (int i = 0; i < pl.paths.length; i++) {
        final p = pl.paths[i];
        final addedAt = pl._addedAt[_playlistPathKey(p)];
        final addedAtStr = addedAt?.toIso8601String();
        db.execute(
          'INSERT INTO playlist_items(playlist_id, path, sort_order, added_at) VALUES(?, ?, ?, ?)',
          [playlistId, p, i, addedAtStr],
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
    final matchedPath = findImportedPlaylistLibraryPath(
      rawPath: raw,
      libraryPaths: collection.map((a) => a.path),
    );
    if (matchedPath != null) resolved.add(matchedPath);
  }
  if (resolved.isEmpty) return null;
  final basename = p.basenameWithoutExtension(file.path);
  return Playlist(basename, resolved);
}

Future<bool> exportPlaylistToFile(Playlist playlist) async {
  final result = await FilePicker.platform.saveFile(
    dialogTitle: '导出歌单 - ${playlist.name}',
    fileName: '${playlist.name}.m3u8',
    type: FileType.custom,
    allowedExtensions: ['m3u8', 'm3u', 'txt'],
  );
  if (result == null) return false;
  final ext = p.extension(result).toLowerCase();
  final isTxt = ext == '.txt';
  final sb = StringBuffer();
  if (!isTxt) sb.writeln('#EXTM3U');
  for (final path in playlist.paths) {
    sb.writeln(path);
  }
  await writeTextFileAtomically(result, sb.toString());
  return true;
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
  Set<String>? _pathKeys;
  final Map<String, DateTime> _addedAt = {};
  List<Audio>? _audiosCache;
  AudioLibrary? _audiosCacheLibrary;

  Playlist(this.name, List<String> paths) : paths = _uniquePlaylistPaths(paths) {
    var ms = DateTime.now().millisecondsSinceEpoch;
    for (final path in this.paths) {
      _addedAt.putIfAbsent(_playlistPathKey(path), () => DateTime.fromMillisecondsSinceEpoch(ms++));
    }
  }

  DateTime addedAt(String path) {
    final key = _playlistPathKey(path);
    return _addedAt[key] ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  Set<String> get _pathKeySet {
    return _pathKeys ??=
        paths.map(_playlistPathKey).where((key) => key.isNotEmpty).toSet();
  }

  void _invalidateAudioCache() {
    _audiosCache = null;
    _audiosCacheLibrary = null;
  }

  Future<Uint8List?> resolveCoverBytes() async {
    if (coverSource == null || coverSource!.isEmpty) return null;
    if (coverSource!.startsWith('file:')) {
      final file = File(coverSource!.substring(5));
      if (file.existsSync()) return file.readAsBytes();
      return null;
    }
    Audio? target;
    if (coverSource!.startsWith('audio:')) {
      target = AudioLibrary.instance.audioByPath(coverSource!.substring(6));
    } else if (coverSource!.startsWith('album:')) {
      final album =
          AudioLibrary.instance.albumCollection[coverSource!.substring(6)];
      if (album != null && album.works.isNotEmpty) target = album.works.first;
    } else if (coverSource!.startsWith('artist:')) {
      final artist =
          AudioLibrary.instance.artistCollection[coverSource!.substring(7)];
      if (artist != null && artist.works.isNotEmpty) {
        target = artist.works.first;
      }
    }
    if (target != null) return target.loadSmallCoverBytes();
    return null;
  }

  Future<ImageProvider?> resolveCoverProvider({int size = 200}) async {
    if (coverSource == null || coverSource!.isEmpty) return null;
    if (coverSource!.startsWith('file:')) {
      final file = File(coverSource!.substring(5));
      if (!file.existsSync()) return null;
      final ratio = PlatformDispatcher.instance.views.first.devicePixelRatio;
      return ResizeImage(
        FileImage(file),
        width: (size * ratio).round(),
        height: (size * ratio).round(),
      );
    }
    if (coverSource!.startsWith('audio:')) {
      final audio = AudioLibrary.instance.audioByPath(
        coverSource!.substring(6),
      );
      if (audio == null) return null;
      return size <= 48 ? audio.cover : audio.mediumCover;
    }
    if (coverSource!.startsWith('album:')) {
      final album =
          AudioLibrary.instance.albumCollection[coverSource!.substring(6)];
      if (album != null) return album.thumbnailCover(size: size);
      return null;
    }
    if (coverSource!.startsWith('artist:')) {
      final artist =
          AudioLibrary.instance.artistCollection[coverSource!.substring(7)];
      if (artist != null) return artist.thumbnailPicture(size: size);
      return null;
    }
    return null;
  }

  List<Audio> get audios {
    final library = AudioLibrary.instance;
    final cached = _audiosCache;
    if (cached != null && identical(_audiosCacheLibrary, library)) {
      return List<Audio>.from(cached);
    }
    final resolved = paths
        .map((path) {
          final key = _playlistPathKey(path);
          if (key.isEmpty) return null;
          return library.audioByPath(path);
        })
        .whereType<Audio>()
        .toList();
    _audiosCache = resolved;
    _audiosCacheLibrary = library;
    return List<Audio>.from(resolved);
  }

  Audio? get firstAudio {
    final library = AudioLibrary.instance;
    final cached = _audiosCache;
    if (cached != null && identical(_audiosCacheLibrary, library)) {
      return cached.isEmpty ? null : cached.first;
    }
    for (final path in paths) {
      final key = _playlistPathKey(path);
      if (key.isEmpty) continue;
      final audio = library.audioByPath(path);
      if (audio != null) return audio;
    }
    return null;
  }

  bool containsPath(String path) {
    final key = _playlistPathKey(path);
    if (key.isEmpty) return false;
    return _pathKeySet.contains(key);
  }

  void addPath(String path) {
    final key = _playlistPathKey(path);
    if (key.isEmpty) return;
    if (_pathKeySet.add(key)) {
      paths.add(path);
      _addedAt[key] = DateTime.now();
      _invalidateAudioCache();
    }
  }

  void removeByPath(String path) {
    final key = _playlistPathKey(path);
    if (key.isEmpty) return;
    if (!_pathKeySet.contains(key)) return;
    paths.removeWhere((item) => _playlistPathKey(item) == key);
    _pathKeys?.remove(key);
    _addedAt.remove(key);
    _invalidateAudioCache();
  }

  void replacePaths(Iterable<String> paths) {
    this.paths = _uniquePlaylistPaths(paths);
    _pathKeys = null;
    _addedAt.clear();
    var ms = DateTime.now().millisecondsSinceEpoch;
    for (final path in this.paths) {
      _addedAt[_playlistPathKey(path)] = DateTime.fromMillisecondsSinceEpoch(ms++);
    }
    _invalidateAudioCache();
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
