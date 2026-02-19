import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart';

class AlbumColor {
  final Color primary;
  final Color onPrimary;
  const AlbumColor({required this.primary, required this.onPrimary});
}

class AlbumColorCache {
  static final instance = AlbumColorCache._();
  AlbumColorCache._();

  static const _cacheFileName = "album_colors.json";
  static const _cacheVersion = 1;

  bool _initialized = false;
  final Map<String, Map<String, Object?>> _entries = {};
  final Map<String, Future<AlbumColor?>> _inFlight = {};
  Timer? _flushTimer;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final dir = await getCacheDir();
      final jsonFile = File("${dir.path}\\$_cacheFileName");

      try {
        final db = await AppDb.instance.db();
        _loadFromDb(db);
        if (_entries.isEmpty && jsonFile.existsSync()) {
          _loadFromJsonFile(jsonFile);
          _persistToDb(db);
        }
        return;
      } catch (_) {}

      if (!jsonFile.existsSync()) return;
      _loadFromJsonFile(jsonFile);
    } catch (_) {}
  }

  Future<AlbumColor?> getAlbumColor(Album album, {bool forceRecompute = false}) async {
    await init();
    final keySig = _albumKeyAndSignature(album);
    final key = keySig.$1;
    final signature = keySig.$2;
    if (!forceRecompute) {
      final cached = _entries[key];
      if (cached != null && cached["sig"] == signature) {
        final p = cached["p"];
        final on = cached["on"];
        if (p is int && on is int) {
          return AlbumColor(primary: Color(p), onPrimary: Color(on));
        }
      }
    }

    final existing = _inFlight[key];
    if (existing != null) return existing;

    final fut = _computeAndStore(album, key: key, signature: signature);
    _inFlight[key] = fut;
    fut.whenComplete(() {
      _inFlight.remove(key);
    });
    return fut;
  }

  Future<void> prewarmAlbums(
    Iterable<Album> albums, {
    int concurrency = 2,
    void Function(int done, int total)? onProgress,
  }) async {
    await init();
    final list = albums.toList(growable: false);
    final total = list.length;
    int done = 0;

    final sem = _AsyncSemaphore(concurrency);
    final futures = <Future<void>>[];
    for (final album in list) {
      futures.add(sem.run(() async {
        await getAlbumColor(album);
        done += 1;
        onProgress?.call(done, total);
        if (done % 12 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }));
    }
    await Future.wait(futures);
  }

  Future<void> recomputeAllAlbums(
    Iterable<Album> albums, {
    int concurrency = 2,
    void Function(int done, int total)? onProgress,
  }) async {
    await init();
    final list = albums.toList(growable: false);
    final total = list.length;
    int done = 0;

    final sem = _AsyncSemaphore(concurrency);
    final futures = <Future<void>>[];
    for (final album in list) {
      futures.add(sem.run(() async {
        await getAlbumColor(album, forceRecompute: true);
        done += 1;
        onProgress?.call(done, total);
        if (done % 8 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }));
    }
    await Future.wait(futures);
  }

  Future<AlbumColor?> _computeAndStore(
    Album album, {
    required String key,
    required String signature,
  }) async {
    try {
      final bytes = await _getAlbumCoverBytes(album);
      if (bytes == null) return null;
      final rgb = await _computeAverageRgb(bytes);
      if (rgb == null) return null;

      final primary = Color(0xff000000 | rgb);
      final onPrimary = primary.computeLuminance() < 0.42
          ? const Color(0xffffffff)
          : const Color(0xff000000);

      _entries[key] = {
        "sig": signature,
        "p": primary.value,
        "on": onPrimary.value,
      };
      _scheduleFlush();
      return AlbumColor(primary: primary, onPrimary: onPrimary);
    } catch (_) {
      return null;
    }
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 800), () {
      flush().ignore();
    });
  }

  Future<void> flush() async {
    try {
      try {
        final db = await AppDb.instance.db();
        _persistToDb(db);
        return;
      } catch (_) {}

      final dir = await getCacheDir();
      final file = File("${dir.path}\\$_cacheFileName");
      final jsonStr = json.encode({"version": _cacheVersion, "data": _entries});
      final out = await file.create(recursive: true);
      await out.writeAsString(jsonStr);
    } catch (_) {}
  }

  void _loadFromDb(Database db) {
    final verRows = db.select(
      "SELECT value FROM meta WHERE key = 'album_colors_version' LIMIT 1",
    );
    final ver = verRows.isEmpty ? null : verRows.first["value"] as String?;
    if (ver != _cacheVersion.toString()) {
      db.execute("DELETE FROM album_colors");
      db.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES('album_colors_version', ?)",
        [_cacheVersion.toString()],
      );
      return;
    }

    final rows = db.select("SELECT key, sig, p, on_p FROM album_colors");
    for (final row in rows) {
      final key = row["key"] as String;
      final sig = row["sig"] as String;
      final p = row["p"] as int;
      final on = row["on_p"] as int;
      _entries[key] = {"sig": sig, "p": p, "on": on};
    }
  }

  void _persistToDb(Database db) {
    db.execute("BEGIN");
    try {
      db.execute("DELETE FROM album_colors");
      db.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES('album_colors_version', ?)",
        [_cacheVersion.toString()],
      );
      for (final e in _entries.entries) {
        final m = e.value;
        final sig = m["sig"];
        final p = m["p"];
        final on = m["on"];
        if (sig is! String || p is! int || on is! int) continue;
        db.execute(
          "INSERT INTO album_colors(key, sig, p, on_p) VALUES(?, ?, ?, ?)",
          [e.key, sig, p, on],
        );
      }
      db.execute("COMMIT");
    } catch (_) {
      db.execute("ROLLBACK");
      rethrow;
    }
  }

  void _loadFromJsonFile(File file) {
    final str = file.readAsStringSync();
    final decoded = json.decode(str);
    if (decoded is! Map) return;
    if (decoded["version"] != _cacheVersion) return;
    final data = decoded["data"];
    if (data is! Map) return;
    for (final e in data.entries) {
      if (e.key is! String || e.value is! Map) continue;
      _entries[e.key] = Map<String, Object?>.from(e.value);
    }
  }

  (String, String) _albumKeyAndSignature(Album album) {
    final audio = album.works.first;
    final parent = Directory(File(audio.path).parent.path);
    final candidates = [
      File("${parent.path}\\cover.jpg"),
      File("${parent.path}\\cover.png"),
    ];
    for (final f in candidates) {
      if (f.existsSync()) {
        final stat = f.statSync();
        final mod = stat.modified.millisecondsSinceEpoch;
        final key = "file:${f.path}";
        final sig = "$key|$mod";
        return (key, sig);
      }
    }
    final key = "audio:${audio.path}";
    final sig = "$key|${audio.modified}";
    return (key, sig);
  }

  Future<Uint8List?> _getAlbumCoverBytes(Album album) async {
    final audio = album.works.first;
    final parent = Directory(File(audio.path).parent.path);
    final candidates = [
      File("${parent.path}\\cover.jpg"),
      File("${parent.path}\\cover.png"),
    ];
    for (final f in candidates) {
      if (f.existsSync()) {
        return f.readAsBytes();
      }
    }

    final bytes = await getPictureFromPath(path: audio.path, width: 64, height: 64);
    return bytes;
  }

  Future<int?> _computeAverageRgb(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 40, targetHeight: 40);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (data == null) return null;

    final rgba = data.buffer.asUint8List();
    int r = 0;
    int g = 0;
    int b = 0;
    int count = 0;

    for (int i = 0; i + 3 < rgba.length; i += 4) {
      final a = rgba[i + 3];
      if (a < 16) continue;
      r += rgba[i];
      g += rgba[i + 1];
      b += rgba[i + 2];
      count += 1;
    }

    if (count == 0) return null;
    final rr = (r / count).round().clamp(0, 255);
    final gg = (g / count).round().clamp(0, 255);
    final bb = (b / count).round().clamp(0, 255);

    return (rr << 16) | (gg << 8) | bb;
  }
}

class _AsyncSemaphore {
  final int _capacity;
  int _inUse = 0;
  final Queue<Completer<void>> _queue = Queue();

  _AsyncSemaphore(this._capacity);

  Future<T> run<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_inUse < _capacity) {
      _inUse += 1;
      return Future.value();
    }
    final c = Completer<void>();
    _queue.add(c);
    return c.future;
  }

  void _release() {
    final next = _queue.isEmpty ? null : _queue.removeFirst();
    if (next != null) {
      next.complete();
      return;
    }
    _inUse = max(0, _inUse - 1);
  }
}
