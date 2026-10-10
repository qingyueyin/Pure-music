import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' as frb;
import 'package:path/path.dart' as p;
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as library_db;
import 'package:pure_music/services/backup_file_transaction.dart';
import 'package:pure_music/services/lastfm/lastfm_models.dart';
import 'package:sqlite3/sqlite3.dart';

/// 备份类别。不含曲库索引本身，只含用户数据与偏好。
enum BackupCategory {
  settings('设置', '界面、播放、歌词等偏好'),
  playlists('歌单与歌词来源', '歌单、歌词匹配来源'),
  playCounts('播放统计', '每首曲目的播放次数'),
  playHistory('播放历史', '带时间戳的播放流水'),
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
const String _playHistoryEntryName = 'play_history.json';
const String _lastfmEntryName = 'lastfm.json';
const int _backupFormatVersion = 2;
const int _maxBackupArchiveBytes = 128 * 1024 * 1024;
const int _maxBackupEntryBytes = 64 * 1024 * 1024;
const int _maxBackupExpandedBytes = 256 * 1024 * 1024;

/// 把选中的类别打包成 zip，返回导出文件路径；用户取消时返回 null。
Future<String?> exportBackup({
  required String targetPath,
  required Set<BackupCategory> categories,
  Directory? dataRoot,
}) async {
  final root = dataRoot ?? await getAppDataDir();
  final archive = Archive();
  final externalFiles = <String, String>{};
  if (categories.contains(BackupCategory.settings)) {
    _exportSettingsCategory(root, archive, externalFiles);
  }
  if (categories.contains(BackupCategory.playlists)) {
    await _exportPlaylistsCategory(archive);
  }
  if (categories.contains(BackupCategory.playCounts)) {
    await _exportPlayCountsCategory(root, archive);
  }
  if (categories.contains(BackupCategory.playHistory)) {
    await _exportPlayHistoryCategory(root, archive);
  }
  if (categories.contains(BackupCategory.lastfm)) {
    await _exportLastfmCategory(archive);
  }
  _exportExternalFiles(archive, externalFiles);
  _exportManifest(archive, categories, externalFiles);
  await _writeBackupArchive(targetPath, archive);
  return targetPath;
}

void _exportSettingsCategory(
  Directory root,
  Archive archive,
  Map<String, String> externalFiles,
) {
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

Future<void> _exportPlaylistsCategory(Archive archive) async {
  final db = await AppDb.instance.db();
  _addJsonEntry(archive, _playlistsEntryName, _exportPlaylists(db));
  _addJsonEntry(archive, _lyricSourcesEntryName, _exportLyricSources(db));
}

Future<void> _exportPlayCountsCategory(Directory root, Archive archive) async {
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

Future<void> _exportPlayHistoryCategory(Directory root, Archive archive) async {
  final entries = await library_db.exportPlayHistory(indexPath: root.path);
  final list = entries
      .map(
        (e) => {
          'path': e.path,
          'playedAt': e.playedAt.map((t) => t.toInt()).toList(),
        },
      )
      .toList();
  _addJsonEntry(archive, _playHistoryEntryName, list);
}

Future<void> _exportLastfmCategory(Archive archive) async {
  final db = await AppDb.instance.db();
  final credentials = _readMetaMap(db, 'lastfm_credentials');
  if (credentials != null) {
    _addJsonEntry(archive, _lastfmEntryName, credentials);
  }
}

void _exportExternalFiles(Archive archive, Map<String, String> externalFiles) {
  for (final entry in externalFiles.entries) {
    final source = File(entry.value);
    if (!source.existsSync()) continue;
    final bytes = _readBackupFile(source);
    final name = p.basename(source.path);
    archive.addFile(ArchiveFile('$_externalDir/$name', bytes.length, bytes));
  }
}

void _exportManifest(
  Archive archive,
  Set<BackupCategory> categories,
  Map<String, String> externalFiles,
) {
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
}

Future<void> _writeBackupArchive(String targetPath, Archive archive) async {
  final encoder = ZipEncoder();
  final data = encoder.encode(archive);
  if (data == null) {
    throw StateError('备份打包失败');
  }
  if (data.length > _maxBackupArchiveBytes) {
    throw StateError('备份文件过大');
  }
  await File(targetPath).writeAsBytes(data, flush: true);
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

@visibleForTesting
bool shouldImportLastFmCredentials({
  required BackupImportMode mode,
  required LastFmCredentials local,
}) {
  return mode == BackupImportMode.overwrite || !local.isAuthorized;
}

/// 从 zip 导入备份。返回实际导入的类别。
Future<Set<BackupCategory>> importBackup({
  required String sourcePath,
  required BackupImportMode mode,
  Directory? dataRoot,
}) async {
  final sourceFile = File(sourcePath);
  if (sourceFile.lengthSync() > _maxBackupArchiveBytes) {
    throw const FormatException('备份文件过大');
  }
  final bytes = sourceFile.readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);
  _validateBackupArchive(archive);

  final manifest = _readBackupManifest(archive);
  final categories = manifest.categories.isEmpty
      ? _inferBackupCategories(archive)
      : manifest.categories;
  final root = dataRoot ?? await getAppDataDir();
  final imported = <BackupCategory>{};

  if (categories.contains(BackupCategory.settings)) {
    await _importSettingsCategory(
      root: root,
      archive: archive,
      mode: mode,
      externalFiles: manifest.externalFiles,
    );
    imported.add(BackupCategory.settings);
  }
  if (categories.contains(BackupCategory.playlists)) {
    final db = await AppDb.instance.db();
    _importPlaylistsAndLyricSources(db, archive, mode);
    imported.add(BackupCategory.playlists);
  }
  if (categories.contains(BackupCategory.playCounts)) {
    await _importPlayCountsCategory(root, archive, mode);
    imported.add(BackupCategory.playCounts);
  }
  if (categories.contains(BackupCategory.playHistory)) {
    await _importPlayHistoryCategory(root, archive, mode);
    imported.add(BackupCategory.playHistory);
  }
  if (categories.contains(BackupCategory.lastfm)) {
    await _importLastFmCategory(archive, mode);
    imported.add(BackupCategory.lastfm);
  }
  return imported;
}

({Set<BackupCategory> categories, Map<String, String> externalFiles})
_readBackupManifest(Archive archive) {
  final categories = <BackupCategory>{};
  final externalFiles = <String, String>{};
  final manifestFile = archive.findFile(_manifestName);
  if (manifestFile == null) {
    return (categories: categories, externalFiles: externalFiles);
  }
  try {
    final manifest = jsonDecode(utf8.decode(manifestFile.content));
    _addManifestCategories(manifest, categories);
    _addManifestExternalFiles(manifest, externalFiles);
  } catch (_) {}
  return (categories: categories, externalFiles: externalFiles);
}

void _addManifestCategories(Object? manifest, Set<BackupCategory> categories) {
  if (manifest is! Map) return;
  final names = manifest['categories'];
  if (names is! List) return;
  for (final name in names) {
    final category = BackupCategory.values
        .where((c) => c.name == name)
        .firstOrNull;
    if (category != null) categories.add(category);
  }
}

void _addManifestExternalFiles(
  Object? manifest,
  Map<String, String> externalFiles,
) {
  if (manifest is! Map) return;
  final ext = manifest['externalFiles'];
  if (ext is! Map) return;
  for (final entry in ext.entries) {
    if (entry.key is! String || entry.value is! String) continue;
    final name = p.basename(entry.value as String);
    if (name.isEmpty || name == '.' || name == p.separator) continue;
    externalFiles[entry.key as String] = name;
  }
}

Set<BackupCategory> _inferBackupCategories(Archive archive) {
  final categories = <BackupCategory>{};
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
  if (archive.findFile(_playHistoryEntryName) != null) {
    categories.add(BackupCategory.playHistory);
  }
  if (archive.findFile(_lastfmEntryName) != null) {
    categories.add(BackupCategory.lastfm);
  }
  return categories;
}

Future<void> _importSettingsCategory({
  required Directory root,
  required Archive archive,
  required BackupImportMode mode,
  required Map<String, String> externalFiles,
}) async {
  final transaction = BackupFileTransaction(root);
  try {
    await _importSettings(root, archive, mode, transaction);
    if (externalFiles.isNotEmpty) {
      await _restoreExternalFiles(
        root,
        archive,
        externalFiles,
        mode,
        transaction,
      );
    }
    await transaction.commit();
  } catch (_) {
    try {
      await transaction.rollback();
    } catch (rollbackError, rollbackTrace) {
      log.settings.error(
        'legacy',
        '备份设置回滚失败',
        error: rollbackError,
        stackTrace: rollbackTrace,
      );
    }
    rethrow;
  }
}

Future<void> _importPlayCountsCategory(
  Directory root,
  Archive archive,
  BackupImportMode mode,
) async {
  final entry = archive.findFile(_playCountsEntryName);
  if (entry == null || !entry.isFile) return;
  final list = jsonDecode(utf8.decode(entry.content));
  if (list is! List) return;
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

Future<void> _importPlayHistoryCategory(
  Directory root,
  Archive archive,
  BackupImportMode mode,
) async {
  final entry = archive.findFile(_playHistoryEntryName);
  if (entry == null || !entry.isFile) return;
  final list = jsonDecode(utf8.decode(entry.content));
  if (list is! List) return;
  final historyEntries = <library_db.PlayHistoryEntry>[];
  for (final item in list) {
    if (item is! Map) continue;
    final path = _readString(item['path']);
    if (path == null || path.isEmpty) continue;
    final rawTimes = item['playedAt'];
    if (rawTimes is! List) continue;
    final times = <int>[];
    for (final raw in rawTimes) {
      final time = _readInt(raw);
      if (time > 0) times.add(time);
    }
    if (times.isEmpty) continue;
    historyEntries.add(
      library_db.PlayHistoryEntry(
        path: path,
        playedAt: frb.Int64List.fromList(times),
      ),
    );
  }
  if (historyEntries.isEmpty) return;
  await library_db.importPlayHistory(
    indexPath: root.path,
    entries: historyEntries,
    overwrite: mode == BackupImportMode.overwrite,
  );
}

Future<void> _importLastFmCategory(
  Archive archive,
  BackupImportMode mode,
) async {
  final entry = archive.findFile(_lastfmEntryName);
  if (entry == null || !entry.isFile) return;
  final decoded = jsonDecode(utf8.decode(entry.content));
  if (decoded is! Map) return;
  final db = await AppDb.instance.db();
  final local = LastFmCredentials.fromMap(
    _readMetaMap(db, 'lastfm_credentials'),
  );
  if (!shouldImportLastFmCredentials(mode: mode, local: local)) return;
  db.execute(
    'INSERT INTO meta(key, value) VALUES(?, ?) '
    'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    ['lastfm_credentials', jsonEncode(decoded)],
  );
}

Future<void> _importSettings(
  Directory root,
  Archive archive,
  BackupImportMode mode,
  BackupFileTransaction transaction,
) async {
  for (final rel in _settingsFiles) {
    final entry = archive.findFile(rel);
    if (entry == null || !entry.isFile) continue;
    final target = File(p.join(root.path, rel));
    await target.parent.create(recursive: true);
    if (mode == BackupImportMode.overwrite) {
      await transaction.writeBytes(target, entry.content);
    } else {
      await _mergeJsonFile(target, entry.content, transaction);
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

@visibleForTesting
void importPlaylistsAndLyricSourcesForTesting(
  Database db,
  Archive archive,
  BackupImportMode mode,
) {
  _importPlaylistsAndLyricSources(db, archive, mode);
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
    _importOnePlaylistRow(db, item, mode);
  }
}

void _importOnePlaylistRow(Database db, Map item, BackupImportMode mode) {
  final name = _readString(item['name']);
  if (name == null || name.isEmpty) return;
  final coverSource = _readString(item['coverSource']);
  final items = item['items'] is List ? item['items'] as List : const [];
  final existing = db.select('SELECT id FROM playlists WHERE name = ?', [name]);
  int playlistId;
  if (existing.isNotEmpty) {
    if (mode == BackupImportMode.merge) return;
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
  BackupFileTransaction transaction,
) async {
  final externalRoot = Directory(p.join(root.path, _externalDir));
  await externalRoot.create(recursive: true);
  final settingsFile = File(p.join(root.path, 'settings/settings.json'));
  final settingsMap = _readSettingsMap(settingsFile);
  final pathRewrites = await _externalPathRewrites(
    archive,
    externalFiles,
    externalRoot,
    settingsMap,
    mode,
    transaction,
  );
  if (pathRewrites.isEmpty) return;
  await _rewriteSettingsPaths(settingsFile, pathRewrites, transaction);
}

Map? _readSettingsMap(File settingsFile) {
  if (!settingsFile.existsSync()) return null;
  try {
    final decoded = jsonDecode(settingsFile.readAsStringSync());
    return decoded is Map ? decoded : null;
  } catch (_) {
    return null;
  }
}

Future<Map<String, String>> _externalPathRewrites(
  Archive archive,
  Map<String, String> externalFiles,
  Directory externalRoot,
  Map? settingsMap,
  BackupImportMode mode,
  BackupFileTransaction transaction,
) async {
  final pathRewrites = <String, String>{};
  for (final entry in externalFiles.entries) {
    final name = p.basename(entry.value);
    if (name.isEmpty || name == '.' || name == p.separator) continue;
    final archiveEntry = archive.findFile('$_externalDir/$name');
    if (archiveEntry == null || !archiveEntry.isFile) continue;
    final target = File(p.join(externalRoot.path, name));
    if (mode == BackupImportMode.overwrite || !target.existsSync()) {
      await transaction.writeBytes(target, archiveEntry.content);
    }
    final localValue = settingsMap?[entry.key];
    final keepLocalPath =
        mode == BackupImportMode.merge &&
        localValue is String &&
        localValue.isNotEmpty &&
        File(localValue).existsSync();
    if (!keepLocalPath) pathRewrites[entry.key] = target.path;
  }
  return pathRewrites;
}

Future<void> _rewriteSettingsPaths(
  File settingsFile,
  Map<String, String> pathRewrites,
  BackupFileTransaction transaction,
) async {
  if (!settingsFile.existsSync()) return;
  final decoded = jsonDecode(settingsFile.readAsStringSync());
  if (decoded is! Map) return;
  for (final entry in pathRewrites.entries) {
    decoded[entry.key] = entry.value;
  }
  await transaction.writeText(settingsFile, jsonEncode(decoded));
}

Future<void> _mergeJsonFile(
  File target,
  List<int> content,
  BackupFileTransaction transaction,
) async {
  if (!target.existsSync()) {
    await transaction.writeBytes(target, content);
    return;
  }
  final local = jsonDecode(target.readAsStringSync());
  final incoming = jsonDecode(utf8.decode(content));
  if (local is! Map || incoming is! Map) {
    throw const FormatException('设置文件必须是 JSON 对象');
  }
  final merged = _mergeJsonMaps(
    Map<String, dynamic>.from(incoming),
    Map<String, dynamic>.from(local),
  );
  await transaction.writeText(target, jsonEncode(merged));
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
