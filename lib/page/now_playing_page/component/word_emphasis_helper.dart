import 'dart:math';
import 'dart:typed_data';

import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/lyric/lyric.dart';

class WordEmphasisState {
  final double yOffset;
  final double scale;
  final double glowIntensity;
  final double glowBlur;
  final double glowAlpha;

  const WordEmphasisState({
    required this.yOffset,
    required this.scale,
    required this.glowIntensity,
    required this.glowBlur,
    required this.glowAlpha,
  });

  static const neutral = WordEmphasisState(
    yOffset: 0.0,
    scale: 1.0,
    glowIntensity: 0.0,
    glowBlur: 0.0,
    glowAlpha: 0.0,
  );
}

class WordAudioReactiveState {
  final double lowEnergy;
  final double highEnergy;
  final double balance;
  final double intensity;

  const WordAudioReactiveState({
    required this.lowEnergy,
    required this.highEnergy,
    required this.balance,
    required this.intensity,
  });

  static const neutral = WordAudioReactiveState(
    lowEnergy: 0.0,
    highEnergy: 0.0,
    balance: 0.0,
    intensity: 0.0,
  );
}

/// 逐字强调动画参数计算器
class WordEmphasisHelper {
  static WordEmphasisState resolve({
    required double progress,
    required double baseSize,
    required LyricRenderConfig config,
    SyncLyricWord? word,
    Float32List? spectrumBands,
    int? characterIndex,
    int? characterCount,
  }) {
    if (!config.shouldApplyWordEmphasis ||
        (word != null && !shouldEmphasizeWord(word))) {
      return WordEmphasisState.neutral;
    }

    final normalized = _applyCharacterPhase(
      progress.clamp(0.0, 1.0).toDouble(),
      characterIndex: characterIndex,
      characterCount: characterCount,
    );
    final audioReactive = _resolveAudioReactive(
      spectrumBands: spectrumBands,
      config: config,
    );
    final glowIntensity = computeGlowIntensity(
          normalized,
          maxIntensity: config.emphasisGlowIntensity,
        ) +
        audioReactive.intensity *
            (0.05 + max(0.0, audioReactive.balance) * 0.05);
    final baseLift = computeYOffset(
      normalized,
      baseSize,
      maxLift: max(config.emphasisLiftPx, baseSize * 0.05),
      attackRatio: config.emphasisAttackRatio,
      releaseRatio: config.emphasisReleaseRatio,
    );
    final reactiveLift = audioReactive.intensity *
        baseSize *
        (0.02 + max(0.0, audioReactive.balance) * 0.012);

    return WordEmphasisState(
      yOffset: baseLift - reactiveLift,
      scale: computeScale(
        normalized,
        scaleBoost: config.emphasisScaleBoost +
            audioReactive.intensity *
                (0.008 + max(0.0, audioReactive.balance) * 0.012),
      ),
      glowIntensity: glowIntensity,
      glowBlur: computeGlowBlur(
        glowIntensity +
            audioReactive.intensity *
                (0.04 + max(0.0, -audioReactive.balance) * 0.08),
      ),
      glowAlpha: computeGlowAlpha(glowIntensity),
    );
  }

  static WordAudioReactiveState _resolveAudioReactive({
    required Float32List? spectrumBands,
    required LyricRenderConfig config,
  }) {
    if (!config.enableAudioReactive ||
        spectrumBands == null ||
        spectrumBands.length < 7) {
      return WordAudioReactiveState.neutral;
    }

    double avg(int start, int end) {
      final clampedStart = start.clamp(0, spectrumBands.length - 1);
      final clampedEnd = end.clamp(clampedStart, spectrumBands.length - 1);
      var sum = 0.0;
      var count = 0;
      for (var i = clampedStart; i <= clampedEnd; i++) {
        sum += spectrumBands[i];
        count++;
      }
      return count == 0 ? 0.0 : sum / count;
    }

    final low = avg(1, 3);
    final high = avg(4, 6);
    final intensity = max(low, high) * config.audioReactiveStrength;
    final balance = (high - low).clamp(-1.0, 1.0);
    return WordAudioReactiveState(
      lowEnergy: low,
      highEnergy: high,
      balance: balance,
      intensity: intensity,
    );
  }

  static double _applyCharacterPhase(
    double progress, {
    int? characterIndex,
    int? characterCount,
  }) {
    if (characterIndex == null ||
        characterCount == null ||
        characterCount <= 1) {
      return progress;
    }
    final center = (characterCount - 1) / 2.0;
    final offset = (characterIndex - center) * 0.08;
    return (progress - offset).clamp(0.0, 1.0).toDouble();
  }

  /// 计算字词的 Y 轴抬升偏移
  /// progress: 0.0 ~ 1.0，表示字词演唱进度
  /// baseSize: 基础字体大小
  static double computeYOffset(
    double progress,
    double baseSize, {
    double maxLift = 0.5,
    double attackRatio = 0.3,
    double releaseRatio = 0.3,
  }) {
    final normalized = progress.clamp(0.0, 1.0);
    final sustainEnd = (1.0 - releaseRatio).clamp(attackRatio, 1.0);

    if (normalized < attackRatio) {
      final t = attackRatio <= 0 ? 1.0 : normalized / attackRatio;
      return -maxLift * sin(t * pi / 2);
    } else if (normalized < sustainEnd) {
      return -maxLift;
    } else {
      final releaseSpan = max(1.0 - sustainEnd, 1e-6);
      final t = (normalized - sustainEnd) / releaseSpan;
      return -maxLift * cos(t * pi / 2);
    }
  }

  /// 计算字词的缩放因子
  /// progress: 0.0 ~ 1.0
  static double computeScale(
    double progress, {
    double scaleBoost = 0.0,
  }) {
    final normalized = progress.clamp(0.0, 1.0);
    return 1.0 + sin(normalized * pi) * scaleBoost;
  }

  /// 计算发光强度（基于进度）
  /// progress: 0.0 ~ 1.0
  static double computeGlowIntensity(
    double progress, {
    double maxIntensity = 0.2,
  }) {
    final normalized = progress.clamp(0.0, 1.0);
    return sin(normalized * pi) * maxIntensity;
  }

  /// 计算发光模糊半径
  static double computeGlowBlur(double glowIntensity) {
    return 1.0 + glowIntensity * 2.0;
  }

  /// 计算发光透明度
  static double computeGlowAlpha(double glowIntensity) {
    if (glowIntensity <= 0.0) return 0.0;
    return 0.06 + glowIntensity * 0.18;
  }

  /// 计算字词的旋转角度
  static double computeRotation(double progress, bool isLongWord) {
    return 0.0;
  }

  static bool shouldEmphasizeWord(SyncLyricWord word) {
    final durationMs = word.length.inMilliseconds;
    if (durationMs < 1000) return false;

    final content = word.content.trim();
    if (content.isEmpty) return false;
    if (_containsCjk(content)) return true;

    return content.length > 1 && content.length <= 7;
  }

  static bool _containsCjk(String text) {
    return RegExp(r'[\u4E00-\u9FFF\u3040-\u30FF\uAC00-\uD7AF]').hasMatch(text);
  }
}

/// 字词进度平滑器 - 使用指数移动平均 (EMA) 减少抖动
class WordProgressSmoother {
  final Map<int, double> _smoothedProgress = {};
  final double smoothingFactor;

  WordProgressSmoother({this.smoothingFactor = 0.3});

  /// 获取平滑后的进度值
  /// wordIndex: 字词索引
  /// rawProgress: 原始进度 (0.0 - 1.0)
  double getSmoothedProgress(int wordIndex, double rawProgress) {
    final previous = _smoothedProgress[wordIndex] ?? rawProgress;
    final smoothed =
        previous * (1 - smoothingFactor) + rawProgress * smoothingFactor;
    _smoothedProgress[wordIndex] = smoothed;
    return smoothed;
  }

  /// 重置指定字词的进度
  void reset(int wordIndex) {
    _smoothedProgress.remove(wordIndex);
  }

  /// 重置所有进度
  void resetAll() {
    _smoothedProgress.clear();
  }
}
