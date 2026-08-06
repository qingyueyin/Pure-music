import 'package:flutter/material.dart';

class ColorExtractionService {
  static final ColorExtractionService _instance =
      ColorExtractionService._internal();
  factory ColorExtractionService() => _instance;
  ColorExtractionService._internal();

  static const int _maxPathCacheSize = 200;

  /// 按音频路径缓存的主色，供首帧同步读取
  final Map<String, Color> _pathColorCache = {};
  final Map<String, List<Color>> _pathPaletteCache = {};
  final List<String> _pathAccessOrder = [];

  void cachePaletteForPath(String path, List<Color> palette) {
    if (palette.isEmpty) return;
    _pathPaletteCache[path] = List.unmodifiable(palette);
    _pathColorCache[path] = palette.first;
    _trimPathCache(path);
  }

  void _trimPathCache(String path) {
    _touchPathCacheEntry(path);
    while (_pathAccessOrder.length > _maxPathCacheSize &&
        _pathAccessOrder.isNotEmpty) {
      final oldest = _pathAccessOrder.removeAt(0);
      _pathColorCache.remove(oldest);
      _pathPaletteCache.remove(oldest);
    }
  }

  Color? getCachedColorForPath(String path) {
    final color = _pathColorCache[path];
    if (color != null) _touchPathCacheEntry(path);
    return color;
  }

  List<Color>? getCachedPaletteForPath(String path) {
    final palette = _pathPaletteCache[path];
    if (palette != null) {
      _touchPathCacheEntry(path);
      return List<Color>.from(palette);
    }
    return null;
  }

  void _touchPathCacheEntry(String path) {
    _pathAccessOrder.remove(path);
    _pathAccessOrder.add(path);
  }

  void clear() {
    _pathColorCache.clear();
    _pathPaletteCache.clear();
    _pathAccessOrder.clear();
  }
}
