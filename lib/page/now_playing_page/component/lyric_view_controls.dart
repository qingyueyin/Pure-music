import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:provider/provider.dart';

class LyricViewController extends ChangeNotifier {
  static LyricViewController? _instance;

  static LyricViewController get instance {
    _instance ??= LyricViewController._internal();
    return _instance!;
  }

  LyricViewController._internal() {
    lyricTextAlign = nowPlayingPagePref.lyricTextAlign;
    lyricFontSize = nowPlayingPagePref.lyricFontSize;
    translationFontSize = nowPlayingPagePref.translationFontSize;
    showLyricTranslation = nowPlayingPagePref.showLyricTranslation;
    lyricFontWeight = nowPlayingPagePref.lyricFontWeight;
    enableLyricBlur = nowPlayingPagePref.enableLyricBlur;
    showLyricRoman = nowPlayingPagePref.showLyricRoman;
    enableLyricScale = nowPlayingPagePref.enableLyricScale;
    enableLyricSpring = nowPlayingPagePref.enableLyricSpring;
    enableAdvanceLyricTiming = nowPlayingPagePref.enableAdvanceLyricTiming;
    enableWordEmphasis = true;
    enableStaggeredAnimation = true;
    enableAudioReactive = false;
    audioReactiveStrength = 0.5;
    wordFadeWidth = nowPlayingPagePref.wordFadeWidth;
  }

  final nowPlayingPagePref = AppPreference.instance.nowPlayingPagePref;
  late LyricTextAlign lyricTextAlign;
  late double lyricFontSize;
  late double translationFontSize;
  late bool showLyricTranslation;
  late bool showLyricRoman;
  late int lyricFontWeight;
  late bool enableLyricBlur;
  late bool enableLyricScale;
  late bool enableLyricSpring;
  late bool enableAdvanceLyricTiming;
  late bool enableWordEmphasis;
  late bool enableStaggeredAnimation;
  late bool enableAudioReactive;
  late double audioReactiveStrength;
  late double wordFadeWidth;

  LyricRenderConfig get renderConfig =>
      nowPlayingPagePref.lyricRenderConfig.copyWith(
        textAlign: lyricTextAlign,
        baseFontSize: lyricFontSize,
        translationBaseFontSize: translationFontSize,
        showTranslation: showLyricTranslation,
        showRoman: showLyricRoman,
        fontWeight: lyricFontWeight,
        enableBlur: enableLyricBlur,
        enableWordEmphasis: enableWordEmphasis,
        enableLineScale: enableLyricScale,
        enableLineSpring: enableLyricSpring,
        enableStaggeredAnimation: enableStaggeredAnimation,
        enableAudioReactive: enableAudioReactive,
        audioReactiveStrength: audioReactiveStrength,
        wordFadeWidth: wordFadeWidth,
      );

  /// 在左对齐、居中、右对齐之间循环切换
  void switchLyricTextAlign() {
    lyricTextAlign = switch (lyricTextAlign) {
      LyricTextAlign.left => LyricTextAlign.center,
      LyricTextAlign.center => LyricTextAlign.right,
      LyricTextAlign.right => LyricTextAlign.left,
    };

    nowPlayingPagePref.lyricTextAlign = lyricTextAlign;
    notifyListeners();
  }

  void increaseFontSize() {
    if (lyricFontSize >= 48) return;
    lyricFontSize += 2;
    translationFontSize = lyricFontSize - 4; // Sync translation size
    nowPlayingPagePref.lyricFontSize = lyricFontSize;
    nowPlayingPagePref.translationFontSize = translationFontSize;
    AppPreference.instance.save();
    notifyListeners();
  }

  void decreaseFontSize() {
    if (lyricFontSize <= 16) return;
    lyricFontSize -= 2;
    translationFontSize = lyricFontSize - 4; // Sync translation size
    nowPlayingPagePref.lyricFontSize = lyricFontSize;
    nowPlayingPagePref.translationFontSize = translationFontSize;
    AppPreference.instance.save();
    notifyListeners();
  }

  void toggleLyricTranslation() {
    showLyricTranslation = !showLyricTranslation;
    nowPlayingPagePref.showLyricTranslation = showLyricTranslation;
    notifyListeners();
  }

  void toggleLyricBlur() {
    enableLyricBlur = !enableLyricBlur;
    nowPlayingPagePref.enableLyricBlur = enableLyricBlur;
    AppPreference.instance.save();
    notifyListeners();
  }

  void toggleLyricScale() {
    enableLyricScale = !enableLyricScale;
    nowPlayingPagePref.enableLyricScale = enableLyricScale;
    AppPreference.instance.save();
    notifyListeners();
  }

  void toggleLyricSpring() {
    enableLyricSpring = !enableLyricSpring;
    nowPlayingPagePref.enableLyricSpring = enableLyricSpring;
    AppPreference.instance.save();
    notifyListeners();
  }

  void toggleAdvanceLyricTiming() {
    enableAdvanceLyricTiming = !enableAdvanceLyricTiming;
    nowPlayingPagePref.enableAdvanceLyricTiming = enableAdvanceLyricTiming;
    AppPreference.instance.save();
    PlayService.instance.lyricService.recomputeTiming();
    notifyListeners();
  }

  void setFontWeight(int weight) {
    if (weight < 100) weight = 100;
    if (weight > 900) weight = 900;

    lyricFontWeight = weight;
    nowPlayingPagePref.lyricFontWeight = lyricFontWeight;
    notifyListeners();
  }

  void increaseFontWeight({bool smallStep = false}) {
    int step = smallStep ? 10 : 100;
    int newWeight = lyricFontWeight + step;
    setFontWeight(newWeight);
  }

  void decreaseFontWeight({bool smallStep = false}) {
    int step = smallStep ? 10 : 100;
    int newWeight = lyricFontWeight - step;
    setFontWeight(newWeight);
  }

  void toggleWordEmphasis() {
    enableWordEmphasis = !enableWordEmphasis;
    notifyListeners();
  }

  void setWordFadeWidth(double value) {
    final presets = _wordFadeWidthPresets;
    var closest = presets.first;
    var minDistance = double.infinity;
    for (final preset in presets) {
      final distance = (preset - value).abs();
      if (distance < minDistance) {
        minDistance = distance;
        closest = preset;
      }
    }
    wordFadeWidth = closest;
    nowPlayingPagePref.wordFadeWidth = wordFadeWidth;
    AppPreference.instance.save();
    notifyListeners();
  }

  void increaseWordFadeWidth() {
    final presets = _wordFadeWidthPresets;
    final currentIndex = presets.indexOf(wordFadeWidth);
    final nextIndex = (currentIndex + 1).clamp(0, presets.length - 1);
    setWordFadeWidth(presets[nextIndex]);
  }

  void decreaseWordFadeWidth() {
    final presets = _wordFadeWidthPresets;
    final currentIndex = presets.indexOf(wordFadeWidth);
    final previousIndex = (currentIndex - 1).clamp(0, presets.length - 1);
    setWordFadeWidth(presets[previousIndex]);
  }

  static const List<double> _wordFadeWidthPresets = [0.0, 0.5, 1.0];

  void toggleStaggeredAnimation() {
    enableStaggeredAnimation = !enableStaggeredAnimation;
    notifyListeners();
  }

  void toggleAudioReactive() {
    enableAudioReactive = !enableAudioReactive;
    notifyListeners();
  }

  void setAudioReactiveStrength(double strength) {
    audioReactiveStrength = strength.clamp(0.0, 1.0);
    notifyListeners();
  }

  void increaseAudioReactiveStrength() {
    audioReactiveStrength = (audioReactiveStrength + 0.1).clamp(0.0, 1.0);
    notifyListeners();
  }

  void decreaseAudioReactiveStrength() {
    audioReactiveStrength = (audioReactiveStrength - 0.1).clamp(0.0, 1.0);
    notifyListeners();
  }
}

class LyricViewControls extends StatelessWidget {
  const LyricViewControls({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const _LyricTranslationSwitchBtn(),
          SizedBox(height: 8.0),
          const _LyricBlurSwitchBtn(),
          SizedBox(height: 8.0),
          const _LyricAlignSwitchBtn(),
          SizedBox(height: 8.0),
          const _FontSizeBtn(),
          SizedBox(height: 8.0),
          const _FontWeightBtn(),
          SizedBox(height: 8.0),
          const _WordEmphasisSwitchBtn(),
          SizedBox(height: 8.0),
          const _WordFadeWidthBtn(),
          SizedBox(height: 8.0),
          const _StaggeredAnimationSwitchBtn(),
          SizedBox(height: 8.0),
          const _AudioReactiveSwitchBtn(),
        ],
      ),
    );
  }
}

class _LyricAlignSwitchBtn extends StatelessWidget {
  const _LyricAlignSwitchBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();

    return IconButton(
      onPressed: lyricViewController.switchLyricTextAlign,
      tooltip: "切换歌词对齐方向",
      color: scheme.onSecondaryContainer,
      icon: Icon(switch (lyricViewController.lyricTextAlign) {
        LyricTextAlign.left => Symbols.format_align_left,
        LyricTextAlign.center => Symbols.format_align_center,
        LyricTextAlign.right => Symbols.format_align_right,
      }),
    );
  }
}

class _FontSizeBtn extends StatelessWidget {
  const _FontSizeBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();

    return GestureDetector(
      onSecondaryTap: lyricViewController.decreaseFontSize,
      child: IconButton(
        onPressed: lyricViewController.increaseFontSize,
        tooltip:
            "字号：左键放大 / 右键缩小 (${lyricViewController.lyricFontSize.toStringAsFixed(0)})",
        color: scheme.onSecondaryContainer,
        icon: Text(
          "A",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: scheme.onSecondaryContainer,
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}

class _LyricTranslationSwitchBtn extends StatelessWidget {
  const _LyricTranslationSwitchBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();
    final enabled = lyricViewController.showLyricTranslation;

    return IconButton(
      onPressed: lyricViewController.toggleLyricTranslation,
      tooltip: enabled ? "歌词翻译：显示" : "歌词翻译：隐藏",
      color: scheme.onSecondaryContainer,
      icon: Icon(
        Symbols.translate,
        fill: enabled ? 1 : 0,
      ),
    );
  }
}

class _LyricBlurSwitchBtn extends StatelessWidget {
  const _LyricBlurSwitchBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();
    final enabled = lyricViewController.enableLyricBlur;

    return IconButton(
      onPressed: lyricViewController.toggleLyricBlur,
      tooltip: enabled ? "歌词模糊：开启" : "歌词模糊：关闭",
      color: scheme.onSecondaryContainer,
      icon: Icon(
        Symbols.blur_on,
        fill: enabled ? 1 : 0,
      ),
    );
  }
}

class _FontWeightBtn extends StatelessWidget {
  const _FontWeightBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();
    final effective =
        ((lyricViewController.lyricFontWeight / 100).round().clamp(1, 9)) * 100;

    return GestureDetector(
      onSecondaryTap: () => lyricViewController.decreaseFontWeight(),
      child: IconButton(
        onPressed: () => lyricViewController.increaseFontWeight(),
        onLongPress: () =>
            lyricViewController.increaseFontWeight(smallStep: true),
        tooltip:
            "粗细：左键加粗 / 右键减粗 (${lyricViewController.lyricFontWeight}, 生效: $effective)",
        icon: Text(
          "B",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: scheme.onSecondaryContainer,
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}

class _WordEmphasisSwitchBtn extends StatelessWidget {
  const _WordEmphasisSwitchBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();
    final enabled = lyricViewController.enableWordEmphasis;

    return IconButton(
      onPressed: lyricViewController.toggleWordEmphasis,
      tooltip: enabled ? "逐字强调：开启" : "逐字强调：关闭",
      color: scheme.onSecondaryContainer,
      icon: Icon(
        Symbols.text_fields,
        fill: enabled ? 1 : 0,
      ),
    );
  }
}

class _WordFadeWidthBtn extends StatelessWidget {
  const _WordFadeWidthBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();

    return GestureDetector(
      onSecondaryTap: lyricViewController.decreaseWordFadeWidth,
      child: IconButton(
        onPressed: lyricViewController.increaseWordFadeWidth,
        tooltip:
            "逐词渐变宽度：左键增加 / 右键减小 (${lyricViewController.wordFadeWidth.toStringAsFixed(2)})",
        color: scheme.onSecondaryContainer,
        icon: Icon(Symbols.gradient),
      ),
    );
  }
}

class _StaggeredAnimationSwitchBtn extends StatelessWidget {
  const _StaggeredAnimationSwitchBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();
    final enabled = lyricViewController.enableStaggeredAnimation;

    return IconButton(
      onPressed: lyricViewController.toggleStaggeredAnimation,
      tooltip: enabled ? "交错动画：开启" : "交错动画：关闭",
      color: scheme.onSecondaryContainer,
      icon: Icon(
        Symbols.animation,
        fill: enabled ? 1 : 0,
      ),
    );
  }
}

class _AudioReactiveSwitchBtn extends StatelessWidget {
  const _AudioReactiveSwitchBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();
    final enabled = lyricViewController.enableAudioReactive;

    return GestureDetector(
      onSecondaryTap: lyricViewController.decreaseAudioReactiveStrength,
      child: IconButton(
        onPressed: lyricViewController.increaseAudioReactiveStrength,
        tooltip: enabled
            ? "音频响应：开启 (强度: ${(lyricViewController.audioReactiveStrength * 100).toStringAsFixed(0)}%)"
            : "音频响应：关闭",
        color: scheme.onSecondaryContainer,
        icon: Icon(
          Symbols.graphic_eq,
          fill: enabled ? 1 : 0,
        ),
      ),
    );
  }
}
