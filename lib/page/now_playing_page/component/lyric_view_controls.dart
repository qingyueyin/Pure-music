import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
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
  LyricFormat lyricSource = LyricFormat.local;

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
          ) ?? false;

      if (found != hasRomanLyric) {
        hasRomanLyric = found;
        needsNotify = true;
      }

      if (lyric != null) {
        final newSource = lyric.source;
        if (newSource != lyricSource) {
          lyricSource = newSource;
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
  late bool showLyricTranslation;
  late bool showLyricRoman;
  late int lyricFontWeight;
  late bool enableLyricBlur;
  late bool enableLyricScale;
  late bool enableLyricSpring;

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

  LyricDisplayMode get lyricDisplayMode =>
      lyricSource == LyricFormat.web
          ? AppSettings.instance.lyricDisplayMode
          : LyricDisplayMode.enhanced;

  ZhConversionMode get zhConversionMode =>
      lyricSource == LyricFormat.web
          ? AppSettings.instance.zhConversionMode
          : ZhConversionMode.none;

  bool get removeEmptyLines => lyricSource == LyricFormat.web
      ? AppSettings.instance.removeEmptyLines
      : false;

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
}

class LyricViewControls extends StatelessWidget {
  const LyricViewControls({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const _LyricTranslationSwitchBtn(),
        const SizedBox(height: 8.0),
        Consumer<LyricViewController>(
          builder: (context, c, _) => Visibility(
            visible: c.hasRomanLyric,
            child: const _LyricRomanSwitchBtn(),
          ),
        ),
        const SizedBox(height: 8.0),
        const _LyricBlurSwitchBtn(),
        const SizedBox(height: 8.0),
        const _LyricAlignSwitchBtn(),
        const SizedBox(height: 8.0),
        const _FontSizeBtn(),
        const SizedBox(height: 8.0),
        const _FontWeightBtn(),
      ],
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
    final enabled = lyricViewController.showLyricTranslation;

    return IconButton(
      onPressed: lyricViewController.toggleLyricTranslation,
      tooltip: enabled ? '歌词翻译：显示' : '歌词翻译：隐藏',
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
      tooltip: enabled ? '歌词罗马音：显示' : '歌词罗马音：隐藏',
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
