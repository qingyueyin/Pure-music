import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as library_db;
import 'package:pure_music/services/lastfm/lastfm_models.dart';
import 'package:sqlite3/sqlite3.dart';

/// 备份类别。不含曲库索引本身，只含用户数据与偏好。
enum BackupCategory {
  settings('设置', '界面、播放、歌词等偏好'),
  playlists('歌单与歌词来源', '歌单、歌词匹配来源'),
  playCounts('播放统计', '每首曲目的播放次数'),
  lastfm('Last.fm 账号', '登录凭证');

  const BackupCategory(this.label, this.description);

  final String label;
  final String description;
}

/// settings 类别打包的文件，路径相对于应用数据目录。
const List<String> _settingsFiles = [
  'settings/settings.json',
  'settings/app_preference.json',
  'settings/playback_pref.json',
];

/// 设置里引用外部文件的字段，导出时把文件一并打包，导入时还原并改写路径。
const List<String> _externalPathKeys = ['FontPath', 'LyricFontPath'];

const String _manifestName = 'manifest.json';
const String _externalDir = 'external';
const String _playlistsEntryName = 'playlists.json';
const String _lyricSourcesEntryName = 'lyric_sources.json';
const String _playCountsEntryName = 'play_counts.json';
const String _lastfmEntryName = 'lastfm.json';
const int _backupFormatVersion = 2;
const int _maxBackupArchiveBytes = 128 * 1024 * 1024;
const int _maxBackupEntryBytes = 64 * 1024 * 1024;
const int _maxBackupExpandedBytes = 256 * 1024 * 1024;

/// 把选中的类别打包成 zip，返回导出文件路径；用户取消时返回 null。
Future<String?> exportBackup({
  required String targetPath,
  required Set<BackupCategory> categories,
}) async {
  final root = await getAppDataDir();
  final archive = Archive();
  final externalFiles = <String, String>{};

  if (categories.contains(BackupCategory.settings)) {
    _collectExternalFiles(root, externalFiles);
    for (final rel in _settingsFiles) {
      final file = File(p.join(root.path, rel));
      if (!file.existsSync()) continue;
      final bytes = rel == 'settings/settings.json'
          ? _readSettingsBackupFile(file, externalFiles)
          : _readBackupFile(file);
      archive.addFile(ArchiveFile(rel, bytes.length, bytes));
    }
  }

  if (categories.contains(BackupCategory.playlists)) {
    final db = await AppDb.instance.db();
    _addJsonEntry(archive, _playlistsEntryName, _exportPlaylists(db));
    _addJsonEntry(archive, _lyricSourcesEntryName, _exportLyricSources(db));
  }

  if (categories.contains(BackupCategory.playCounts)) {
    final entries = await library_db.exportPlayCounts(indexPath: root.path);
    final list = entries
        .map(
          (e) => {
            'path': e.path,
            'title': e.title,
            'artist': e.artist,
            'album': e.album,
            'playCount': e.playCount,
          },
        )
        .toList();
    _addJsonEntry(archive, _playCountsEntryName, list);
  }

  if (categories.contains(BackupCategory.lastfm)) {
    final db = await AppDb.instance.db();
    final credentials = _readMetaMap(db, 'lastfm_credentials');
    if (credentials != null) {
      _addJsonEntry(archive, _lastfmEntryName, credentials);
    }
  }

  for (final entry in externalFiles.entries) {
    final source = File(entry.value);
    if (!source.existsSync()) continue;
    final bytes = _readBackupFile(source);
    final name = p.basename(source.path);
    archive.addFile(ArchiveFile('$_externalDir/$name', bytes.length, bytes));
  }

  final manifestExternalFiles = <String, String>{};
  for (final entry in externalFiles.entries) {
    final name = p.basename(entry.value);
    if (name.isNotEmpty && name != '.' && name != p.separator) {
      manifestExternalFiles[entry.key] = name;
    }
  }
  final manifest = {
    'formatVersion': _backupFormatVersion,
    'categories': categories.map((c) => c.name).toList(),
    'externalFiles': manifestExternalFiles,
  };
  final manifestBytes = utf8.encode(jsonEncode(manifest));
  archive.addFile(
    ArchiveFile(_manifestName, manifestBytes.length, manifestBytes),
  );

  final encoder = ZipEncoder();
  final data = encoder.encode(archive);
  if (data == null) {
    throw StateError('备份打包失败');
  }
  if (data.length > _maxBackupArchiveBytes) {
    throw StateError('备份文件过大');
  }
  await File(targetPath).writeAsBytes(data, flush: true);
  return targetPath;
}

List<int> _readBackupFile(File file) {
  final size = file.lengthSync();
  if (size > _maxBackupEntryBytes) {
    throw StateError('备份内容过大：${file.path}');
  }
  return file.readAsBytesSync();
}

List<int> _readSettingsBackupFile(
  File file,
  Map<String, String> externalFiles,
) {
  final decoded = jsonDecode(utf8.decode(_readBackupFile(file)));
  if (decoded is! Map) {
    throw const FormatException('设置文件格式无效');
  }
  final sanitized = Map<String, dynamic>.from(decoded);
  for (final key in _externalPathKeys) {
    final source = externalFiles[key];
    sanitized[key] = source == null
        ? null
        : '$_externalDir/${p.basename(source)}';
  }
  return utf8.encode(jsonEncode(sanitized));
}

void _addJsonEntry(Archive archive, String name, Object data) {
  final bytes = utf8.encode(jsonEncode(data));
  archive.addFile(ArchiveFile(name, bytes.length, bytes));
}

void _collectExternalFiles(Directory root, Map<String, String> out) {
  final settingsFile = File(p.join(root.path, 'settings/settings.json'));
  if (!settingsFile.existsSync()) return;
  try {
    final settingsMap = jsonDecode(settingsFile.readAsStringSync());
    if (settingsMap is! Map) return;
    for (final key in _externalPathKeys) {
      final value = settingsMap[key];
      if (value is String && value.isNotEmpty && File(value).existsSync()) {
        out[key] = value;
      }
    }
  } catch (_) {
    // settings.json 损坏时跳过外部文件收集，不影响其余导出
  }
}

List<Map<String, Object?>> _exportPlaylists(Database db) {
  final playlistRows = db.select(
    'SELECT id, name, cover_source FROM playlists',
  );
  final itemRows = db.select(
    'SELECT playlist_id, path, sort_order, added_at FROM playlist_items '
    'ORDER BY playlist_id, sort_order',
  );
  final itemsByPlaylistId = <int, List<Map<String, Object?>>>{};
  for (final row in itemRows) {
    final playlistId = row['playlist_id'] as int;
    itemsByPlaylistId.putIfAbsent(playlistId, () => []).add({
      'path': row['path'],
      'sortOrder': row['sort_order'],
      'addedAt': row['added_at'],
    });
  }
  return playlistRows
      .map(
        (row) => {
          'name': row['name'],
          'coverSource': row['cover_source'],
          'items': itemsByPlaylistId[row['id'] as int] ?? const [],
        },
      )
      .toList();
}

List<Map<String, Object?>> _exportLyricSources(Database db) {
  final rows = db.select('SELECT path, source, id FROM lyric_sources');
  return rows
      .map(
        (row) => {
          'path': row['path'],
          'source': row['source'],
          'id': row['id'],
        },
      )
      .toList();
}

Map? _readMetaMap(Database db, String key) {
  final rows = db.select('SELECT value FROM meta WHERE key = ?', [key]);
  if (rows.isEmpty) return null;
  final raw = rows.first['value'];
  if (raw is! String || raw.isEmpty) return null;
  try {
    final decoded = json.decode(raw);
    return decoded is Map ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// 导入策略。
enum BackupImportMode { overwrite, merge }

/// 从 zip 导入备份。返回实际导入的类别。
Future<Set<BackupCategory>> importBackup({
  required String sourcePath,
  required BackupImportMode mode,
}) async {
  final sourceFile = File(sourcePath);
  if (sourceFile.lengthSync() > _maxBackupArchiveBytes) {
    throw const FormatException('备份文件过大');
  }
  final bytes = sourceFile.readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);
  _validateBackupArchive(archive);

  final manifestFile = archive.findFile(_manifestName);
  final categories = <BackupCategory>{};
  final externalFiles = <String, String>{};
  if (manifestFile != null) {
    try {
      final manifest = jsonDecode(utf8.decode(manifestFile.content));
      final names = manifest['categories'];
      if (names is List) {
        for (final name in names) {
          final category = BackupCategory.values
              .where((c) => c.name == name)
              .firstOrNull;
          if (category != null) categories.add(category);
        }
      }
      final ext = manifest['externalFiles'];
      if (ext is Map) {
        for (final entry in ext.entries) {
          if (entry.key is String && entry.value is String) {
            final name = p.basename(entry.value as String);
            if (name.isNotEmpty && name != '.' && name != p.separator) {
              externalFiles[entry.key as String] = name;
            }
          }
        }
      }
    } catch (_) {
      // 清单损坏时回退为按条目存在性推断
    }
  }

  if (categories.isEmpty) {
    if (_settingsFiles.any((rel) => archive.findFile(rel) != null)) {
      categories.add(BackupCategory.settings);
    }
    if (archive.findFile(_playlistsEntryName) != null ||
        archive.findFile(_lyricSourcesEntryName) != null) {
      categories.add(BackupCategory.playlists);
    }
    if (archive.findFile(_playCountsEntryName) != null) {
      categories.add(BackupCategory.playCounts);
    }
    if (archive.findFile(_lastfmEntryName) != null) {
      categories.add(BackupCategory.lastfm);
    }
  }

  final root = await getAppDataDir();
  final imported = <BackupCategory>{};

  if (categories.contains(BackupCategory.settings)) {
    await _importSettings(root, archive, mode);
    if (externalFiles.isNotEmpty) {
      await _restoreExternalFiles(root, archive, externalFiles, mode);
    }
    imported.add(BackupCategory.settings);
  }

  if (categories.contains(BackupCategory.playlists)) {
    final db = await AppDb.instance.db();
    _importPlaylistsAndLyricSources(db, archive, mode);
    imported.add(BackupCategory.playlists);
  }

  if (categories.contains(BackupCategory.playCounts)) {
    final entry = archive.findFile(_playCountsEntryName);
    if (entry != null && entry.isFile) {
      final list = jsonDecode(utf8.decode(entry.content));
      if (list is List) {
        final playCountEntries = list
            .whereType<Map>()
            .map(
              (m) => library_db.PlayCountEntry(
                path: _readString(m['path']) ?? '',
                title: _readString(m['title']) ?? '',
                artist: _readString(m['artist']) ?? '',
                album: _readString(m['album']) ?? '',
                playCount: _readInt(
                  m['playCount'],
                ).clamp(0, 0x7fffffffffffffff).toInt(),
              ),
            )
            .where((e) => e.path.isNotEmpty)
            .toList();
        await library_db.importPlayCounts(
          indexPath: root.path,
          entries: playCountEntries,
          overwrite: mode == BackupImportMode.overwrite,
        );
      }
    }
    imported.add(BackupCategory.playCounts);
  }

  if (categories.contains(BackupCategory.lastfm)) {
    final entry = archive.findFile(_lastfmEntryName);
    if (entry != null && entry.isFile) {
      final decoded = jsonDecode(utf8.decode(entry.content));
      if (decoded is Map) {
        final db = await AppDb.instance.db();
        final local = LastFmCredentials.fromMap(
          _readMetaMap(db, 'lastfm_credentials'),
        );
        if (mode == BackupImportMode.overwrite || !local.isAuthorized) {
          db.execute(
            'INSERT INTO meta(key, value) VALUES(?, ?) '
            'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
            ['lastfm_credentials', jsonEncode(decoded)],
          );
        }
      }
    }
    imported.add(BackupCategory.lastfm);
  }

  return imported;
}

Future<void> _importSettings(
  Directory root,
  Archive archive,
  BackupImportMode mode,
) async {
  for (final rel in _settingsFiles) {
    final entry = archive.findFile(rel);
    if (entry == null || !entry.isFile) continue;
    final target = File(p.join(root.path, rel));
    await target.parent.create(recursive: true);
    if (mode == BackupImportMode.overwrite) {
      await target.writeAsBytes(entry.content, flush: true);
    } else {
      await _mergeJsonFile(target, entry.content);
    }
  }
}

/// 歌单和歌词来源在同一个事务中导入，避免只完成其中一类。
void _importPlaylistsAndLyricSources(
  Database db,
  Archive archive,
  BackupImportMode mode,
) {
  db.execute('BEGIN');
  try {
    _importPlaylistsRows(db, archive, mode);
    _importLyricSourceRows(db, archive, mode);
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

/// 歌单按 name 去重：本机没有该名称则整份导入；已有同名时，
/// merge 跳过保留本机版本，overwrite 用备份整份替换。
void _importPlaylistsRows(Database db, Archive archive, BackupImportMode mode) {
  final entry = archive.findFile(_playlistsEntryName);
  if (entry == null || !entry.isFile) return;
  final decoded = jsonDecode(utf8.decode(entry.content));
  if (decoded is! List) return;

  if (mode == BackupImportMode.overwrite) {
    db.execute('DELETE FROM playlist_items');
    db.execute('DELETE FROM playlists');
  }

  for (final item in decoded) {
    if (item is! Map) continue;
    final name = _readString(item['name']);
    if (name == null || name.isEmpty) continue;
    final coverSource = _readString(item['coverSource']);
    final items = item['items'] is List ? item['items'] as List : const [];

    final existing = db.select('SELECT id FROM playlists WHERE name = ?', [
      name,
    ]);

    int playlistId;
    if (existing.isNotEmpty) {
      if (mode == BackupImportMode.merge) continue;
      playlistId = _readInt(existing.first['id']);
      db.execute('UPDATE playlists SET cover_source = ? WHERE id = ?', [
        coverSource,
        playlistId,
      ]);
      db.execute('DELETE FROM playlist_items WHERE playlist_id = ?', [
        playlistId,
      ]);
    } else {
      db.execute('INSERT INTO playlists(name, cover_source) VALUES(?, ?)', [
        name,
        coverSource,
      ]);
      playlistId = db.lastInsertRowId;
    }

    for (final rawItem in items) {
      if (rawItem is! Map) continue;
      final path = _readString(rawItem['path']);
      if (path == null || path.isEmpty) continue;
      db.execute(
        'INSERT INTO playlist_items(playlist_id, path, sort_order, added_at) '
        'VALUES(?, ?, ?, ?)',
        [
          playlistId,
          path,
          _readInt(rawItem['sortOrder']),
          _readString(rawItem['addedAt']),
        ],
      );
    }
  }
}

/// 歌词来源按 path 去重：本机没有该曲目才写入；已有时 merge 跳过、overwrite 覆盖。
void _importLyricSourceRows(
  Database db,
  Archive archive,
  BackupImportMode mode,
) {
  final entry = archive.findFile(_lyricSourcesEntryName);
  if (entry == null || !entry.isFile) return;
  final decoded = jsonDecode(utf8.decode(entry.content));
  if (decoded is! List) return;

  if (mode == BackupImportMode.overwrite) {
    db.execute('DELETE FROM lyric_sources');
  }

  for (final item in decoded) {
    if (item is! Map) continue;
    final path = _readString(item['path']);
    if (path == null || path.isEmpty) continue;
    final source = _readString(item['source']);
    if (source == null || source.isEmpty) continue;
    final id = _readString(item['id']);

    if (mode == BackupImportMode.merge) {
      final existing = db.select('SELECT 1 FROM lyric_sources WHERE path = ?', [
        path,
      ]);
      if (existing.isNotEmpty) continue;
    }
    db.execute(
      'INSERT INTO lyric_sources(path, source, id) VALUES(?, ?, ?) '
      'ON CONFLICT(path) DO UPDATE SET source = excluded.source, id = excluded.id',
      [path, source, id],
    );
  }
}

String? _readString(Object? value) => value is String ? value : null;

int _readInt(Object? value) {
  final number = switch (value) {
    num() => value.toInt(),
    String() => int.tryParse(value.trim()),
    _ => null,
  };
  return number ?? 0;
}

/// 还原外部文件到数据目录 external/ 下，并改写 settings.json 里的路径。
Future<void> _restoreExternalFiles(
  Directory root,
  Archive archive,
  Map<String, String> externalFiles,
  BackupImportMode mode,
) async {
  final externalRoot = Directory(p.join(root.path, _externalDir));
  await externalRoot.create(recursive: true);

  final settingsFile = File(p.join(root.path, 'settings/settings.json'));
  Map? settingsMap;
  if (settingsFile.existsSync()) {
    try {
      final decoded = jsonDecode(settingsFile.readAsStringSync());
      if (decoded is Map) settingsMap = decoded;
    } catch (_) {}
  }

  final pathRewrites = <String, String>{};
  for (final entry in externalFiles.entries) {
    final key = entry.key;
    final name = p.basename(entry.value);
    if (name.isEmpty || name == '.' || name == p.separator) continue;
    final archiveEntry = archive.findFile('$_externalDir/$name');
    if (archiveEntry == null || !archiveEntry.isFile) continue;

    final target = File(p.join(externalRoot.path, name));
    if (mode == BackupImportMode.overwrite || !target.existsSync()) {
      await target.writeAsBytes(archiveEntry.content, flush: true);
    }
    final localValue = settingsMap?[key];
    final keepLocalPath =
        mode == BackupImportMode.merge &&
        localValue is String &&
        localValue.isNotEmpty &&
        File(localValue).existsSync();
    if (!keepLocalPath) pathRewrites[key] = target.path;
  }

  if (pathRewrites.isEmpty) return;

  if (!settingsFile.existsSync()) return;
  try {
    final settingsMap = jsonDecode(settingsFile.readAsStringSync());
    if (settingsMap is Map) {
      for (final entry in pathRewrites.entries) {
        settingsMap[entry.key] = entry.value;
      }
      await writeTextFileAtomically(settingsFile.path, jsonEncode(settingsMap));
    }
  } catch (error, trace) {
    logger.w('改写外部文件路径失败', error: error, stackTrace: trace);
  }
}

/// JSON 文件按顶层键合并：本机已有键保留，缺失键补入。
Future<void> _mergeJsonFile(File target, List<int> content) async {
  if (!target.existsSync()) {
    await target.writeAsBytes(content, flush: true);
    return;
  }
  try {
    final local = jsonDecode(target.readAsStringSync());
    final incoming = jsonDecode(utf8.decode(content));
    if (local is Map && incoming is Map) {
      final merged = _mergeJsonMaps(
        Map<String, dynamic>.from(incoming),
        Map<String, dynamic>.from(local),
      );
      await writeTextFileAtomically(target.path, jsonEncode(merged));
    }
  } catch (error, trace) {
    logger.w('合并备份文件失败，保留本机文件', error: error, stackTrace: trace);
  }
}

Map<String, dynamic> _mergeJsonMaps(
  Map<String, dynamic> incoming,
  Map<String, dynamic> local,
) {
  final merged = <String, dynamic>{};
  for (final entry in incoming.entries) {
    final localValue = local[entry.key];
    final incomingValue = entry.value;
    if (local.containsKey(entry.key)) {
      merged[entry.key] = localValue is Map && incomingValue is Map
          ? _mergeJsonMaps(
              Map<String, dynamic>.from(incomingValue),
              Map<String, dynamic>.from(localValue),
            )
          : localValue;
    } else {
      merged[entry.key] = incomingValue;
    }
  }
  for (final entry in local.entries) {
    merged.putIfAbsent(entry.key, () => entry.value);
  }
  return merged;
}

void _validateBackupArchive(Archive archive) {
  var expandedBytes = 0;
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    final int size = (entry.content.length as num).toInt();
    if (size > _maxBackupEntryBytes) {
      throw FormatException('备份条目过大：${entry.name}');
    }
    if (size > _maxBackupExpandedBytes - expandedBytes) {
      throw const FormatException('备份内容总量过大');
    }
    expandedBytes += size;
  }
}
