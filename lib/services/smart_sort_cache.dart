import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/sqlite_runtime.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:sqlite3/sqlite3.dart';

/// 智能排序特征缓存。查找仍用内存，排序过程不会按首查库。
/// 落盘只写本次改过的曲目；旧的整份 JSON 在首次打开时导入后删除。
class SmartSortFeatureCache {
  SmartSortFeatureCache._({Future<Directory> Function()? appDataDirectory})
    : _appDataDirectory = appDataDirectory ?? getAppDataDir;

  static final SmartSortFeatureCache instance = SmartSortFeatureCache._();

  @visibleForTesting
  factory SmartSortFeatureCache.forTesting(Directory directory) =>
      SmartSortFeatureCache._(appDataDirectory: () async => directory);

  static const _dbFileName = 'smart_sort_features.sqlite';
  static const _legacyFileName = 'smart_sort_features.json';
  static const _featureVersion = 2;
  static const _sqliteCorrupt = 11;
  static const _sqliteNotADatabase = 26;

  final Future<Directory> Function() _appDataDirectory;

  String _keyForPath(String value) =>
      p.normalize(p.absolute(value)).replaceAll('\\', '/').toLowerCase();

  Map<String, _FeatureEntry>? _store;
  final Set<String> _dirtyKeys = <String>{};
  Future<Map<String, _FeatureEntry>>? _loadFuture;
  Future<void>? _flushFuture;
  bool _loaded = false;

  Future<Map<String, _FeatureEntry>> _loadStore() {
    if (_loaded) return Future.value(_store!);
    final pending = _loadFuture;
    if (pending != null) return pending;
    final future = _loadStoreNow();
    _loadFuture = future;
    future.then<void>(
      (_) {
        if (identical(_loadFuture, future)) _loadFuture = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_loadFuture, future)) _loadFuture = null;
      },
    );
    return future;
  }

  Future<Map<String, _FeatureEntry>> _loadStoreNow() async {
    final loaded = <String, _FeatureEntry>{};
    try {
      final dir = await _appDataDirectory();
      final db = await _openDatabase(p.join(dir.path, _dbFileName));
      try {
        await _importLegacyJson(db, dir);
        for (final row in db.select(
          'SELECT path, version, mtime, features FROM features',
        )) {
          loaded[row['path'] as String] = _FeatureEntry(
            version: row['version'] as int,
            mtime: row['mtime'] as int,
            features: row['features'] as String,
          );
        }
      } finally {
        db.dispose();
      }
    } catch (error, trace) {
      log.app.warn(
        'legacy',
        '[smart sort] feature cache load failed',
        error: error,
        stackTrace: trace,
      );
    }
    final memory = _store;
    if (memory != null) loaded.addAll(memory);
    _store = loaded;
    _loaded = true;
    return loaded;
  }

  /// 命中返回可直接拼接进 FFI 输入数组的特征 JSON 字符串。
  Future<String?> lookup(Audio audio) async {
    final store = await _loadStore();
    final entry = store[_keyForPath(audio.path)] ?? store[audio.path];
    if (entry == null || entry.version != _featureVersion) return null;
    if (entry.mtime != audio.modified) return null;
    return entry.features;
  }

  void put(Audio audio, String featuresJson) {
    final key = _keyForPath(audio.path);
    (_store ??= <String, _FeatureEntry>{})[key] = _FeatureEntry(
      version: _featureVersion,
      mtime: audio.modified,
      features: featuresJson,
    );
    _dirtyKeys.add(key);
  }

  Future<void> flush() {
    if (_dirtyKeys.isEmpty && _flushFuture == null) return Future.value();
    final pending = _flushFuture;
    if (pending != null) return pending;
    final future = _flushNow();
    _flushFuture = future;
    future.then<void>(
      (_) {
        if (identical(_flushFuture, future)) _flushFuture = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_flushFuture, future)) _flushFuture = null;
      },
    );
    return future;
  }

  Future<void> _flushNow() async {
    if (_dirtyKeys.isEmpty) return;
    await _loadStore();
    final dir = await _appDataDirectory();
    while (_dirtyKeys.isNotEmpty) {
      final keys = List<String>.of(_dirtyKeys);
      final batch = <String, _FeatureEntry>{};
      for (final key in keys) {
        final entry = _store?[key];
        if (entry != null) batch[key] = entry;
      }
      _dirtyKeys.removeAll(keys);
      if (batch.isEmpty) continue;
      try {
        await _writeEntries(p.join(dir.path, _dbFileName), batch);
      } catch (error, trace) {
        _dirtyKeys.addAll(keys);
        log.app.warn(
          'legacy',
          '[smart sort] feature cache save failed',
          error: error,
          stackTrace: trace,
        );
        return;
      }
    }
  }

  Future<void> _importLegacyJson(Database db, Directory dir) async {
    final file = File(p.join(dir.path, _legacyFileName));
    if (!file.existsSync()) return;
    Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } catch (error, trace) {
      log.app.warn(
        'legacy',
        '[smart sort] legacy feature cache ignored',
        error: error,
        stackTrace: trace,
      );
      await _deleteQuietly(file);
      return;
    }
    if (decoded is! Map) {
      await _deleteQuietly(file);
      return;
    }

    final rows = <List<Object>>[];
    for (final item in decoded.entries) {
      final key = item.key;
      final value = item.value;
      if (key is! String || value is! Map) continue;
      final version = value['version'];
      final features = value['features'];
      final mtime = switch (value['mtime']) {
        int number => number,
        num number => number.toInt(),
        String text => int.tryParse(text),
        _ => null,
      };
      if (version is! int || mtime == null || features is! String) continue;
      rows.add([key, version, mtime, features]);
    }
    if (rows.isNotEmpty) {
      _replaceRows(db, rows);
    }
    await _deleteQuietly(file);
  }

  Future<void> _writeEntries(
    String path,
    Map<String, _FeatureEntry> entries,
  ) async {
    final db = await _openDatabase(path);
    try {
      _replaceRows(db, [
        for (final item in entries.entries)
          [item.key, item.value.version, item.value.mtime, item.value.features],
      ]);
    } finally {
      db.dispose();
    }
  }

  void _replaceRows(Database db, List<List<Object>> rows) {
    final statement = db.prepare(
      'INSERT OR REPLACE INTO features(path, version, mtime, features) '
      'VALUES(?, ?, ?, ?)',
    );
    try {
      db.execute('BEGIN IMMEDIATE');
      try {
        for (final row in rows) {
          statement.execute(row);
        }
        db.execute('COMMIT');
      } catch (_) {
        try {
          db.execute('ROLLBACK');
        } catch (_) {}
        rethrow;
      }
    } finally {
      statement.dispose();
    }
  }

  Future<Database> _openDatabase(String path) async {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      throw FileSystemException('智能排序缓存路径被目录占用', path);
    }
    try {
      return _openFresh(path);
    } on SqliteException catch (error) {
      if (type != FileSystemEntityType.file || !_isUnreadableDatabase(error)) {
        rethrow;
      }
      await File(path).delete();
      return _openFresh(path);
    }
  }

  Database _openFresh(String path) {
    ensureSqliteRuntime();
    final db = sqlite3.open(path);
    try {
      db.execute('PRAGMA busy_timeout = 3000');
      db.execute('''
        CREATE TABLE IF NOT EXISTS features (
          path TEXT PRIMARY KEY,
          version INTEGER NOT NULL,
          mtime INTEGER NOT NULL,
          features TEXT NOT NULL
        )
      ''');
      return db;
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  bool _isUnreadableDatabase(SqliteException error) {
    final code = error.resultCode;
    return code == _sqliteCorrupt || code == _sqliteNotADatabase;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

class _FeatureEntry {
  const _FeatureEntry({
    required this.version,
    required this.mtime,
    required this.features,
  });

  final int version;
  final int mtime;
  final String features;
}
