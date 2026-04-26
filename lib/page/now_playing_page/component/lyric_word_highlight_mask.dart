import 'package:flutter/material.dart';

/// 逐词渐变遮罩生成器
/// 采用 ZeroBit-Player 的固定三段式渐变方案：
/// - 高亮区 (0.0 ~ 0.333): alpha=0.9
/// - 过渡区 (0.333 ~ 0.666): alpha=0.4
/// - 透明区 (0.666 ~ 1.0): alpha=0.4
/// 渐变层放大 2-3 倍后，通过 Transform 平移实现动画效果
class LyricWordHighlightMask {
  final double progress;

  const LyricWordHighlightMask({
    required this.progress,
  });

  factory LyricWordHighlightMask.fromMetrics({
    required double progress,
    required double fadeScale,
    required double wordWidth,
    required double wordHeight,
  }) {
    return LyricWordHighlightMask(
      progress: progress,
    );
  }

  bool get shouldHighlight => progress > 0.0;

  /// 固定的三段式渐变 stops
  static const List<double> gradientStops = [0.0, 0.333, 0.666];

  /// 根据当前主题色自动判断使用纯白或纯黑
  /// 深色模式用纯白，浅色模式用纯黑
  /// 对应 Pure-music 的 activeStyle 颜色逻辑
  static List<Color> createGradientColors(ColorScheme scheme) {
    final isDarkMode = scheme.brightness == Brightness.dark;
    final highlightColor = isDarkMode ? Colors.white : Colors.black;
    return [
      highlightColor, // alpha=1.0，已播放区域完全不透明
      highlightColor, // alpha=1.0，过渡区起点
      highlightColor.withValues(alpha: 0.0), // 未播放区域完全透明
    ];
  }

  /// 获取渐变 stops
  List<double> get stops => gradientStops;

  /// 根据单词时长计算遮罩层缩放系数
  /// 对应 ZeroBit-Player 的 scale 逻辑
  static double calcMaskScale(double durationMs) {
    return durationMs >= 1000.0 ? 3.0 : 2.0;
  }
}

/// 渐变层缩放平移变换器
/// 对应 ZeroBit-Player 的 _ScaledTranslateGradientTransform
class ScaledTranslateGradientTransform extends GradientTransform {
  final double dx;
  final double scale;

  const ScaledTranslateGradientTransform({
    required this.dx,
    required this.scale,
  });

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    /// 遮罩层放大后，需要向左平移以在动画开始时覆盖透明区
    /// dx = -0.666 * bounds.width * (1 - progress)
    /// 随着 progress 增大，遮罩逐渐向右移动
    // ignore: deprecated_member_use
    return Matrix4.identity()
      // ignore: deprecated_member_use
      ..scale(scale)
      // ignore: deprecated_member_use
      ..leftTranslate(dx, 0.0, 0.0);
  }
}
