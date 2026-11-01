import 'package:pure_music/core/database.dart';
import 'package:pure_music/remote/remote_source.dart';
import 'package:sqlite3/sqlite3.dart';

class RemoteStore {
  const RemoteStore();

  /// 分批让出事件循环的粒度（不提交事务）：大库写入时界面还能呼吸。
  static const _chunkSize = 400;

  static bool _schemaReady = false;

  /// 写操作串行化。replaceTracks 的事务会跨越多个 await，共享连接上
  /// 如果混进别的写入，它会并入事务或把回滚搅乱；并发替换还会互相
  /// BEGIN 导致双方都不完整。所有写都排在这条队上执行。
  static Future<void> _writeLock = Future<void>.value();

  static Future<T> _write<T>(Future<T> Function() action) {
    final result = _writeLock.then((_) => action());
    _writeLock = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _ensureSchema() async {
    if (_schemaReady) return;
    final db = await AppDb.instance.db();
    db.execute('''
CREATE TABLE IF NOT EXISTS remote_sources (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  name TEXT NOT NULL,
  base_url TEXT NOT NULL,
  username TEXT NOT NULL,
  secret TEXT NOT NULL,
  root TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_sync_at INTEGER NOT NULL,
  sort_order INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS remote_tracks (
  path TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  track_id TEXT NOT NULL,
  title TEXT NOT NULL,
  artist TEXT NOT NULL,
  album TEXT NOT NULL,
  album_artist TEXT,
  track INTEGER NOT NULL,
  disc INTEGER,
  duration INTEGER NOT NULL,
  bitrate INTEGER,
  sample_rate INTEGER,
  modified INTEGER NOT NULL,
  created INTEGER NOT NULL,
  by TEXT,
  cover_id TEXT,
  UNIQUE(source_id, track_id)
);

CREATE INDEX IF NOT EXISTS idx_remote_tracks_source
  ON remote_tracks(source_id);

CREATE TABLE IF NOT EXISTS remote_play_history (
  path TEXT NOT NULL,
  played_at INTEGER NOT NULL,
  PRIMARY KEY(path, played_at)
);

CREATE INDEX IF NOT EXISTS idx_remote_play_history_path
  ON remote_play_history(path);
''');
    _schemaReady = true;
  }

  Future<List<RemoteSource>> readSources() async {
    await _ensureSchema();
    final db = await AppDb.instance.db();
    final rows = db.select(
      'SELECT * FROM remote_sources ORDER BY sort_order ASC, created_at ASC',
    );
    return rows.map(_sourceFromRow).toList(growable: false);
  }

  Future<void> upsertSource(RemoteSource source) {
    return _write(() async {
      await _ensureSchema();
      final db = await AppDb.instance.db();
      db.execute(
        '''
INSERT INTO remote_sources
  (id, kind, name, base_url, username, secret, root, created_at, last_sync_at, sort_order)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  kind = excluded.kind,
  name = excluded.name,
  base_url = excluded.base_url,
  username = excluded.username,
  secret = excluded.secret,
  root = excluded.root,
  last_sync_at = excluded.last_sync_at,
  sort_order = excluded.sort_order
''',
        [
          source.id,
          source.kind.name,
          source.name,
          source.baseUrl,
          source.username,
          source.secret,
          source.root,
          source.createdAt,
          source.lastSyncAt,
          source.sortOrder,
        ],
      );
    });
  }

  Future<void> deleteSource(String id) {
    return _write(() async {
      await _ensureSchema();
      final db = await AppDb.instance.db();
      db.execute('DELETE FROM remote_tracks WHERE source_id = ?', [id]);
      db.execute('DELETE FROM remote_sources WHERE id = ?', [id]);
      db.execute('DELETE FROM remote_play_history WHERE path LIKE ?', [
        '$remotePathPrefix$id/%',
      ]);
    });
  }

  Future<void> recordPlay(String path, int playedAt) {
    return _write(() async {
      await _ensureSchema();
      final db = await AppDb.instance.db();
      db.execute(
        'INSERT OR IGNORE INTO remote_play_history (path, played_at) '
        'VALUES (?, ?)',
        [path, playedAt],
      );
    });
  }

  Future<void> updateTrackDuration(String path, int duration) {
    return _write(() async {
      await _ensureSchema();
      final db = await AppDb.instance.db();
      db.execute(
        'UPDATE remote_tracks SET duration = ? WHERE path = ? AND duration <= 0',
        [duration, path],
      );
    });
  }

  Future<Map<String, int>> readPlayCounts() async {
    await _ensureSchema();
    final db = await AppDb.instance.db();
    final rows = db.select(
      'SELECT path, COUNT(*) AS count FROM remote_play_history '
      'GROUP BY path',
    );
    return {
      for (final row in rows) row['path'] as String: row['count'] as int,
    };
  }

  Future<Map<String, List<int>>> readPlayHistory() async {
    await _ensureSchema();
    final db = await AppDb.instance.db();
    final rows = db.select(
      'SELECT path, played_at FROM remote_play_history ORDER BY played_at ASC',
    );
    final result = <String, List<int>>{};
    for (final row in rows) {
      result
          .putIfAbsent(row['path'] as String, () => <int>[])
          .add(row['played_at'] as int);
    }
    return result;
  }

  Future<List<RemoteTrack>> readTracks() async {
    await _ensureSchema();
    final db = await AppDb.instance.db();
    final rows = db.select(
      'SELECT * FROM remote_tracks ORDER BY source_id ASC, album ASC, disc ASC, track ASC, title ASC',
    );
    return rows.map(_trackFromRow).toList(growable: false);
  }

  Future<List<RemoteTrack>> readTracksForSource(String sourceId) async {
    await _ensureSchema();
    final db = await AppDb.instance.db();
    final rows = db.select(
      'SELECT * FROM remote_tracks WHERE source_id = ? '
      'ORDER BY album ASC, disc ASC, track ASC, title ASC',
      [sourceId],
    );
    return rows.map(_trackFromRow).toList(growable: false);
  }

  /// 整体替换一个源的曲目。整个替换在**单个事务**里完成：中途任何错误
  /// （写入、进度回调抛取消、进程被杀）都由事务回滚兜底，旧曲目集合
  /// 原样保留，不会留下缺歌的半成品库。
  ///
  /// 每 [_chunkSize] 行让出一次事件循环，界面不会假死；让出期间事务保持
  /// 打开，由 [_write] 的写锁挡住其他写入，避免它们并入本事务。
  Future<void> replaceTracks(
    String sourceId,
    List<RemoteTrack> tracks,
    String Function(RemoteTrack track) pathOf, {
    void Function(int done, int total)? onProgress,
  }) {
    return _write(() async {
      await _ensureSchema();
      final db = await AppDb.instance.db();
      final statement = db.prepare('''
INSERT OR REPLACE INTO remote_tracks
  (path, source_id, track_id, title, artist, album, album_artist, track, disc,
   duration, bitrate, sample_rate, modified, created, by, cover_id)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
''');
      final total = tracks.length;
      var done = 0;
      try {
        db.execute('BEGIN');
        try {
          db.execute('DELETE FROM remote_tracks WHERE source_id = ?', [
            sourceId,
          ]);
          for (final track in tracks) {
            statement.execute([
              pathOf(track),
              track.sourceId,
              track.trackId,
              track.title,
              track.artist,
              track.album,
              track.albumArtist,
              track.track,
              track.disc,
              track.duration,
              track.bitrate,
              track.sampleRate,
              track.modified,
              track.created,
              track.by,
              track.coverId,
            ]);
            done++;
            if (done % _chunkSize == 0) {
              onProgress?.call(done, total);
              // 让出事件循环，避免大库同步时界面完全卡死。
              await Future<void>.delayed(Duration.zero);
            }
          }
          db.execute('COMMIT');
        } catch (_) {
          try {
            db.execute('ROLLBACK');
          } catch (_) {}
          rethrow;
        }
        onProgress?.call(total, total);
      } finally {
        statement.dispose();
      }
    });
  }

  RemoteSource _sourceFromRow(Row row) {
    return RemoteSource(
      id: row['id'] as String,
      kind: RemoteSourceKind.parse(row['kind'] as String),
      name: row['name'] as String,
      baseUrl: row['base_url'] as String,
      username: row['username'] as String,
      secret: row['secret'] as String,
      root: row['root'] as String,
      createdAt: row['created_at'] as int,
      lastSyncAt: row['last_sync_at'] as int,
      sortOrder: row['sort_order'] as int,
    );
  }

  RemoteTrack _trackFromRow(Row row) {
    return RemoteTrack(
      sourceId: row['source_id'] as String,
      trackId: row['track_id'] as String,
      title: row['title'] as String,
      artist: row['artist'] as String,
      album: row['album'] as String,
      albumArtist: row['album_artist'] as String?,
      track: row['track'] as int,
      disc: row['disc'] as int?,
      duration: row['duration'] as int,
      bitrate: row['bitrate'] as int?,
      sampleRate: row['sample_rate'] as int?,
      modified: row['modified'] as int,
      created: row['created'] as int,
      by: row['by'] as String?,
      coverId: row['cover_id'] as String?,
    );
  }
}
