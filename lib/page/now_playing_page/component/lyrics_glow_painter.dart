import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// 歌词辉光效果绘制器
///
/// 参考 ZeroBit-Player 的智能辉光系统，适配到 Pure-music 的 CustomPainter 架构
class LyricsGlowPainter {
  // 辉光效果常量（参考 ZeroBit 原版参数，增强 blur 半径）
  static const double glowAlphaMin = 0.2;          // ZeroBit: _glowAlphaMin = 0.2
  static const double glowAlphaExtra = 0.3;        // ZeroBit: _glowAlphaExtra = 0.3
  static const double ripplesScaleMin = 1.1;       // ZeroBit: _ripplesScaleMin = 1.1
  static const double ripplesScaleExtra = 0.1;     // ZeroBit: _ripplesScaleExtra = 0.1
  static const double rippleThreshold = 1.5;       // 缩放阈值（≥1.5s → 单纯缩放）
  static const double glowThreshold = 2.5;         // 辉光阈值（≥2.5s → 缩放+辉光）
  
  // blur 半径（比 ZeroBit 更大，因为 CustomPainter 没有 Widget 层的额外光晕）
  static const double innerBlurRadius = 12.0;      // ZeroBit: 4
  static const double outerBlurRadius = 24.0;      // ZeroBit: 8

  /// 计算辉光强度（基于词的持续时间）
  ///
  /// [durationSeconds] 词的持续时间（秒）
  /// 返回：辉光最大透明度
  static double calculateGlowAlpha(double durationSeconds) {
    if (durationSeconds < rippleThreshold) {
      return 0.0; // 短音节不应用辉光
    }

    // 将 [1.5, 3.0] 区间归一化到 [0.0, 1.0]
    final effectRatio = ((durationSeconds - rippleThreshold) / (3.0 - rippleThreshold))
        .clamp(0.0, 1.0);

    return glowAlphaMin + glowAlphaExtra * effectRatio;
  }

  /// 计算缩放倍数（用于辉光扩散效果）
  ///
  /// [durationSeconds] 词的持续时间（秒）
  /// 返回：缩放最大值
  static double calculateRipplesScale(double durationSeconds) {
    if (durationSeconds < rippleThreshold) {
      return 1.0; // 短音节不缩放
    }

    final effectRatio = ((durationSeconds - rippleThreshold) / (3.0 - rippleThreshold))
        .clamp(0.0, 1.0);

    return ripplesScaleMin + ripplesScaleExtra * effectRatio;
  }

  /// 计算字符的辉光进度（非对称曲线）
  ///
  /// [charProgress] 字符的播放进度 [0.0, 1.0]
  /// 返回：辉光动画曲线值 [0.0, 1.0]
  static double calculateGlowCurve(double charProgress) {
    const animatedRatio = 0.6; // 60% 时间放大，40% 时间缩小

    if (charProgress < animatedRatio) {
      // 前 60% 时间：快速放大（easeOut）
      return Curves.easeOut.transform(charProgress / animatedRatio);
    } else {
      // 后 40% 时间：慢速缩小（easeIn）
      return 1.0 -
          Curves.easeIn.transform(
            (charProgress - animatedRatio) / (1.0 - animatedRatio),
          );
    }
  }

  /// 绘制单个字符的辉光效果
  ///
  /// [canvas] 画布
  /// [text] 字符内容
  /// [offset] 绘制位置
  /// [style] 文本样式
  /// [glowAlpha] 辉光透明度 [0.0, 1.0]
  /// [scale] 缩放倍数
  static void paintCharGlow(
    Canvas canvas,
    String text,
    Offset offset,
    TextStyle style,
    double glowAlpha,
    double scale,
  ) {
    if (glowAlpha < 0.01) return; // 透明度太低，跳过绘制

    final baseColor = style.color ?? Colors.white;

    // 创建辉光样式（字符透明，只显示 Shadow）
    final glowStyle = style.copyWith(
      color: Colors.transparent, // 关键：字符本身必须透明
      shadows: [
        Shadow(
          color: baseColor.withValues(alpha: glowAlpha * 0.6),
          blurRadius: 4.0, // 内层：紧致的核心光
        ),
        Shadow(
          color: baseColor.withValues(alpha: glowAlpha),
          blurRadius: 8.0, // 外层：扩散的光晕
        ),
      ],
    );

    final textPainter = TextPainter(
      text: TextSpan(text: text, style: glowStyle),
      textDirection: TextDirection.ltr,
    );

    textPainter.layout();

    // 应用缩放（以字符底部中心为原点，匹配 ZeroBit 的 Alignment.bottomCenter）
    if (scale != 1.0) {
      canvas.save();
      final centerX = offset.dx + textPainter.width / 2;
      final bottomY = offset.dy + textPainter.height;
      canvas.translate(centerX, bottomY);
      canvas.scale(scale);
      canvas.translate(-centerX, -bottomY);
    }

    textPainter.paint(canvas, offset);

    if (scale != 1.0) {
      canvas.restore();
    }

    textPainter.dispose();
  }

  /// 绘制词的辉光效果（批量优化版本）
  ///
  /// [canvas] 画布
  /// [chars] 字符列表
  /// [offsets] 每个字符的绘制位置
  /// [style] 文本样式
  /// [charProgresses] 每个字符的播放进度
  /// [wordDurationSeconds] 词的总持续时间（秒）
  static void paintWordGlow(
    Canvas canvas,
    List<String> chars,
    List<Offset> offsets,
    TextStyle style,
    List<double> charProgresses,
    double wordDurationSeconds,
  ) {
    if (wordDurationSeconds < rippleThreshold) return; // 短音节跳过

    final maxGlowAlpha = calculateGlowAlpha(wordDurationSeconds);
    final maxScale = calculateRipplesScale(wordDurationSeconds);

    for (int i = 0; i < chars.length; i++) {
      final charProgress = charProgresses[i].clamp(0.0, 1.0);
      if (charProgress <= 0.0) continue; // 未开始的字符跳过

      final animationCurve = calculateGlowCurve(charProgress);
      final glowAlpha = ui.lerpDouble(0.0, maxGlowAlpha, animationCurve)!;
      final scale = ui.lerpDouble(1.0, maxScale, animationCurve)!;

      paintCharGlow(
        canvas,
        chars[i],
        offsets[i],
        style,
        glowAlpha,
        scale,
      );
    }
  }
}
