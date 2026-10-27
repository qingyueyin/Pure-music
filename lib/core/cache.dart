import 'dart:developer' as developer;
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:pure_music/core/color_extraction.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/workload_policy.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as library_db;
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/remote/remote_library.dart';
import 'package:flutter/foundation.dart';
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
  int _generation = 0;
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

  Future<AlbumColor?> getAlbumColor(
    Album album, {
    bool forceRecompute = false,
  }) async {
    await init();
    final keySig = await _albumKeyAndSignature(album);
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

    final generation = _generation;
    final fut = _computeAndStore(
      album,
      key: key,
      signature: signature,
      generation: generation,
    );
    _inFlight[key] = fut;
    unawaited(
      fut.whenComplete(() {
        _inFlight.remove(key);
      }),
    );
    return fut;
  }

  AlbumColor? getAlbumColorSync(Album album) {
    final keySig = _albumKeyAndSignatureSync(album);
    final key = keySig.$1;
    final signature = keySig.$2;
    final cached = _entries[key];
    if (cached == null || cached['sig'] != signature) return null;
    final p = cached['p'];
    final on = cached['on'];
    if (p is! int || on is! int) return null;
    _entries.remove(key);
    _entries[key] = cached;
    return AlbumColor(primary: Color(p), onPrimary: Color(on));
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
      futures.add(
        sem.run(() async {
          await getAlbumColor(album);
          done += 1;
          onProgress?.call(done, total);
          if (done % 12 == 0) {
            await Future<void>.delayed(Duration.zero);
          }
        }),
      );
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
      futures.add(
        sem.run(() async {
          await getAlbumColor(album, forceRecompute: true);
          done += 1;
          onProgress?.call(done, total);
          if (done % 8 == 0) {
            await Future<void>.delayed(Duration.zero);
          }
        }),
      );
    }
    await Future.wait(futures);
  }

  Future<AlbumColor?> _computeAndStore(
    Album album, {
    required String key,
    required String signature,
    required int generation,
  }) async {
    try {
      final bytes = await _getAlbumCoverBytes(album);
      if (bytes == null) return null;
      final rgb = await _computeAverageRgb(bytes);
      if (rgb == null || generation != _generation) return null;

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
    _generation++;
    _flushTimer?.cancel();
    _flushTimer = null;
    _initialized = false;
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

  File? _findLocalCoverFileSync(Directory parent) {
    final candidates = [
      File(path.join(parent.path, 'cover.jpg')),
      File(path.join(parent.path, 'cover.png')),
    ];
    for (final f in candidates) {
      if (f.existsSync()) return f;
    }
    return null;
  }

  Future<(String, String)> _albumKeyAndSignature(Album album) async {
    final audio = album.works.isEmpty ? null : album.works.first;
    if (audio == null) return ('album:${album.name}', 'nomedia');
    final coverPath = await audio.resolveFolderCoverPath();
    if (coverPath != null) {
      final cover = File(coverPath);
      final mod = (await cover.stat()).modified.millisecondsSinceEpoch;
      final key = 'file:$coverPath';
      final sig = '$key|$mod';
      return (key, sig);
    }
    final key = 'audio:${audio.path}';
    final sig = '$key|${audio.modified}';
    return (key, sig);
  }

  (String, String) _albumKeyAndSignatureSync(Album album) {
    final audio = album.works.isEmpty ? null : album.works.first;
    if (audio == null) return ('album:${album.name}', 'nomedia');
    final parent = Directory(File(audio.path).parent.path);
    final cover = _findLocalCoverFileSync(parent);
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
    final coverPath = await audio.resolveFolderCoverPath();
    if (coverPath != null) return File(coverPath).readAsBytes();

    final bytes = await CoverImageCache.instance.loadBytes(
      path: audio.path,
      modified: audio.modified,
      width: 64,
      height: 64,
    );
    return bytes;
  }

  Future<int?> _computeAverageRgb(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 40,
      targetHeight: 40,
    );
    ui.Image? img;
    ByteData? data;
    try {
      final frame = await codec.getNextFrame();
      img = frame.image;
      data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    } finally {
      img?.dispose();
      codec.dispose();
    }
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
  final Queue<Completer<void>> _highPriority = Queue();
  final Queue<Completer<void>> _lowPriority = Queue();

  _AsyncSemaphore(this._capacity);

  Future<T> run<T>(
    Future<T> Function() task, {
    bool lowPriority = false,
  }) async {
    await _acquire(lowPriority);
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<void> _acquire(bool lowPriority) {
    if (_inUse < _capacity) {
      _inUse += 1;
      return Future.value();
    }
    final c = Completer<void>();
    (lowPriority ? _lowPriority : _highPriority).add(c);
    return c.future;
  }

  void _release() {
    final next = _highPriority.isNotEmpty
        ? _highPriority.removeFirst()
        : _lowPriority.isNotEmpty
        ? _lowPriority.removeFirst()
        : null;
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
  final void Function(K key, V value)? onRemove;
  final void Function(K key, V value)? onEvict;
  final _map = <K, V>{};

  _LruMap(this.maxSize, {this.onRemove, this.onEvict});

  void _discard(K key, V value, {required bool evict}) {
    onRemove?.call(key, value);
    if (evict) onEvict?.call(key, value);
  }

  V? get(K key) {
    final value = _map.remove(key);
    if (value == null) return null;
    _map[key] = value;
    return value;
  }

  void set(K key, V value) {
    final old = _map.remove(key);
    if (old != null && !identical(old, value)) {
      _discard(key, old, evict: false);
    }
    while (_map.length >= maxSize) {
      final oldestKey = _map.keys.first;
      final evicted = _map.remove(oldestKey);
      if (evicted != null) _discard(oldestKey, evicted, evict: true);
    }
    _map[key] = value;
  }

  void remove(K key) {
    final removed = _map.remove(key);
    if (removed != null) _discard(key, removed, evict: true);
  }

  void clear() {
    for (final entry in _map.entries) {
      _discard(entry.key, entry.value, evict: true);
    }
    _map.clear();
  }

  int get length => _map.length;

  /// 最久没被用到的键。空表时为空。
  K? get oldestKey => _map.isEmpty ? null : _map.keys.first;

  void removeWhere(bool Function(K key) test) {
    final keys = _map.keys.where(test).toList(growable: false);
    for (final key in keys) {
      remove(key);
    }
  }

  /// 超过上限时从最久未用的键开始删，[keep] 为真的键不动。
  void trimToSize(int size, {bool Function(K key)? keep}) {
    while (_map.length > size) {
      K? oldestKey;
      for (final key in _map.keys) {
        if (keep == null || !keep(key)) {
          oldestKey = key;
          break;
        }
      }
      if (oldestKey == null) return;
      final removed = _map.remove(oldestKey);
      if (removed != null) _discard(oldestKey, removed, evict: true);
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
@immutable
class _StableCoverKey {
  const _StableCoverKey({
    required this.path,
    required this.width,
    required this.height,
    required this.pixelRatio,
    required this.generation,
  });

  final String path;
  final int width;
  final int height;
  final double pixelRatio;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is _StableCoverKey &&
      other.path == path &&
      other.width == width &&
      other.height == height &&
      other.pixelRatio == pixelRatio &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(path, width, height, pixelRatio, generation);
}

@immutable
class _StableCoverImage extends ImageProvider<_StableCoverKey> {
  const _StableCoverImage({
    required this.path,
    required this.width,
    required this.height,
    required this.pixelRatio,
    required this.generation,
    this.initialBytes,
  });

  final String path;
  final int width;
  final int height;
  final double pixelRatio;
  final int generation;
  final Uint8List? initialBytes;

  int get byteLength => initialBytes?.length ?? 0;
  _StableCoverKey get cacheKey => _StableCoverKey(
    path: path,
    width: width,
    height: height,
    pixelRatio: pixelRatio,
    generation: generation,
  );

  @override
  Future<_StableCoverKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_StableCoverKey>(cacheKey);

  @override
  ImageStreamCompleter loadImage(
    _StableCoverKey key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1,
      debugLabel: 'CoverImage(${key.path}, ${key.width}x${key.height})',
    );
  }

  Future<ui.Codec> _loadAsync(
    _StableCoverKey key,
    ImageDecoderCallback decode,
  ) async {
    final bytes =
        initialBytes ??
        await CoverImageCache.instance._loadBytesAt(
          path: key.path,
          width: key.width,
          height: key.height,
          pixelRatio: key.pixelRatio,
        );
    if (bytes == null) {
      throw StateError('Cover image is unavailable: ${key.path}');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }
}

class CoverImageCache {
  static final instance = CoverImageCache._();
  CoverImageCache._();

  static const int _smallByteBudget = 12 * 1024 * 1024;
  static const int _mediumByteBudget = 8 * 1024 * 1024;
  static const int _largeByteBudget = 12 * 1024 * 1024;

  /// 测试里把小图预算改小，用来验证超限会赶走旧图。
  @visibleForTesting
  int? debugSmallByteBudget;

  late final _small = _LruMap<String, ImageProvider>(
    256,
    onRemove: (key, _) => _smallBytes.remove(key),
    onEvict: (_, provider) => unawaited(provider.evict()),
  );
  late final _medium = _LruMap<String, ImageProvider>(
    64,
    onRemove: (key, _) => _mediumBytes.remove(key),
    onEvict: (_, provider) => unawaited(provider.evict()),
  );
  late final _large = _LruMap<String, ImageProvider>(
    4,
    onRemove: (key, _) => _largeBytes.remove(key),
    onEvict: (_, provider) => unawaited(provider.evict()),
  );
  final _smallBytes = <String, int>{};
  final _mediumBytes = <String, int>{};
  final _largeBytes = <String, int>{};
  final _pending = <String, Future<ImageProvider?>>{};
  final _pendingBytes = <String, Future<Uint8List?>>{};
  final _decodedBytes = _LruMap<String, Uint8List>(20);
  final _persistentWarmCompleted = <String>{};
  final _persistentWarmPending = <String>{};
  late final _missing = _LruMap<String, bool>(512);
  final _coverLoadSemaphore = _AsyncSemaphore(
    backgroundWorkerConcurrencyFor(applicationProcessorBudget),
  );
  int _generation = 0;
  int _stableImageGeneration = 0;
  final Set<(int, int, double)> _stableImageConfigurations = {};
  int _hitCount = 0;
  int _missCount = 0;
  String? _indexPath;
  bool _databaseWarningLogged = false;

  void configure({required String indexPath}) {
    _indexPath = indexPath;
  }

  _LruMap<String, ImageProvider> _tierFor(int width, int height) {
    final max = width > height ? width : height;
    if (max <= 48) return _small;
    if (max <= 200) return _medium;
    return _large;
  }

  String _coverKey(String path, int width, int height, {int? modified}) {
    final size = '${width}x$height';
    if (modified == null) return '$path|$size';
    return '$path|$modified|$size';
  }

  Future<ImageProvider?> get({
    required String path,
    required int width,
    required int height,
    int? modified,
  }) async {
    final key = _coverKey(path, width, height, modified: modified);
    final tier = _tierFor(width, height);

    final cached = _getCached(
      key,
      tier,
      path: path,
      width: width,
      height: height,
    );
    if (cached != null) {
      return cached;
    }

    final pending = _pending[key];
    if (pending != null) {
      return pending;
    }

    _missCount++;
    final generation = _generation;
    final future = _fetch(path, width, height, modified: modified);
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
        final removed = _pending.remove(key);
        if (removed != null) unawaited(removed);
      }
    }
  }

  ImageProvider? getCached({
    required String path,
    required int width,
    required int height,
    int? modified,
  }) {
    final key = _coverKey(path, width, height, modified: modified);
    return _getCached(
      key,
      _tierFor(width, height),
      path: path,
      width: width,
      height: height,
    );
  }

  ImageProvider? _getCached(
    String key,
    _LruMap<String, ImageProvider> tier, {
    required String path,
    required int width,
    required int height,
  }) {
    final cached = tier.get(key);
    if (cached != null) {
      _hitCount++;
      return cached;
    }
    final stable = _stableImage(path: path, width: width, height: height);
    final status = PaintingBinding.instance.imageCache.statusForKey(
      stable.cacheKey,
    );
    if (!status.pending && !status.keepAlive && !status.live) return null;
    _hitCount++;
    return stable;
  }

  void _trackBytes(
    String key,
    _LruMap<String, ImageProvider> tier,
    ImageProvider provider,
  ) {
    final bytes = switch (provider) {
      MemoryImage image => image.bytes.length,
      _StableCoverImage image => image.byteLength,
      _ => 0,
    };
    final bytesMap = _bytesMapFor(tier);
    bytesMap.remove(key);
    bytesMap[key] = bytes;
    _trimTierToByteBudget(tier, bytesMap);
  }

  int _byteBudgetFor(_LruMap<String, ImageProvider> tier) {
    if (identical(tier, _small)) {
      return debugSmallByteBudget ?? _smallByteBudget;
    }
    if (identical(tier, _medium)) return _mediumByteBudget;
    return _largeByteBudget;
  }

  /// 超过字节预算就从最久未用的图开始释放，刚放进去的那张留着。
  void _trimTierToByteBudget(
    _LruMap<String, ImageProvider> tier,
    Map<String, int> bytesMap,
  ) {
    final budget = _byteBudgetFor(tier);
    var total = 0;
    for (final value in bytesMap.values) {
      total += value;
    }
    while (total > budget && tier.length > 1) {
      final oldest = tier.oldestKey;
      if (oldest == null) return;
      final size = bytesMap[oldest] ?? 0;
      tier.remove(oldest);
      total -= size;
    }
  }

  @visibleForTesting
  void rememberCoverForTesting({
    required String path,
    required int width,
    required int height,
    required Uint8List bytes,
  }) {
    final key = _coverKey(path, width, height);
    final tier = _tierFor(width, height);
    final provider = _stableImage(
      path: path,
      width: width,
      height: height,
      initialBytes: bytes,
    );
    tier.set(key, provider);
    _trackBytes(key, tier, provider);
  }

  Map<String, int> _bytesMapFor(_LruMap<String, ImageProvider> tier) {
    if (identical(tier, _small)) return _smallBytes;
    if (identical(tier, _medium)) return _mediumBytes;
    return _largeBytes;
  }

  Future<ImageProvider?> _fetch(
    String path,
    int width,
    int height, {
    int? modified,
  }) async {
    final bytes = await loadBytes(
      path: path,
      width: width,
      height: height,
      modified: modified,
    );
    if (bytes == null) return null;
    return _stableImage(
      path: path,
      width: width,
      height: height,
      initialBytes: bytes,
    );
  }

  _StableCoverImage _stableImage({
    required String path,
    required int width,
    required int height,
    Uint8List? initialBytes,
  }) {
    final pixelRatio =
        ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    _stableImageConfigurations.add((width, height, pixelRatio));
    return _StableCoverImage(
      path: path,
      width: width,
      height: height,
      pixelRatio: pixelRatio,
      generation: _stableImageGeneration,
      initialBytes: initialBytes,
    );
  }

  @visibleForTesting
  ImageProvider stableImageForTesting({
    required String path,
    required int width,
    required int height,
    required Uint8List bytes,
  }) => _stableImage(
    path: path,
    width: width,
    height: height,
    initialBytes: bytes,
  );

  @visibleForTesting
  int get stableImageConfigurationCountForTesting =>
      _stableImageConfigurations.length;

  @visibleForTesting
  int get decodedBytesCountForTesting => _decodedBytes.length;

  Future<Uint8List?> loadBytes({
    required String path,
    required int width,
    required int height,
    bool lowPriority = false,
    int? modified,
  }) async {
    final pixelRatio =
        ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    return _loadBytesAt(
      path: path,
      width: width,
      height: height,
      pixelRatio: pixelRatio,
      lowPriority: lowPriority,
      modified: modified,
    );
  }

  Future<Uint8List?> loadPhysicalBytes({
    required String path,
    required int width,
    required int height,
  }) => _loadBytesAt(path: path, width: width, height: height, pixelRatio: 1);

  Future<Uint8List?> _loadBytesAt({
    required String path,
    required int width,
    required int height,
    required double pixelRatio,
    bool lowPriority = false,
    int? modified,
  }) async {
    final physicalWidth = (width * pixelRatio).round();
    final physicalHeight = (height * pixelRatio).round();
    final key = _coverKey(
      path,
      physicalWidth,
      physicalHeight,
      modified: modified,
    );
    final cached = _decodedBytes.get(key);
    if (cached != null) return cached;
    final pending = _pendingBytes[key];
    if (pending != null) return pending;

    if (_missing.get(key) == true) return null;

    final generation = _generation;
    final future = _coverLoadSemaphore.run(
      () => _loadBytesUncached(
        path: path,
        physicalWidth: physicalWidth,
        physicalHeight: physicalHeight,
      ),
      lowPriority: lowPriority,
    );
    _pendingBytes[key] = future;
    try {
      final result = await future;
      if (generation == _generation) {
        if (result == null) {
          _missing.set(key, true);
        } else {
          _decodedBytes.set(key, result);
        }
      }
      return result;
    } finally {
      if (identical(_pendingBytes[key], future)) {
        final removed = _pendingBytes.remove(key);
        if (removed != null) unawaited(removed);
      }
    }
  }

  /// 小封面（≤96 物理像素）直接 FFI 读音频文件，不走 SQLite 持久化层：
  /// 内存缓存已足以覆盖列表滚动距离，省掉每次 stat + 全局锁 + SQLite 查询。
  /// 大封面仍走持久化缓存，命中时避免重复读音频文件。
  Future<Uint8List?> _loadBytesUncached({
    required String path,
    required int physicalWidth,
    required int physicalHeight,
  }) async {
    developer.Timeline.startSync('cover.decode');
    try {
      final indexPath = _indexPath;
      final maxPhysical = max(physicalWidth, physicalHeight);
      if (RemoteLibrary.isRemotePath(path)) {
        return RemoteLibrary.instance.coverBytes(path, maxPhysical);
      }
      if (indexPath != null && maxPhysical > 96) {
        try {
          return await library_db.getCachedCover(
            indexPath: indexPath,
            path: path,
            width: physicalWidth,
            height: physicalHeight,
          );
        } catch (error, trace) {
          if (!_databaseWarningLogged) {
            _databaseWarningLogged = true;
            log.app.warn(
              'legacy',
              '[cache] persistent cover cache unavailable: $error',
              stackTrace: trace,
            );
          }
        }
      }
      return getPictureFromPath(
        path: path,
        width: physicalWidth,
        height: physicalHeight,
      );
    } finally {
      developer.Timeline.finishSync();
    }
  }

  /// 后台预生成常用缩略图，字节写入磁盘后立即释放。
  void preloadPersistent(Iterable<Audio> audios) {
    if (_indexPath == null) return;
    final targets = <String, int>{};
    for (final audio in audios) {
      if (audio.path.isNotEmpty) targets[audio.path] = audio.modified;
    }
    if (targets.isEmpty) return;
    unawaited(_warmPersistent(targets));
  }

  Future<void> _warmPersistent(Map<String, int> targets) async {
    final generation = _generation;
    var processed = 0;
    for (final entry in targets.entries) {
      if (generation != _generation) break;
      const size = 200;
      final key = '${entry.key}|${entry.value}|${size}x$size';
      if (_persistentWarmCompleted.contains(key) ||
          !_persistentWarmPending.add(key)) {
        continue;
      }
      try {
        await loadBytes(
          path: entry.key,
          width: size,
          height: size,
          modified: entry.value,
          lowPriority: true,
        );
        if (generation == _generation) {
          _persistentWarmCompleted.add(key);
        }
      } catch (error, trace) {
        log.app.debug(
          'legacy',
          '[cache] persistent cover warm skipped: $error',
          stackTrace: trace,
        );
      } finally {
        _persistentWarmPending.remove(key);
      }
      processed++;
      if (processed % 8 == 0) await Future<void>.delayed(Duration.zero);
    }
  }

  void preload(String? path, {int width = 48, int height = 48, int? modified}) {
    if (path == null) return;
    get(path: path, width: width, height: height, modified: modified).ignore();
  }

  void putDecodedBytes({
    required String path,
    required int width,
    required int height,
    required Uint8List bytes,
    int? modified,
  }) {
    final pixelRatio =
        ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    final key = _coverKey(
      path,
      (width * pixelRatio).round(),
      (height * pixelRatio).round(),
      modified: modified,
    );
    _decodedBytes.set(key, bytes);
  }

  void preloadNowPlayingCover(Audio audio) {
    if (audio.path.isEmpty) return;
    unawaited(_preloadNowPlayingCover(audio));
  }

  Future<void> _preloadNowPlayingCover(Audio audio) async {
    final generation = _generation;
    final path = audio.path;
    final modified = audio.modified;
    final colors = ColorExtractionService();
    if (colors.getCachedPaletteForPath(path, modified: modified) != null) {
      await loadBytes(
        path: path,
        width: 160,
        height: 160,
        modified: modified,
        lowPriority: true,
      );
      return;
    }
    try {
      final result = await getPictureAndColors(
        path: path,
        width: 160,
        height: 160,
        numColors: 8,
      );
      final bytes = result.$1;
      if (bytes != null && generation == _generation) {
        putDecodedBytes(
          path: path,
          width: 160,
          height: 160,
          bytes: bytes,
          modified: modified,
        );
      }
      if (generation == _generation && result.$2.isNotEmpty) {
        colors.cachePaletteForPath(path, [
          for (final argb in result.$2) Color(argb),
        ], modified: modified);
      }
    } catch (error, trace) {
      log.app.debug(
        'legacy',
        '[cache] now playing cover prefetch skipped: $error',
        stackTrace: trace,
      );
    }
  }

  void clear() {
    _generation++;
    _stableImageGeneration++;
    _small.clear();
    _medium.clear();
    _large.clear();
    _pending.clear();
    _pendingBytes.clear();
    _decodedBytes.clear();
    _missing.clear();
    _persistentWarmCompleted.clear();
    _persistentWarmPending.clear();
  }

  /// 释放不常用的缓存层，保留小图缓存以维持列表流畅滚动
  /// [keepPath] 指定保留当前播放曲目的缓存，避免回退时重新 FFI 加载
  void trimMemory({String? keepPath}) {
    if (keepPath != null) {
      final prefix = '$keepPath|';
      bool notKeep(String key) => !key.startsWith(prefix);
      _medium.removeWhere(notKeep);
      _large.removeWhere(notKeep);
      _pending.removeWhere((key, _) => notKeep(key));
      _pendingBytes.removeWhere((key, _) => notKeep(key));
      _decodedBytes.removeWhere(notKeep);
      _missing.removeWhere(notKeep);
    } else {
      _generation++;
      _medium.clear();
      _large.clear();
      _pending.clear();
      _pendingBytes.clear();
      _decodedBytes.clear();
      _missing.clear();
    }
  }

  /// 按上限缩小图缓存，当前播放曲目的图始终保留。
  void trimSmall({required int keepEntries}) {
    final keepPath = AudioLibrary.instance.currentPlayingPath;
    final keepPrefix = keepPath == null || keepPath.isEmpty
        ? null
        : '$keepPath|';
    bool keep(String key) => keepPrefix != null && key.startsWith(keepPrefix);
    _small.trimToSize(keepEntries.clamp(0, 96), keep: keep);
  }

  void evictPath(String path) {
    _generation++;
    final prefix = '$path|';
    bool matches(String key) => key.startsWith(prefix);
    _small.removeWhere(matches);
    _medium.removeWhere(matches);
    _large.removeWhere(matches);
    _pending.removeWhere((key, _) => matches(key));
    _pendingBytes.removeWhere((key, _) => matches(key));
    _decodedBytes.removeWhere(matches);
    _missing.removeWhere(matches);
    _persistentWarmCompleted.removeWhere((key) => key.startsWith('$path|'));
    _persistentWarmPending.removeWhere((key) => key.startsWith('$path|'));
    for (final configuration in _stableImageConfigurations) {
      unawaited(
        _StableCoverImage(
          path: path,
          width: configuration.$1,
          height: configuration.$2,
          pixelRatio: configuration.$3,
          generation: _stableImageGeneration,
        ).evict(),
      );
    }
  }

  CacheStats get stats => CacheStats(
    smallEntries: _small.length,
    mediumEntries: _medium.length,
    largeEntries: _large.length,
    pendingRequests: _pending.length + _pendingBytes.length,
    hits: _hitCount,
    misses: _missCount,
    smallBytes: _smallBytes.values.fold(0, (a, b) => a + b),
    mediumBytes: _mediumBytes.values.fold(0, (a, b) => a + b),
    largeBytes: _largeBytes.values.fold(0, (a, b) => a + b),
  );

  void logStats() {
    final s = stats;
    final hitRate = s.hitRate;
    final hitRateText = hitRate == null
        ? '-'
        : '${(hitRate * 100).toStringAsFixed(0)}%';
    log.app.debug(
      'legacy',
      '[cache] CoverImageCache '
          '${s.hits}h/${s.misses}m '
          '(hit rate $hitRateText) '
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
    _pendingBytes.clear();
    _decodedBytes.clear();
    _missing.clear();
    _persistentWarmCompleted.clear();
    _persistentWarmPending.clear();
  }
}
