import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:path/path.dart' as p;

/// 智能排序特征缓存：按 path + mtime 持久化每首乐曲的紧凑特征 JSON。
/// 乐曲文件未变化时直接复用，只对新增或已修改的乐曲做增量分析。
class SmartSortFeatureCache {
  SmartSortFeatureCache._({Future<Directory> Function()? appDataDirectory})
    : _appDataDirectory = appDataDirectory ?? getAppDataDir;

  static final SmartSortFeatureCache instance = SmartSortFeatureCache._();

  @visibleForTesting
  factory SmartSortFeatureCache.forTesting(Directory directory) =>
      SmartSortFeatureCache._(appDataDirectory: () async => directory);

  static const _fileName = 'smart_sort_features.json';
  static const _featureVersion = 2;
  final Future<Directory> Function() _appDataDirectory;

  String _keyForPath(String value) =>
      p.normalize(p.absolute(value)).replaceAll('\\', '/').toLowerCase();

  /// path 到 {"mtime", "features"} 的映射，features 为可直接拼接进 FFI 输入的紧凑特征 JSON。
  Map<String, dynamic>? _store;
  Future<Map<String, dynamic>>? _loadFuture;
  Future<void>? _flushFuture;
  bool _loaded = false;
  bool _dirty = false;

  Future<Map<String, dynamic>> _loadStore() {
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

  Future<Map<String, dynamic>> _loadStoreNow() async {
    final loaded = <String, dynamic>{};
    try {
      final dir = await _appDataDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$_fileName');
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) {
          loaded.addAll(decoded);
        }
      }
    } catch (error, trace) {
      logger.w(
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
    if (entry is! Map<String, dynamic>) return null;
    if (entry['version'] != _featureVersion) return null;
    final mtime = switch (entry['mtime']) {
      num value => value.toInt(),
      String value => int.tryParse(value),
      _ => null,
    };
    if (mtime != audio.modified) return null;
    final features = entry['features'];
    return features is String ? features : null;
  }

  void put(Audio audio, String featuresJson) {
    (_store ??= <String, dynamic>{})[_keyForPath(audio.path)] = {
      'version': _featureVersion,
      'mtime': audio.modified,
      'features': featuresJson,
    };
    _dirty = true;
  }

  Future<void> flush() {
    if (!_dirty && _flushFuture == null) return Future.value();
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
    if (!_dirty) return;
    final store = await _loadStore();
    final dir = await _appDataDirectory();
    final filePath = '${dir.path}${Platform.pathSeparator}$_fileName';
    while (_dirty) {
      final content = jsonEncode(store);
      _dirty = false;
      try {
        await writeTextFileAtomically(filePath, content);
      } catch (error, trace) {
        _dirty = true;
        logger.w(
          '[smart sort] feature cache save failed',
          error: error,
          stackTrace: trace,
        );
        return;
      }
    }
  }
}
