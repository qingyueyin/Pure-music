import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/lyric_action_state.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/zh_converter.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:provider/provider.dart';

class LyricViewController extends ChangeNotifier {
  static LyricViewController? _instance;

  static LyricViewController get instance {
    _instance ??= LyricViewController._internal();
    return _instance!;
  }

  bool _disposed = false;
  bool _isListening = false;
  bool hasRomanLyric = false;
  bool hasTranslation = false;
  bool hasMultipleAgents = false;
  LyricFormat lyricSource = LyricFormat.local;

  LyricViewController._internal() {
    lyricTextAlign = nowPlayingPagePref.lyricTextAlign;
    lyricFontSize = nowPlayingPagePref.lyricFontSize;
    translationFontSize = nowPlayingPagePref.translationFontSize;
    showLyricTranslation = nowPlayingPagePref.showLyricTranslation;
    lyricFontWeight = nowPlayingPagePref.lyricFontWeight;
    enableLyricBlur = nowPlayingPagePref.enableLyricBlur;
    showLyricRoman = nowPlayingPagePref.showLyricRoman;
    rubyPosition = nowPlayingPagePref.rubyPosition;
    enableLyricScale = nowPlayingPagePref.enableLyricScale;
    enableLyricSpring = nowPlayingPagePref.enableLyricSpring;
    enableLyricGlow = nowPlayingPagePref.enableLyricGlow;

    _listenToLyricChanges();
  }

  void _listenToLyricChanges() {
    if (_isListening) return;
    _isListening = true;
    PlayService.instance.lyricService.addListener(_checkRomanLyric);
    _checkRomanLyric();
  }

  Future<void> _checkRomanLyric() async {
    if (_disposed) return;

    try {
      final lyric = await PlayService.instance.lyricService.currLyricFuture;
      if (_disposed) return;

      bool needsNotify = false;

      final found = lyric?.lines.any(
            (line) => line.romanLyric != null && line.romanLyric!.isNotEmpty,
          ) ??
          false;
      final translationFound = lyricHasTranslation(lyric);

      if (found != hasRomanLyric) {
        hasRomanLyric = found;
        needsNotify = true;
      }
      if (translationFound != hasTranslation) {
        hasTranslation = translationFound;
        needsNotify = true;
      }

      if (lyric != null) {
        final newSource = lyric.source;
        if (newSource != lyricSource) {
          lyricSource = newSource;
          needsNotify = true;
        }

        final agentCount = lyric.uniqueAgentCount;
        final newHasMultipleAgents = agentCount > 1;
        if (newHasMultipleAgents != hasMultipleAgents) {
          hasMultipleAgents = newHasMultipleAgents;
          needsNotify = true;
        }
      }

      // 统一通知，避免多次独立通知导致状态时序不一致
      if (needsNotify && !_disposed) {
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Failed to switch lyric source: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _isListening = false;
    PlayService.instance.lyricService.removeListener(_checkRomanLyric);
    super.dispose();
  }

  final nowPlayingPagePref = AppPreference.instance.nowPlayingPagePref;
  late LyricTextAlign lyricTextAlign;
  late double lyricFontSize;
  late double translationFontSize;
  late   bool showLyricTranslation;
  late bool showLyricRoman;
  late RubyPosition rubyPosition;
  late int lyricFontWeight;
  late bool enableLyricBlur;
  late bool enableLyricScale;
  late bool enableLyricSpring;
  late bool enableLyricGlow;

  LyricRenderConfig get renderConfig =>
      nowPlayingPagePref.lyricRenderConfig.copyWith(
        textAlign: lyricTextAlign,
        baseFontSize: lyricFontSize,
        translationBaseFontSize: translationFontSize,
        showTranslation: showLyricTranslation,
        showRoman: showLyricRoman,
        lineOrder: rubyPosition.toLineOrder(),
        fontWeight: lyricFontWeight,
        enableBlur: enableLyricBlur,
        enableLineScale: enableLyricScale,
        enableLineSpring: enableLyricSpring,
        enableGlow: enableLyricGlow,
        hasMultipleAgents: hasMultipleAgents,
        displayMode: lyricDisplayMode,
      );

  void triggerRebuild() {
    notifyListeners();
  }

  LyricDisplayMode get lyricDisplayMode =>
      AppSettings.instance.lyricDisplayMode;

  ZhConversionMode get zhConversionMode =>
      AppSettings.instance.zhConversionMode;

  void switchLyricTextAlign() {
    lyricTextAlign = switch (lyricTextAlign) {
      LyricTextAlign.left => LyricTextAlign.center,
      LyricTextAlign.center => LyricTextAlign.right,
      LyricTextAlign.right => LyricTextAlign.left,
    };
    nowPlayingPagePref.lyricTextAlign = lyricTextAlign;
    AppPreference.instance.save();
    notifyListeners();
  }

  void increaseFontSize() {
    final nextSize = (lyricFontSize + 2).clamp(16.0, 48.0).toDouble();
    if (nextSize == lyricFontSize) return;
    lyricFontSize = nextSize;
    translationFontSize = lyricFontSize - 4;
    nowPlayingPagePref.lyricFontSize = lyricFontSize;
    nowPlayingPagePref.translationFontSize = translationFontSize;
    AppPreference.instance.save();
    notifyListeners();
  }

  void decreaseFontSize() {
    final nextSize = (lyricFontSize - 2).clamp(16.0, 48.0).toDouble();
    if (nextSize == lyricFontSize) return;
    lyricFontSize = nextSize;
    translationFontSize = lyricFontSize - 4;
    nowPlayingPagePref.lyricFontSize = lyricFontSize;
    nowPlayingPagePref.translationFontSize = translationFontSize;
    AppPreference.instance.save();
    notifyListeners();
  }

  void toggleLyricTranslation() {
    showLyricTranslation = !showLyricTranslation;
    nowPlayingPagePref.showLyricTranslation = showLyricTranslation;
    AppPreference.instance.save();
    notifyListeners();
  }

  void setShowLyricTranslation(bool value) {
    showLyricTranslation = value;
    nowPlayingPagePref.showLyricTranslation = value;
    AppPreference.instance.save();
    notifyListeners();
  }

  void setShowLyricRoman(bool value) {
    showLyricRoman = value;
    nowPlayingPagePref.showLyricRoman = value;
    AppPreference.instance.save();
    notifyListeners();
  }

  void toggleLyricRoman() {
    showLyricRoman = !showLyricRoman;
    nowPlayingPagePref.showLyricRoman = showLyricRoman;
    AppPreference.instance.save();
    notifyListeners();
  }

  void setRubyPosition(RubyPosition position) {
    if (position == rubyPosition) return;
    rubyPosition = position;
    nowPlayingPagePref.rubyPosition = position;
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
    final nextWeight = weight.clamp(100, 900);
    if (nextWeight == lyricFontWeight) return;
    lyricFontWeight = nextWeight;
    nowPlayingPagePref.lyricFontWeight = lyricFontWeight;
    AppPreference.instance.save();
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
}

class LyricViewControls extends StatelessWidget {
  const LyricViewControls({super.key});

  @override
  Widget build(BuildContext context) {
    final lyricViewController = context.watch<LyricViewController>();
    final controls = <Widget>[
      const _LyricTranslationSwitchBtn(),
      if (lyricViewController.hasRomanLyric) const _LyricRomanSwitchBtn(),
      const _LyricBlurSwitchBtn(),
      if (!lyricViewController.hasMultipleAgents) const _LyricAlignSwitchBtn(),
      const _FontSizeBtn(),
      const _FontWeightBtn(),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: _withVerticalSpacing(controls, 8.0),
    );
  }
}

List<Widget> _withVerticalSpacing(List<Widget> children, double spacing) {
  if (children.length < 2) return children;

  return [
    for (var index = 0; index < children.length; index++) ...[
      if (index > 0) SizedBox(height: spacing),
      children[index],
    ],
  ];
}

class _LyricAlignSwitchBtn extends StatelessWidget {
  const _LyricAlignSwitchBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();

    return IconButton(
      onPressed: lyricViewController.switchLyricTextAlign,
      tooltip: '切换歌词对齐方向',
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
            '字号：左键放大 / 右键缩小 (${lyricViewController.lyricFontSize.toStringAsFixed(0)})',
        color: scheme.onSecondaryContainer,
        icon: Text(
          'A',
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
    final available = lyricViewController.hasTranslation;
    final enabled = available && lyricViewController.showLyricTranslation;

    return IconButton(
      onPressed: available ? lyricViewController.toggleLyricTranslation : null,
      tooltip: available
          ? enabled
              ? '歌词翻译：显示'
              : '歌词翻译：隐藏'
          : '当前歌词没有翻译',
      style: IconButton.styleFrom(
        backgroundColor: enabled ? scheme.secondaryContainer : null,
      ),
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
      tooltip: enabled ? '歌词注音：显示' : '歌词注音：隐藏',
      style: IconButton.styleFrom(
        backgroundColor: enabled ? scheme.secondaryContainer : null,
      ),
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
      tooltip: enabled ? '歌词模糊：开启' : '歌词模糊：关闭',
      style: IconButton.styleFrom(
        backgroundColor: enabled ? scheme.secondaryContainer : null,
      ),
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
            '粗细：左键加粗 / 右键减粗 (${lyricViewController.lyricFontWeight}, 生效: $effective)',
        icon: Text(
          'B',
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


