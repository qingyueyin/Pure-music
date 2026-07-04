import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

class ColorExtractionService {
  static final ColorExtractionService _instance = ColorExtractionService._internal();
  factory ColorExtractionService() => _instance;
  ColorExtractionService._internal();

  static const int _maxCacheSize = 50;
  static const Duration _cacheDuration = Duration(minutes: 10);
  final Map<String, Color> _colorCache = {};
  final Map<String, DateTime> _cacheTime = {};
  final List<String> _accessOrder = [];

  /// 按音频路径缓存的主色，供首帧同步读取
  final Map<String, Color> _pathColorCache = {};

  void cacheColorForPath(String path, Color color) {
    _pathColorCache[path] = color;
  }

  Color? getCachedColorForPath(String path) => _pathColorCache[path];

  Future<Color?> extractDominantColor(Uint8List? imageBytes) async {
    if (imageBytes == null || imageBytes.isEmpty) return null;

    final cacheKey = imageBytes.hashCode.toString();

    if (_colorCache.containsKey(cacheKey)) {
      final cacheAge = DateTime.now().difference(_cacheTime[cacheKey]!);
      if (cacheAge < _cacheDuration) {
        _touchCacheEntry(cacheKey);
        return _colorCache[cacheKey];
      } else {
        _removeCacheEntry(cacheKey);
      }
    }

    try {
      final imageProvider = MemoryImage(imageBytes);

      final palette = await PaletteGenerator.fromImageProvider(
        imageProvider,
        size: const Size(100, 100),
        maximumColorCount: 5,
      );

      // PaletteGenerator.fromImageProvider 会在 Flutter ImageCache 中驻留原图，
      // 大封面长期占用内存，提取完成后立即逐出。
      PaintingBinding.instance.imageCache.evict(imageProvider);

      final dominantColor = palette.dominantColor?.color;
      if (dominantColor == null) return null;

      _putCacheEntry(cacheKey, dominantColor);

      return dominantColor;
    } catch (e) {
      debugPrint('Color extraction failed: $e');
      return null;
    }
  }

  void _touchCacheEntry(String key) {
    _accessOrder.remove(key);
    _accessOrder.add(key);
  }

  void _removeCacheEntry(String key) {
    _colorCache.remove(key);
    _cacheTime.remove(key);
    _accessOrder.remove(key);
  }

  void _putCacheEntry(String key, Color color) {
    _evictExpiredEntries();
    while (_colorCache.length >= _maxCacheSize && _accessOrder.isNotEmpty) {
      final oldest = _accessOrder.removeAt(0);
      _removeCacheEntry(oldest);
    }
    _colorCache[key] = color;
    _cacheTime[key] = DateTime.now();
    _accessOrder.add(key);
  }

  void _evictExpiredEntries() {
    final now = DateTime.now();
    final expired = <String>[];
    for (final entry in _cacheTime.entries) {
      if (now.difference(entry.value) > _cacheDuration) {
        expired.add(entry.key);
      }
    }
    for (final key in expired) {
      _removeCacheEntry(key);
    }
  }

  void clearExpiredCache() {
    _evictExpiredEntries();
  }

  Color getComplementaryColor(Color color, {double offset = 0.2}) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withHue((hsl.hue + 30) % 360)
        .withSaturation((hsl.saturation + offset).clamp(0.0, 1.0))
        .toColor();
  }

  static bool isColorLight(Color color) {
    final r = (color.r * 255.0).round().clamp(0, 255);
    final g = (color.g * 255.0).round().clamp(0, 255);
    final b = (color.b * 255.0).round().clamp(0, 255);
    final luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
    return luminance > 0.5;
  }

  void clear() {
    _colorCache.clear();
    _cacheTime.clear();
  }
}
