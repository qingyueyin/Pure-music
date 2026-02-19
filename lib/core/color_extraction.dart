import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

class ColorExtractionService {
  static final ColorExtractionService _instance = ColorExtractionService._internal();
  factory ColorExtractionService() => _instance;
  ColorExtractionService._internal();

  final Map<String, Color> _colorCache = {};
  final Duration _cacheDuration = const Duration(minutes: 10);
  final Map<String, DateTime> _cacheTime = {};

  Future<Color?> extractDominantColor(Uint8List? imageBytes) async {
    if (imageBytes == null || imageBytes.isEmpty) return null;

    final cacheKey = imageBytes.hashCode.toString();

    if (_colorCache.containsKey(cacheKey)) {
      final cacheAge = DateTime.now().difference(_cacheTime[cacheKey]!);
      if (cacheAge < _cacheDuration) {
        return _colorCache[cacheKey];
      }
    }

    try {
      final imageProvider = MemoryImage(imageBytes);

      final palette = await PaletteGenerator.fromImageProvider(
        imageProvider,
        size: const Size(100, 100),
        maximumColorCount: 5,
      );

      final dominantColor = palette.dominantColor?.color;
      if (dominantColor == null) return null;

      _colorCache[cacheKey] = dominantColor;
      _cacheTime[cacheKey] = DateTime.now();

      return dominantColor;
    } catch (e) {
      debugPrint('Color extraction failed: $e');
      return null;
    }
  }

  void clearExpiredCache() {
    final now = DateTime.now();
    _cacheTime.removeWhere((key, time) {
      if (now.difference(time) > _cacheDuration) {
        _colorCache.remove(key);
        return true;
      }
      return false;
    });
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
