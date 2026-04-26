// DOM 风格歌词播放器 - Apple Music 风格歌词实现
//
// 基于 applemusic-like-lyrics 框架的 Dart/Flutter 移植。
//
// 本模块提供弹簧物理动画支持，增强现有的歌词显示效果。

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/dom_lyric_spring.dart';

/// 歌词播放模式
enum LyricLineRenderMode {
  solid,
  karaoke,
}

/// 歌词行数据（DOM 风格）
class DomLyricLineData {
  final List<DomLyricWordData> words;
  final String translatedLyric;
  final String romanLyric;
  final double startTime;
  final double endTime;
  final bool isBG;
  final bool isDuet;

  const DomLyricLineData({
    required this.words,
    this.translatedLyric = '',
    this.romanLyric = '',
    required this.startTime,
    required this.endTime,
    this.isBG = false,
    this.isDuet = false,
  });

  factory DomLyricLineData.fromLyricLine(LyricLine line) {
    List<DomLyricWordData> words = [];

    if (line is SyncLyricLine) {
      words = line.words.map((w) => DomLyricWordData(
        content: w.content,
        startTime: w.start.inMilliseconds.toDouble(),
        endTime: w.start.inMilliseconds + w.length.inMilliseconds.toDouble(),
        romanWord: null,
        obscene: w.obscene,
      )).toList();
    }

    return DomLyricLineData(
      words: words,
      translatedLyric: line.translation ?? '',
      romanLyric: line.romanLyric ?? '',
      startTime: line.start.inMilliseconds.toDouble(),
      endTime: line.start.inMilliseconds + line.length.inMilliseconds.toDouble(),
    );
  }
}

/// 歌词单词数据
class DomLyricWordData {
  final String content;
  final double startTime;
  final double endTime;
  final String? romanWord;
  final bool obscene;
  final List<DomRubyData>? ruby;

  const DomLyricWordData({
    required this.content,
    required this.startTime,
    required this.endTime,
    this.romanWord,
    this.obscene = false,
    this.ruby,
  });
}

/// 注音数据
class DomRubyData {
  final String word;
  final double startTime;
  final double endTime;

  const DomRubyData({
    required this.word,
    required this.startTime,
    required this.endTime,
  });
}

/// 歌词弹簧动画控制器
/// 用于实现 Apple Music 风格的平滑滚动效果
class LyricSpringController extends ChangeNotifier {
  /// Y 位置弹簧
  final Spring posY;

  /// X 位置弹簧
  final Spring posX;

  /// 缩放弹簧
  final Spring scale;

  /// 启用弹簧动画
  bool enabled;

  /// 当前缩放值
  double currentScale;

  LyricSpringController({
    SpringParams? posYParams,
    SpringParams? posXParams,
    SpringParams? scaleParams,
    this.enabled = true,
    this.currentScale = 1.0,
  })  : posY = Spring(params: posYParams),
        posX = Spring(params: posXParams),
        scale = Spring(params: scaleParams);

  /// 设置目标 Y 位置
  void setTargetY(double target, {double delay = 0}) {
    if (!enabled) return;
    posY.setTargetPosition(target, delay: delay);
  }

  /// 设置目标缩放
  void setTargetScale(double target, {double delay = 0}) {
    if (!enabled) return;
    scale.setTargetPosition(target, delay: delay);
  }

  /// 强制设置位置（无动画）
  void forceSetY(double position) {
    posY.setPosition(position);
  }

  /// 强制设置缩放（无动画）
  void forceSetScale(double scaleValue) {
    currentScale = scaleValue;
    scale.setPosition(scaleValue);
  }

  /// 更新时间增量
  /// [dt] - 时间增量（秒）
  void update(double dt) {
    if (!enabled) return;

    posY.update(dt);
    posX.update(dt);
    scale.update(dt);

    currentScale = scale.getCurrentPosition();

    notifyListeners();
  }

  /// 获取当前位置
  double get currentY => posY.getCurrentPosition();

  /// 获取当前缩放
  double get currentScaleValue => currentScale;

  /// 是否已停止
  bool get isAtRest => posY.isAtRest && scale.isAtRest;

}

/// 用于扩展现有歌词行的弹簧动画
class LyricLineSpringMotion extends StatefulWidget {
  final Widget child;
  final LyricSpringController controller;
  final bool enabled;

  const LyricLineSpringMotion({
    super.key,
    required this.child,
    required this.controller,
    this.enabled = true,
  });

  @override
  State<LyricLineSpringMotion> createState() => _LyricLineSpringMotionState();
}

class _LyricLineSpringMotionState extends State<LyricLineSpringMotion>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 16),
    );
    _animController.addListener(_onUpdate);
    _animController.repeat();
  }

  void _onUpdate() {
    if (!widget.enabled) return;
    widget.controller.update(0.016);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, controller.currentY),
          child: Transform.scale(
            scale: controller.currentScaleValue,
            alignment: Alignment.center,
            child: widget.child,
          ),
        );
      },
    );
  }
}

/// 单词淡入淡出 mask 生成器
/// 对应 applemusic-like-lyrics 的 generateFadeGradient
class FadeGradientGenerator {
  /// 生成渐变 mask
  /// [width] - 淡入宽度比例
  /// [padding] - 内边距
  /// [bright] - 高亮颜色
  /// [dark] - 暗淡颜色
  static (String, double) generate({
    required double width,
    double padding = 0,
    String bright = 'rgba(255,255,255,1)',
    String dark = 'rgba(255,255,255,0.2)',
  }) {
    final totalAspect = 2 + width + padding;
    final widthInTotal = width / totalAspect;
    final leftPos = (1 - widthInTotal) / 2;

    final gradient = 'linear-gradient(to right, $bright ${leftPos * 100}%, $dark ${(leftPos + widthInTotal) * 100}%)';

    return (gradient, totalAspect);
  }

  /// 生成 Flutter ShaderMask 用的 stops
  static List<double> generateStops({
    required double progress,
    double fadeScale = 0.5,
  }) {
    final p = progress.clamp(0.0, 1.0);
    final fade = fadeScale.clamp(0.0, 1.0);

    return [
      (p - fade * 2).clamp(0.0, 1.0),
      (p - fade).clamp(0.0, 1.0),
      p.clamp(0.0, 1.0),
      (p + fade).clamp(0.0, 1.0),
    ];
  }
}

/// Descender 字符检测与处理
/// 用于处理 y, p, j, g, q 等下垂字母的渲染间距
/// 支持不同字体、字重、字号下的精确测量
class DescenderUtil {
  /// 需要额外底部的 descender 字符 (Latin + Emoji variants)
  static const String _descenderChars = 'ypjqgQ😂😭';

  /// 检测字符串是否包含 descender 字符
  static bool hasDescender(String text) {
    if (text.isEmpty) return false;
    for (int i = 0; i < text.length; i++) {
      if (_descenderChars.contains(text[i])) {
        return true;
      }
    }
    return false;
  }

  /// 检测单个字符是否为 descender
  static bool isDescenderChar(String char) {
    if (char.isEmpty) return false;
    return _descenderChars.contains(char);
  }

  /// 计算带安全边距的 descender padding
  static double calcDescenderPadding({
    required double fontSize,
    FontWeight? fontWeight,
    bool isEmphasized = false,
    bool hasDescenders = true,
  }) {
    if (!hasDescenders) return 0;

    double baseRatio = 0.18;
    if (fontSize < 16) baseRatio = 0.22;
    if (fontSize > 32) baseRatio = 0.16;

    if (fontWeight != null) {
      final w = fontWeight.value;
      if (w >= 700) {
        baseRatio += 0.025;
      } else if (w >= 500) {
        baseRatio += 0.015;
      }
    }

    double padding = fontSize * baseRatio;
    if (isEmphasized) padding *= 1.35;

    return padding.clamp(2.0, 28.0);
  }

  /// 顶部边距
  static double calcTopPadding({
    required double fontSize,
    bool isEmphasized = false,
  }) {
    if (isEmphasized) return fontSize * 0.18;
    return fontSize * 0.10;
  }

  /// 生成完整 EdgeInsets
  static EdgeInsets calcAllPadding({
    required double fontSize,
    FontWeight? fontWeight,
    bool hasDescenders = true,
    bool isEmphasized = false,
  }) {
    final horizontal = fontSize * (isEmphasized ? 0.06 : 0.025);
    return EdgeInsets.fromLTRB(
      horizontal,
      calcTopPadding(fontSize: fontSize, isEmphasized: isEmphasized),
      horizontal,
      calcDescenderPadding(
        fontSize: fontSize,
        fontWeight: fontWeight,
        isEmphasized: isEmphasized,
        hasDescenders: hasDescenders,
      ),
    );
  }
}

/// 歌词单词动画管理器
/// 使用真实歌词时序 + 帧级插值，消除人为延迟
class LyricWordAnimationManager {
  /// 极短单词的最小可视时长 (毫秒)
  /// 仅对时长为0或接近0的无效数据做兜底
  static const double minValidWordDuration = 50.0;

  /// 高亮保持时间 (毫秒) - 从400降到150，更贴近真实播放
  static const double highlightHoldTime = 150.0;

  /// 渐变宽度比例
  static const double defaultFadeWidth = 0.5;

  /// 计算有效的单词动画时长
  /// 只对无效时长（<=0）做兜底，否则使用真实时长
  static double getEffectiveDuration(double rawDuration) {
    if (rawDuration <= 0) return minValidWordDuration;
    return rawDuration;
  }

  /// 计算单词进度（基于真实时序，不做人为膨胀）
  /// [currentTime] - 当前播放位置 (毫秒)
  /// [wordStart] - 单词开始时间 (毫秒)
  /// [wordEnd] - 单词结束时间 (毫秒)
  static double calcWordProgress(
    double currentTime,
    double wordStart,
    double wordEnd,
  ) {
    final rawDuration = wordEnd - wordStart;
    if (rawDuration <= 0) {
      // 无效时长：瞬间切换
      return currentTime >= wordStart ? 1.0 : 0.0;
    }
    if (currentTime <= wordStart) return 0.0;
    if (currentTime >= wordEnd + highlightHoldTime) return 1.0;
    if (currentTime >= wordEnd) {
      // 在保持阶段：返回1.0
      return 1.0;
    }
    return ((currentTime - wordStart) / rawDuration).clamp(0.0, 1.0);
  }

  /// 计算遮罩层缩放系数
  /// 根据单词时长动态决定遮罩层放大倍数，视觉效果更平滑
  /// 对应 ZeroBit-Player 的 scale 逻辑
  static double calcMaskScale(double durationMs) {
    return durationMs >= 1000.0 ? 3.0 : 2.0;
  }

  /// 计算单词动画的可见进度（用于 ShaderMask）
  /// 包含 fade-in 和 fade-out
  static List<double> calcMaskStops({
    required double progress,
    double fadeScale = 0.5,
  }) {
    final p = progress.clamp(0.0, 1.0);
    final fade = fadeScale.clamp(0.1, 0.8);

    return [
      0.0,
      (p - fade * 0.5).clamp(0.0, 1.0),
      (p).clamp(0.0, 1.0),
      (p + fade).clamp(0.0, 1.0),
      1.0,
    ];
  }

  /// 检查是否为"极短单词"（需要特殊处理）
  static bool isShortWord(String word, double durationMs) {
    return (word.length <= 2 && durationMs < minValidWordDuration * 2);
  }

  /// 获取极短单词的额外放大系数
  /// 让极短单词即使快速略过也有轻微的动画效果
  static double getShortWordScaleBoost(String word, double progress) {
    if (!isShortWord(word, 0)) return 1.0;

    if (progress > 0.2 && progress < 0.8) {
      final boost = (progress - 0.2) / 0.6;
      final sineBoost = (boost < 0.5 ? 2 * boost * boost : 1 - 2 * (1 - boost) * (1 - boost));
      return 1.0 + (sineBoost * 0.08);
    }
    return 1.0;
  }
}

/// 检查是否为逐词歌词
bool isDynamicLyric(List<LyricLine> lines) {
  for (final line in lines) {
    if (line is SyncLyricLine && line.words.isNotEmpty) {
      for (final word in line.words) {
        if (word.length.inMilliseconds > 0) {
          return true;
        }
      }
    }
  }
  return false;
}

/// 检测并返回当前高亮的行索引
int getCurrentLineIndex(List<LyricLine> lines, double positionMs) {
  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];
    final startMs = line.start.inMilliseconds.toDouble();
    final endMs = startMs + line.length.inMilliseconds.toDouble();

    if (positionMs >= startMs && positionMs < endMs) {
      return i;
    }
  }

  for (int i = 0; i < lines.length; i++) {
    if (lines[i].start.inMilliseconds.toDouble() > positionMs) {
      return max(0, i - 1);
    }
  }

  return lines.isEmpty ? 0 : lines.length - 1;
}
