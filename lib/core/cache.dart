import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as path;

class AlbumColor {
  final Color primary;
  final Color onPrimary;
  const AlbumColor({required this.primary, required this.onPrimary});
}

class AlbumColorCache {
  static final instance = AlbumColorCache._();
  AlbumColorCache._();

  static const _cacheVersion = 1;

  bool _initialized = false;
  static const int _maxEntries = 200;
  final Map<String, Map<String, Object?>> _entries = {};
  final Map<String, Future<AlbumColor?>> _inFlight = {};
  Timer? _flushTimer;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final db = await AppDb.instance.db();
      _loadFromDb(db);
    } catch (_) {}
  }

  Future<AlbumColor?> getAlbumColor(Album album,
      {bool forceRecompute = false}) async {
    await init();
    final keySig = _albumKeyAndSignature(album);
    final key = keySig.$1;
    final signature = keySig.$2;
    if (!forceRecompute) {
      final cached = _entries[key];
      if (cached != null && cached['sig'] == signature) {
        final p = cached['p'];
        final on = cached['on'];
        if (p is int && on is int) {
          // LRU: 移到末尾（最近使用）
          _entries.remove(key);
          _entries[key] = cached;
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
        'sig': signature,
        'p': primary.toARGB32(),
        'on': onPrimary.toARGB32(),
      };
      // LRU 淘汰：超出上限时移除最旧条目
      while (_entries.length > _maxEntries) {
        _entries.remove(_entries.keys.first);
      }
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
      final db = await AppDb.instance.db();
      _persistToDb(db);
    } catch (_) {}
  }

  void dispose() {
    _flushTimer?.cancel();
    _entries.clear();
    _inFlight.clear();
  }

  void _loadFromDb(Database db) {
    final verRows = db.select(
      "SELECT value FROM meta WHERE key = 'album_colors_version' LIMIT 1",
    );
    final ver = verRows.isEmpty ? null : verRows.first['value'] as String?;
    if (ver != _cacheVersion.toString()) {
      db.execute('DELETE FROM album_colors');
      db.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES('album_colors_version', ?)",
        [_cacheVersion.toString()],
      );
      return;
    }

    final rows = db.select('SELECT key, sig, p, on_p FROM album_colors');
    for (final row in rows) {
      final key = row['key'] as String;
      final sig = row['sig'] as String;
      final p = row['p'] as int;
      final on = row['on_p'] as int;
      _entries[key] = {'sig': sig, 'p': p, 'on': on};
    }
  }

  void _persistToDb(Database db) {
    db.execute('BEGIN');
    try {
      db.execute('DELETE FROM album_colors');
      db.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES('album_colors_version', ?)",
        [_cacheVersion.toString()],
      );
      for (final e in _entries.entries) {
        final m = e.value;
        final sig = m['sig'];
        final p = m['p'];
        final on = m['on'];
        if (sig is! String || p is! int || on is! int) continue;
        db.execute(
          'INSERT INTO album_colors(key, sig, p, on_p) VALUES(?, ?, ?, ?)',
          [e.key, sig, p, on],
        );
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  File? _findLocalCoverFile(Directory parent) {
    final candidates = [
      File(path.join(parent.path, 'cover.jpg')),
      File(path.join(parent.path, 'cover.png')),
    ];
    for (final f in candidates) {
      if (f.existsSync()) return f;
    }
    return null;
  }

  (String, String) _albumKeyAndSignature(Album album) {
    final audio = album.works.isEmpty ? null : album.works.first;
    if (audio == null) return ('album:${album.name}', 'nomedia');
    final parent = Directory(File(audio.path).parent.path);
    final cover = _findLocalCoverFile(parent);
    if (cover != null) {
      final mod = cover.statSync().modified.millisecondsSinceEpoch;
      final key = 'file:${cover.path}';
      final sig = '$key|$mod';
      return (key, sig);
    }
    final key = 'audio:${audio.path}';
    final sig = '$key|${audio.modified}';
    return (key, sig);
  }

  Future<Uint8List?> _getAlbumCoverBytes(Album album) async {
    final audio = album.works.isEmpty ? null : album.works.first;
    if (audio == null) return null;
    final parent = Directory(File(audio.path).parent.path);
    final cover = _findLocalCoverFile(parent);
    if (cover != null) return cover.readAsBytes();

    final bytes =
        await getPictureFromPath(path: audio.path, width: 64, height: 64);
    return bytes;
  }

  Future<int?> _computeAverageRgb(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes,
        targetWidth: 40, targetHeight: 40);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    codec.dispose();
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

/// 通用 LRU 映射表
class _LruMap<K, V> {
  final int maxSize;
  final void Function(K key, V value)? onEvict;
  final _map = <K, V>{};

  _LruMap(this.maxSize, {this.onEvict});

  V? get(K key) {
    final value = _map.remove(key);
    if (value == null) return null;
    _map[key] = value;
    return value;
  }

  void set(K key, V value) {
    final old = _map.remove(key);
    if (old != null && !identical(old, value)) {
      onEvict?.call(key, old);
    }
    while (_map.length >= maxSize) {
      final oldestKey = _map.keys.first;
      final evicted = _map.remove(oldestKey);
      if (evicted != null) onEvict?.call(oldestKey, evicted);
    }
    _map[key] = value;
  }

  void remove(K key) {
    final removed = _map.remove(key);
    if (removed != null) onEvict?.call(key, removed);
  }

  void clear() {
    if (onEvict != null) {
      for (final entry in _map.entries) {
        onEvict!(entry.key, entry.value);
      }
    }
    _map.clear();
  }

  int get length => _map.length;

  void removeWhere(bool Function(K key) test) {
    final keys = _map.keys.where(test).toList(growable: false);
    for (final key in keys) {
      remove(key);
    }
  }
}

class CacheStats {
  final int smallEntries;
  final int mediumEntries;
  final int largeEntries;
  final int pendingRequests;
  final int hits;
  final int misses;
  final int smallBytes;
  final int mediumBytes;
  final int largeBytes;

  const CacheStats({
    required this.smallEntries,
    required this.mediumEntries,
    required this.largeEntries,
    required this.pendingRequests,
    required this.hits,
    required this.misses,
    required this.smallBytes,
    required this.mediumBytes,
    required this.largeBytes,
  });

  int get totalEntries => smallEntries + mediumEntries + largeEntries;
  int get totalBytes => smallBytes + mediumBytes + largeBytes;
  double? get hitRate {
    final total = hits + misses;
    return total > 0 ? hits / total : null;
  }
}

/// 统一封面 ImageProvider 缓存
/// 按尺寸分层：小(48x48)、中(200x200)、大(400x400)
/// 缓存 ImageProvider 而非 bytes，避免重复解码
class CoverImageCache {
  static final instance = CoverImageCache._();
  CoverImageCache._();

  late final _small = _LruMap<String, ImageProvider>(
    12,
    onEvict: (key, provider) {
      unawaited(provider.evict());
      _smallBytes.remove(key);
    },
  );
  late final _medium = _LruMap<String, ImageProvider>(
    4,
    onEvict: (key, provider) {
      unawaited(provider.evict());
      _mediumBytes.remove(key);
    },
  );
  late final _large = _LruMap<String, ImageProvider>(
    1,
    onEvict: (key, provider) {
      unawaited(provider.evict());
      _largeBytes.remove(key);
    },
  );
  final _smallBytes = <String, int>{};
  final _mediumBytes = <String, int>{};
  final _largeBytes = <String, int>{};
  final _pending = <String, Future<ImageProvider?>>{};
  int _generation = 0;
  int _hitCount = 0;
  int _missCount = 0;

  _LruMap<String, ImageProvider> _tierFor(int width, int height) {
    final max = width > height ? width : height;
    if (max <= 48) return _small;
    if (max <= 200) return _medium;
    return _large;
  }

  Future<ImageProvider?> get({
    required String path,
    required int width,
    required int height,
  }) async {
    final key = '$path|${width}x$height';
    final tier = _tierFor(width, height);

    final cached = tier.get(key);
    if (cached != null) {
      _hitCount++;
      return cached;
    }

    final pending = _pending[key];
    if (pending != null) {
      return pending;
    }

    _missCount++;
    final generation = _generation;
    final future = _fetch(path, width, height);
    _pending[key] = future;
    try {
      final result = await future;
      if (result != null &&
          generation == _generation &&
          identical(_pending[key], future)) {
        tier.set(key, result);
        _trackBytes(key, tier, result);
      }
      return result;
    } finally {
      if (identical(_pending[key], future)) {
        _pending.remove(key);
      }
    }
  }

  void _trackBytes(
    String key,
    _LruMap<String, ImageProvider> tier,
    ImageProvider provider,
  ) {
    final bytes = provider is MemoryImage ? provider.bytes.length : 0;
    final bytesMap = _bytesMapFor(tier);
    bytesMap.remove(key);
    bytesMap[key] = bytes;
  }

  Map<String, int> _bytesMapFor(_LruMap<String, ImageProvider> tier) {
    if (identical(tier, _small)) return _smallBytes;
    if (identical(tier, _medium)) return _mediumBytes;
    return _largeBytes;
  }

  Future<ImageProvider?> _fetch(String path, int width, int height) async {
    final ratio = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    final bytes = await getPictureFromPath(
      path: path,
      width: (width * ratio).round(),
      height: (height * ratio).round(),
    );
    if (bytes == null) return null;
    return MemoryImage(bytes);
  }

  void preload(String? path, {int width = 48, int height = 48}) {
    if (path == null) return;
    get(path: path, width: width, height: height).ignore();
  }

  void clear() {
    _generation++;
    _small.clear();
    _medium.clear();
    _large.clear();
    _pending.clear();
  }

  /// 释放不常用的缓存层，保留小图缓存以维持列表流畅滚动
  void trimMemory() {
    _generation++;
    _medium.clear();
    _large.clear();
    _pending.clear();
  }

  void evictPath(String path) {
    _generation++;
    final prefix = '$path|';
    bool matches(String key) => key.startsWith(prefix);
    _small.removeWhere(matches);
    _medium.removeWhere(matches);
    _large.removeWhere(matches);
    _pending.removeWhere((key, _) => matches(key));
  }

  CacheStats get stats => CacheStats(
        smallEntries: _small.length,
        mediumEntries: _medium.length,
        largeEntries: _large.length,
        pendingRequests: _pending.length,
        hits: _hitCount,
        misses: _missCount,
        smallBytes: _smallBytes.values.fold(0, (a, b) => a + b),
        mediumBytes: _mediumBytes.values.fold(0, (a, b) => a + b),
        largeBytes: _largeBytes.values.fold(0, (a, b) => a + b),
      );

  void logStats() {
    final s = stats;
    logger.d(
      '[cache] CoverImageCache '
      '${s.hits}h/${s.misses}m '
      '(hit rate ${(s.hitRate! * 100).toStringAsFixed(0)}%) '
      '| ${s.smallEntries}s/${s.mediumEntries}m/${s.largeEntries}l entries '
      '| ${(s.smallBytes / 1024).toStringAsFixed(0)}/${(s.mediumBytes / 1024).toStringAsFixed(0)}/${(s.largeBytes / 1024).toStringAsFixed(0)} KB '
      '| ${s.pendingRequests} pending',
    );
  }

  /// 完全释放并清理所有缓存
  void dispose() {
    _generation++;
    _small.clear();
    _medium.clear();
    _large.clear();
    _pending.clear();
  }
}
