import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/zh_converter.dart';
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

    final settings = AppSettings.instance;
    lyricDisplayMode = settings.lyricDisplayMode;
    zhConversionMode = settings.zhConversionMode;
    removeEmptyLines = settings.removeEmptyLines;
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

  late LyricDisplayMode lyricDisplayMode;
  late ZhConversionMode zhConversionMode;
  late bool removeEmptyLines;

  LyricRenderConfig get renderConfig =>
      nowPlayingPagePref.lyricRenderConfig.copyWith(
        textAlign: lyricTextAlign,
        baseFontSize: lyricFontSize,
        translationBaseFontSize: translationFontSize,
        showTranslation: showLyricTranslation,
        showRoman: showLyricRoman,
        fontWeight: lyricFontWeight,
        enableBlur: enableLyricBlur,
        enableLineScale: enableLyricScale,
        enableLineSpring: enableLyricSpring,
      );

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
    translationFontSize = lyricFontSize - 4;
    nowPlayingPagePref.lyricFontSize = lyricFontSize;
    nowPlayingPagePref.translationFontSize = translationFontSize;
    AppPreference.instance.save();
    notifyListeners();
  }

  void decreaseFontSize() {
    if (lyricFontSize <= 16) return;
    lyricFontSize -= 2;
    translationFontSize = lyricFontSize - 4;
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

  void toggleLyricRoman() {
    showLyricRoman = !showLyricRoman;
    nowPlayingPagePref.showLyricRoman = showLyricRoman;
    AppPreference.instance.save();
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

  void cycleLyricDisplayMode() {
    lyricDisplayMode = switch (lyricDisplayMode) {
      LyricDisplayMode.plain => LyricDisplayMode.verbatim,
      LyricDisplayMode.verbatim => LyricDisplayMode.enhanced,
      LyricDisplayMode.enhanced => LyricDisplayMode.plain,
    };
    final settings = AppSettings.instance;
    settings.lyricDisplayMode = lyricDisplayMode;
    settings.saveSettings();
    notifyListeners();
  }

  void cycleZhConversionMode() {
    zhConversionMode = switch (zhConversionMode) {
      ZhConversionMode.none => ZhConversionMode.traditionalToSimplified,
      ZhConversionMode.traditionalToSimplified => ZhConversionMode.simplifiedToTraditional,
      ZhConversionMode.simplifiedToTraditional => ZhConversionMode.none,
    };
    final settings = AppSettings.instance;
    settings.zhConversionMode = zhConversionMode;
    settings.saveSettings();
    notifyListeners();
  }

  void toggleRemoveEmptyLines() {
    removeEmptyLines = !removeEmptyLines;
    final settings = AppSettings.instance;
    settings.removeEmptyLines = removeEmptyLines;
    settings.saveSettings();
    notifyListeners();
  }
}

class LyricViewControls extends StatelessWidget {
  const LyricViewControls({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const _LyricDisplayModeBtn(),
        SizedBox(height: 8.0),
        const _ZhConversionBtn(),
        SizedBox(height: 8.0),
        const _RemoveEmptyLinesBtn(),
        SizedBox(height: 8.0),
        const _LyricTranslationSwitchBtn(),
        SizedBox(height: 8.0),
        const _LyricRomanSwitchBtn(),
        SizedBox(height: 8.0),
        const _LyricBlurSwitchBtn(),
        SizedBox(height: 8.0),
        const _LyricAlignSwitchBtn(),
        SizedBox(height: 8.0),
        const _FontSizeBtn(),
        SizedBox(height: 8.0),
        const _FontWeightBtn(),
      ],
    );
  }
}

class _LyricDisplayModeBtn extends StatelessWidget {
  const _LyricDisplayModeBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();
    final mode = lyricViewController.lyricDisplayMode;

    final modeLabel = switch (mode) {
      LyricDisplayMode.plain => '纯原文',
      LyricDisplayMode.verbatim => '原文+音',
      LyricDisplayMode.enhanced => '完整',
    };

    return IconButton(
      onPressed: lyricViewController.cycleLyricDisplayMode,
      tooltip: '歌词模式：$modeLabel（左键切换）',
      color: scheme.onSecondaryContainer,
      icon: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.article, size: 20),
          Text(
            modeLabel,
            style: TextStyle(fontSize: 8, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _ZhConversionBtn extends StatelessWidget {
  const _ZhConversionBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();
    final mode = lyricViewController.zhConversionMode;

    final modeLabel = switch (mode) {
      ZhConversionMode.none => '不转换',
      ZhConversionMode.traditionalToSimplified => '繁转简',
      ZhConversionMode.simplifiedToTraditional => '简转繁',
    };

    return IconButton(
      onPressed: lyricViewController.cycleZhConversionMode,
      tooltip: '简繁转换：$modeLabel（左键切换）',
      color: scheme.onSecondaryContainer,
      icon: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.translate, size: 20),
          Text(
            modeLabel == '不转换' ? '简繁' : modeLabel,
            style: TextStyle(fontSize: 8, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _RemoveEmptyLinesBtn extends StatelessWidget {
  const _RemoveEmptyLinesBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();
    final enabled = lyricViewController.removeEmptyLines;

    return IconButton(
      onPressed: lyricViewController.toggleRemoveEmptyLines,
      tooltip: enabled ? '空行过滤：开启' : '空行过滤：关闭',
      color: scheme.onSecondaryContainer,
      icon: Icon(
        Symbols.format_line_spacing,
        fill: enabled ? 1 : 0,
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

class _LyricRomanSwitchBtn extends StatelessWidget {
  const _LyricRomanSwitchBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();
    final enabled = lyricViewController.showLyricRoman;

    return IconButton(
      onPressed: lyricViewController.toggleLyricRoman,
      tooltip: enabled ? "歌词罗马音：显示" : "歌词罗马音：隐藏",
      color: scheme.onSecondaryContainer,
      icon: Icon(
        Symbols.language,
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
