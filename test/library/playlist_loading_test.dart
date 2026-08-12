import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('loads playlists and all ordered items with two bulk queries', () {
    final database = sqlite3.openInMemory();
    try {
      database.execute('''
        CREATE TABLE playlists (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          cover_source TEXT
        );
        CREATE TABLE playlist_items (
          playlist_id INTEGER NOT NULL,
          path TEXT NOT NULL,
          sort_order INTEGER NOT NULL,
          added_at TEXT
        );
        INSERT INTO playlists(id, name, cover_source)
        VALUES (2, 'Beta', NULL), (1, 'Alpha', 'audio:cover');
        INSERT INTO playlist_items(playlist_id, path, sort_order, added_at)
        VALUES
          (1, 'late.mp3', 1, '2026-01-02T00:00:00.000Z'),
          (1, 'early.mp3', 0, '2026-01-01T00:00:00.000Z'),
          (2, 'beta.mp3', 0, NULL);
      ''');

      final result = readPlaylistsFromDatabase(database);

      expect(result.map((playlist) => playlist.name), ['Alpha', 'Beta']);
      expect(result.first.paths, ['early.mp3', 'late.mp3']);
      expect(result.first.coverSource, 'audio:cover');
      expect(
        result.first.addedAt('early.mp3'),
        DateTime.parse('2026-01-01T00:00:00.000Z'),
      );
      expect(result.last.paths, ['beta.mp3']);
      expect(
        () => result.add(Playlist('Gamma', const [])),
        returnsNormally,
      );
    } finally {
      database.dispose();
    }
  });

  test('creates one persisted playlist and rejects a duplicate name', () {
    final database = sqlite3.openInMemory();
    try {
      database.execute('''
        CREATE TABLE playlists (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL UNIQUE,
          cover_source TEXT
        );
      ''');

      final created = createPlaylistInDatabase(database, '  Favorites  ');

      expect(created.id, isNotNull);
      expect(created.name, 'Favorites');
      expect(
        database.select('SELECT name FROM playlists').single['name'],
        'Favorites',
      );
      expect(
        () => createPlaylistInDatabase(database, 'Favorites'),
        throwsA(isA<PlaylistAlreadyExistsException>()),
      );
    } finally {
      database.dispose();
    }
  });
}
