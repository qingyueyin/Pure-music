import 'dart:io';

import 'package:pure_music/app_settings.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

class AppDb {
  AppDb._();

  static final AppDb instance = AppDb._();

  Database? _db;

  Future<Database> db() async {
    final existing = _db;
    if (existing != null) return existing;

    final dir = await getDbDir();
    final dbFile = File(path.join(dir.path, "app.sqlite"));
    dbFile.parent.createSync(recursive: true);

    final opened = sqlite3.open(dbFile.path);
    _initSchema(opened);
    _db = opened;
    return opened;
  }

  void _initSchema(Database db) {
    db.execute("""
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;

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
  audio_json TEXT NOT NULL,
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
""");
  }

  void dispose() {
    _db?.dispose();
    _db = null;
  }
}
