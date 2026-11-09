import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/sqlite_runtime.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

class AppDb {
  AppDb._();

  static final AppDb instance = AppDb._();

  Database? _db;
  Future<Database>? _opening;

  Future<Database> db() {
    final existing = _db;
    if (existing != null) return Future<Database>.value(existing);
    final opening = _opening;
    if (opening != null) return opening;

    final future = _open();
    _opening = future;
    return future;
  }

  Future<Database> _open() async {
    Database? opened;
    try {
      final dir = await getDbDir();
      final dbFile = File(path.join(dir.path, 'app.sqlite'));
      dbFile.parent.createSync(recursive: true);

      ensureSqliteRuntime();
      opened = openRecovering(dbFile);
      _db = opened;
      return opened;
    } catch (_) {
      opened?.dispose();
      rethrow;
    } finally {
      _opening = null;
    }
  }

  /// 打开数据库；文件损坏时把旧文件隔离后重建，避免整个应用起不来
  @visibleForTesting
  static Database openRecovering(File dbFile) {
    ensureSqliteRuntime();
    try {
      final db = sqlite3.open(dbFile.path);
      try {
        _initSchema(db);
      } catch (_) {
        db.dispose();
        rethrow;
      }
      return db;
    } on SqliteException catch (error) {
      if (!_isCorruption(error)) rethrow;
      final quarantined = _quarantine(dbFile);
      if (quarantined == null) rethrow;
      log.app.warn(
        'db_corrupt',
        'database quarantined to $quarantined',
        fields: {'code': error.resultCode},
      );
      final db = sqlite3.open(dbFile.path);
      try {
        _initSchema(db);
      } catch (_) {
        db.dispose();
        rethrow;
      }
      return db;
    }
  }

  static bool _isCorruption(SqliteException error) {
    // SQLITE_CORRUPT=11、SQLITE_NOTADB=26，扩展码取低 8 位
    final code = error.resultCode & 0xff;
    return code == 11 || code == 26;
  }

  /// 把损坏的数据库连同 WAL/SHM 一起改名保留，返回主文件的新路径
  static String? _quarantine(File dbFile) {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    String? mainPath;
    for (final suffix in const ['', '-wal', '-shm']) {
      final file = File('${dbFile.path}$suffix');
      if (!file.existsSync()) continue;
      final target = '${dbFile.path}.corrupt-$stamp$suffix';
      try {
        file.renameSync(target);
        if (suffix.isEmpty) mainPath = target;
      } catch (_) {
        if (suffix.isEmpty) return null;
      }
    }
    return mainPath;
  }

  static void _initSchema(Database db) {
    db.execute('''
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA busy_timeout = 3000;
PRAGMA cache_size = -16000;
PRAGMA journal_size_limit = 67108864;

CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS playlists (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS playlist_items (
  playlist_id INTEGER NOT NULL,
  path TEXT NOT NULL,
  PRIMARY KEY (playlist_id, path)
);

CREATE INDEX IF NOT EXISTS idx_playlist_items_playlist_id ON playlist_items(playlist_id);

CREATE TABLE IF NOT EXISTS lyric_sources (
  path TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  id TEXT
);

CREATE TABLE IF NOT EXISTS album_colors (
  key TEXT PRIMARY KEY,
  sig TEXT NOT NULL,
  p INTEGER NOT NULL,
  on_p INTEGER NOT NULL
);
''');

    _migrate(db);
  }

  static void _migrate(Database db) {
    db.execute('BEGIN');
    try {
      final version =
          db.select('PRAGMA user_version').first['user_version'] as int;
      if (version < 1) {
        db.execute(
            'ALTER TABLE playlist_items ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0');
        db.execute('PRAGMA user_version = 1');
      }
      if (version < 2) {
        try {
          db.execute('ALTER TABLE playlist_items DROP COLUMN audio_json');
        } catch (_) {}
        db.execute('PRAGMA user_version = 2');
      }
      if (version < 3) {
        db.execute('ALTER TABLE playlists ADD COLUMN cover_source TEXT');
        db.execute('PRAGMA user_version = 3');
      }
      if (version < 4) {
        db.execute('ALTER TABLE playlist_items ADD COLUMN added_at TEXT');
        db.execute('PRAGMA user_version = 4');
      }
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void dispose() {
    _db?.dispose();
    _db = null;
  }

  /// 把 WAL 日志合并回主文件。库结构迁移完成后调用一次即可，
  /// 期间正常读写仍可用（PASSIVE 模式不阻塞）。
  void checkpointWal() {
    final db = _db;
    if (db == null) return;
    db.execute('PRAGMA wal_checkpoint(PASSIVE)');
  }
}
