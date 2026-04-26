import 'dart:math';
import 'dart:typed_data';

import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/lyric/lyric.dart';

class WordMarkingUtil {
  static final _emojiRegex = RegExp(
    r'[\u{1F600}-\u{1F64F}\u{1F300}-\u{1F5FF}\u{1F680}-\u{1F6FF}'
    r'\u{1F1E0}-\u{1F1FF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}'
    r'\u{FE00}-\u{FE0F}\u{1F900}-\u{1F9FF}\u{1FA00}-\u{1FA6F}'
    r'\u{1FA70}-\u{1FAFF}\u{200D}]',
    unicode: true,
  );

  static final _punctuationRegex = RegExp(
    r'^[\p{P}\p{S}\s]+$',
    unicode: true,
  );

  static const String _descenderChars = 'gjpqy';

  static bool isEmoji(String text) => _emojiRegex.hasMatch(text);

  static bool isOnlyPunctuation(String text) => _punctuationRegex.hasMatch(text);

  static bool hasDescenderChar(String text) =>
      text.split('').any((c) => _descenderChars.contains(c));

  static bool containsCjk(String text) =>
      RegExp(r'[\u4E00-\u9FFF\u3040-\u30FF\uAC00-\uD7AF]').hasMatch(text);

  static Set<WordMark> analyze(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return const {};

    final marks = <WordMark>{};

    if (isOnlyPunctuation(trimmed)) {
      marks.add(WordMark.punctuation);
      return marks;
    }

    if (isEmoji(trimmed)) {
      marks.add(WordMark.emoji);
    }

    if (hasDescenderChar(trimmed)) {
      marks.add(WordMark.descender);
    }

    if (trimmed.length == 1 && !containsCjk(trimmed)) {
      marks.add(WordMark.singleChar);
    }

    return marks;
  }

  static Set<WordMark> analyzeWithDuration(
    String content,
    int durationMs, {
    int longNoteThresholdMs = 1500,
  }) {
    final marks = analyze(content);

    if (durationMs >= longNoteThresholdMs) {
      marks.add(WordMark.longNote);
    }

    return marks;
  }
}

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

class WordEmphasisHelper {
  static WordEmphasisState resolve({
    required double progress,
    required double baseSize,
    required LyricRenderConfig config,
    SyncLyricWord? word,
    int? characterIndex,
    int? characterCount,
    Float32List? spectrumBands,
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
    final glowIntensity = computeGlowIntensity(
      normalized,
      maxIntensity: config.emphasisGlowIntensity,
    );

    // Audio reactive boost from spectrum
    double audioGlow = 0.0;
    double audioScale = 0.0;
    double audioBlur = 0.0;

    if (spectrumBands != null && spectrumBands.length >= 8) {
      final audioBoost = _computeAudioReactiveBoost(spectrumBands);
      audioGlow = audioBoost['glowAlpha']!;
      audioScale = audioBoost['scale']!;
      audioBlur = audioBoost['glowBlur']!;
    }

    final finalGlowIntensity = min(glowIntensity + audioGlow, 1.0).toDouble();
    final finalScale = computeScale(
      normalized,
      scaleBoost: config.emphasisScaleBoost + audioScale,
    );
    final finalGlowBlur = computeGlowBlur(finalGlowIntensity) + audioBlur;
    final finalGlowAlpha = computeGlowAlpha(finalGlowIntensity);

    return WordEmphasisState(
      yOffset: computeYOffset(
        normalized,
        baseSize,
        maxLift: max(config.emphasisLiftPx, baseSize * 0.05),
        attackRatio: config.emphasisAttackRatio,
        releaseRatio: config.emphasisReleaseRatio,
      ),
      scale: finalScale,
      glowIntensity: finalGlowIntensity,
      glowBlur: finalGlowBlur,
      glowAlpha: finalGlowAlpha,
    );
  }

  static Map<String, double> _computeAudioReactiveBoost(Float32List bands) {
    // 8 bands (logarithmic): 45Hz ~ 16000Hz
    // Band 0:   45~63Hz    (sub-bass)
    // Band 1:   63~200Hz   (bass/drums)
    // Band 2:   200~560Hz  (male voice fundamental + low harmonics)
    // Band 3:   560~1580Hz (female voice fundamental + male harmonics)
    // Band 4:   1580~4450Hz (female voice fundamental)
    // Band 5:   4450~12500Hz (vocal clarity/air)
    // Band 6-7: 12500Hz~    (treble/sibilance)

    // Step 1: energy of each region
    double bassEnergy = bands[0] + bands[1];                        // 45~200Hz
    double maleFundamental = bands[2];                              // 200~560Hz
    double femaleFundamental = bands[3] + bands[4];                  // 560~4450Hz
    double vocalAir = bands[5];                                     // 4450~12500Hz (sibilance)
    double totalVocalEnergy = maleFundamental + femaleFundamental + vocalAir;
    double totalEnergy = bands[0] + bands[1] + totalVocalEnergy + bands[6] + bands[7];

    if (totalEnergy < 0.05) {
      return {'glowAlpha': 0.0, 'scale': 0.0, 'glowBlur': 0.0};
    }

    // Step 2: pitch ratio — determines if voice is high (female) or low (male)
    // If femaleFundamental >> maleFundamental → female voice (high pitch)
    // If maleFundamental dominant → male voice (low pitch)
    final pitchRatio = totalVocalEnergy > 0
        ? femaleFundamental / (totalVocalEnergy + 0.001)
        : 0.5; // default to middle if no vocal detected
    // pitchRatio: 0.0 = pure male/low, 1.0 = pure female/high

    // Step 3: loudness (normalized 0~1)
    final normalizedLoudness = (totalEnergy / 8.0).clamp(0.0, 1.0).toDouble();

    // Step 4: classify
    //   loud = normalizedLoudness > 0.4
    //   high = pitchRatio > 0.5 (female voice dominant)
    //   low  = pitchRatio < 0.35 (male voice dominant)

    // glowAlpha: depends on loudness AND pitch
    // - quiet: no boost (0.0)
    // - loud + high pitch: strongest (+0.3)
    // - loud + low pitch: moderate (+0.1)
    // - loud + mid pitch: medium (+0.15)
    double glowAlpha = 0.0;
    if (normalizedLoudness > 0.4) {
      if (pitchRatio > 0.5) {
        // Female/high voice: bright and strong
        glowAlpha = 0.06 + normalizedLoudness * 0.24; // 0.4→0.156, 1.0→0.30
      } else if (pitchRatio < 0.35) {
        // Male/low voice: warm and moderate
        glowAlpha = 0.04 + normalizedLoudness * 0.06; // 0.4→0.064, 1.0→0.10
      } else {
        // Mid pitch (mixed or instrumental)
        glowAlpha = 0.05 + normalizedLoudness * 0.10; // 0.4→0.09, 1.0→0.15
      }
    }

    // glowBlur: spread depends on pitch (female = wider, male = tighter)
    // High pitch words naturally have more shimmer — give them more blur radius.
    // Low pitch words are grounded — minimal blur.
    double glowBlur = 0.0;
    if (normalizedLoudness > 0.3) {
      // Range: 0.0 (pure male/low) ~ 2.5 (pure female/high)
      final baseBlur = (pitchRatio - 0.35) * 5.0; // 0.35→0, 0.85→2.5
      glowBlur = baseBlur * normalizedLoudness;
    }

    // scale bounce:鼓点/低频瞬时峰值触发
    // bassEnergy peak (bands 0-1) when sudden onset → scale bounce
    double scale = 0.0;
    if (bassEnergy > 0.6) {
      scale = (bassEnergy - 0.6) * 0.20; // 0.6→0.0, 1.0→0.08
    }

    return {
      'glowAlpha': glowAlpha.clamp(0.0, 0.3).toDouble(),
      'scale': scale.clamp(0.0, 0.08).toDouble(),
      'glowBlur': glowBlur.clamp(0.0, 2.5).toDouble(),
    };
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

  static double computeScale(
    double progress, {
    double scaleBoost = 0.0,
  }) {
    final normalized = progress.clamp(0.0, 1.0);
    return 1.0 + sin(normalized * pi) * scaleBoost;
  }

  static double computeGlowIntensity(
    double progress, {
    double maxIntensity = 0.2,
  }) {
    final normalized = progress.clamp(0.0, 1.0);
    return sin(normalized * pi) * maxIntensity;
  }

  static double computeGlowBlur(double glowIntensity) {
    return 1.0 + glowIntensity * 2.0;
  }

  static double computeGlowAlpha(double glowIntensity) {
    if (glowIntensity <= 0.0) return 0.0;
    return 0.06 + glowIntensity * 0.18;
  }

  static double computeRotation(double progress, bool isLongWord) {
    return 0.0;
  }

  static bool shouldEmphasizeWord(SyncLyricWord word) {
    final content = word.content.trim();
    if (content.isEmpty) return false;

    if (word.isPunctuation) return false;

    if (word.isEmoji && content.length <= 2) return false;

    final durationMs = word.length.inMilliseconds;
    if (durationMs < 500) return false;

    if (WordMarkingUtil.containsCjk(content)) return true;

    if (content.length >= 2 && content.length <= 12) return true;

    return durationMs >= 800;
  }
}

class WordProgressSmoother {
  final Map<int, double> _smoothedProgress = {};
  final double smoothingFactor;

  WordProgressSmoother({this.smoothingFactor = 0.3});

  double getSmoothedProgress(int wordIndex, double rawProgress) {
    final previous = _smoothedProgress[wordIndex] ?? rawProgress;
    final smoothed =
        previous * (1 - smoothingFactor) + rawProgress * smoothingFactor;
    _smoothedProgress[wordIndex] = smoothed;
    return smoothed;
  }

  void reset(int wordIndex) {
    _smoothedProgress.remove(wordIndex);
  }

  void resetAll() {
    _smoothedProgress.clear();
  }
}
