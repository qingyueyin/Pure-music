import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/lyric_action_state.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/lyric/lyric_manual_offset.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/theme.dart';
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

  static void disposeIfInitialized() {
    final controller = _instance;
    if (controller == null) return;
    _instance = null;
    controller.dispose();
  }

  bool _disposed = false;
  bool _isListening = false;
  bool offsetAdjusting = false;
  String? _offsetTrackPath;
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
    enableLyricGlow = nowPlayingPagePref.enableLyricGlow;

    _listenToLyricChanges();
    _offsetTrackPath = PlayService.instance.playbackService.nowPlaying?.path;
    PlayService.instance.playbackService.nowPlayingNotifier.addListener(
      _handleOffsetTrackChanged,
    );
  }

  void _handleOffsetTrackChanged() {
    final path = PlayService.instance.playbackService.nowPlaying?.path;
    if (path == _offsetTrackPath) return;
    _offsetTrackPath = path;
    if (!offsetAdjusting || _disposed) return;
    offsetAdjusting = false;
    notifyListeners();
  }

  void toggleLyricOffsetAdjust() {
    if (_disposed) return;
    if (offsetAdjusting) {
      exitLyricOffsetAdjust();
      return;
    }
    final path = PlayService.instance.playbackService.nowPlaying?.path;
    unawaited(LyricManualOffset.instance.bind(path));
    offsetAdjusting = true;
    notifyListeners();
  }

  /// 退出调整：偏移记在这台电脑上，不写进歌曲文件，并回到歌词设置栏。
  void exitLyricOffsetAdjust() {
    if (!offsetAdjusting || _disposed) return;
    final manual = LyricManualOffset.instance;
    final playing = PlayService.instance.playbackService.nowPlaying?.path;
    if (playing != null && manual.path == playing) {
      manual.setManual(manual.manualMs);
    }
    offsetAdjusting = false;
    notifyListeners();
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

      final found =
          lyric?.lines.any(
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
    PlayService.instance.playbackService.nowPlayingNotifier.removeListener(
      _handleOffsetTrackChanged,
    );
    PlayService.instance.lyricService.removeListener(_checkRomanLyric);
    super.dispose();
  }

  final nowPlayingPagePref = AppPreference.instance.nowPlayingPagePref;
  late LyricTextAlign lyricTextAlign;
  late double lyricFontSize;
  late double translationFontSize;
  late bool showLyricTranslation;
  late bool showLyricRoman;
  late RubyPosition rubyPosition;
  late int lyricFontWeight;
  late bool enableLyricBlur;
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
        enableGlow: enableLyricGlow,
        hasMultipleAgents: hasMultipleAgents,
      );

  void triggerRebuild() {
    notifyListeners();
  }

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
      const _LyricOffsetBtn(),
    ];

    if (lyricViewController.offsetAdjusting) {
      return const _LyricOffsetPanel();
    }
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

Color _lyricControlForeground(ColorScheme scheme) {
  return playerThemeForeground(
    scheme,
    enabled: AppSettings.instance.useMaterialYouForControls,
  );
}

/// 和字号按钮里的「A」同一格。字多时缩小，圆按钮不再被撑宽。
Widget _lyricBarLabel(String label, Color color) {
  return SizedBox(
    width: 32,
    height: 24,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: color,
          fontSize: 16,
        ),
      ),
    ),
  );
}

Color? _lyricControlSelectedBackground(ColorScheme scheme, bool selected) {
  if (!selected) return null;
  if (AppSettings.instance.useMaterialYouForControls) {
    return scheme.secondaryContainer;
  }
  return _lyricControlForeground(scheme).withValues(alpha: 0.18);
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
      color: _lyricControlForeground(scheme),
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
        color: _lyricControlForeground(scheme),
        icon: Text(
          'A',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: _lyricControlForeground(scheme),
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
        backgroundColor: _lyricControlSelectedBackground(scheme, enabled),
      ),
      color: _lyricControlForeground(scheme),
      icon: Icon(Symbols.translate, fill: enabled ? 1 : 0),
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
        backgroundColor: _lyricControlSelectedBackground(scheme, enabled),
      ),
      color: _lyricControlForeground(scheme),
      icon: Icon(Symbols.language, fill: enabled ? 1 : 0),
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
        backgroundColor: _lyricControlSelectedBackground(scheme, enabled),
      ),
      color: _lyricControlForeground(scheme),
      icon: Icon(Symbols.blur_on, fill: enabled ? 1 : 0),
    );
  }
}

class _LyricOffsetBtn extends StatelessWidget {
  const _LyricOffsetBtn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: LyricViewController.instance.toggleLyricOffsetAdjust,
      tooltip: '调整歌词偏移',
      color: _lyricControlForeground(scheme),
      icon: const Icon(Symbols.timer),
    );
  }
}

class _LyricOffsetPanel extends StatelessWidget {
  const _LyricOffsetPanel();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: _withVerticalSpacing(const [
        _SaveOffsetToTagButton(),
        _OffsetNudgeButton(),
        _OffsetResetButton(),
      ], 8.0),
    );
  }
}

class _OffsetNudgeButton extends StatelessWidget {
  const _OffsetNudgeButton();

  @override
  Widget build(BuildContext context) {
    final color = _lyricControlForeground(Theme.of(context).colorScheme);
    return ListenableBuilder(
      listenable: LyricManualOffset.instance,
      builder: (context, _) {
        final ms = LyricManualOffset.instance.manualMs;
        final label = ms == 0 ? '0' : '${ms > 0 ? '+' : ''}$ms';
        return GestureDetector(
          onSecondaryTap: () => LyricManualOffset.instance.add(-100),
          child: IconButton(
            onPressed: () => LyricManualOffset.instance.add(100),
            onLongPress: () => LyricManualOffset.instance.add(50),
            tooltip: '偏移：左键提前 / 右键延后 / 长按微调 ($label)',
            color: color,
            icon: _lyricBarLabel(label, color),
          ),
        );
      },
    );
  }
}

class _OffsetResetButton extends StatelessWidget {
  const _OffsetResetButton();

  @override
  Widget build(BuildContext context) {
    final color = _lyricControlForeground(Theme.of(context).colorScheme);
    return IconButton(
      onPressed: LyricManualOffset.instance.reset,
      tooltip: '重置',
      color: color,
      icon: const Icon(Symbols.restart_alt),
    );
  }
}

class _SaveOffsetToTagButton extends StatefulWidget {
  const _SaveOffsetToTagButton();

  @override
  State<_SaveOffsetToTagButton> createState() => _SaveOffsetToTagButtonState();
}

class _SaveOffsetToTagButtonState extends State<_SaveOffsetToTagButton> {
  var _busy = false;
  var _written = false;

  @override
  void initState() {
    super.initState();
    LyricManualOffset.instance.addListener(_onOffsetChanged);
  }

  @override
  void dispose() {
    LyricManualOffset.instance.removeListener(_onOffsetChanged);
    super.dispose();
  }

  void _onOffsetChanged() {
    if (!_written || !mounted) return;
    setState(() => _written = false);
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    final lyricService = PlayService.instance.lyricService;
    final wroteExternal = lyricService.activeLocalIsExternal == true;
    final result = await lyricService.saveCurrentOffsetToTag();
    if (!mounted) return;
    final error = result.error;
    final keptInPlayer =
        error != null && (error.contains('仍记在播放器里') || error.contains('不用写入'));
    setState(() {
      _busy = false;
      _written = error == null;
    });
    if (error != null) {
      showTextOnSnackBar(
        error,
        variant: keptInPlayer ? ToastVariant.info : ToastVariant.error,
      );
      return;
    }
    showTextOnSnackBar(
      result.deferred
          ? '歌词偏移将在播放结束后写入标签'
          : wroteExternal
          ? '歌词偏移已写入歌词文件'
          : '歌词偏移已写入标签',
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = _lyricControlForeground(Theme.of(context).colorScheme);
    final external =
        PlayService.instance.lyricService.activeLocalIsExternal == true;
    final scheme = Theme.of(context).colorScheme;
    final tooltip = _busy
        ? '正在写入'
        : _written
        ? '已写入'
        : external
        ? '保存到歌词文件'
        : '保存到标签';
    return IconButton(
      onPressed: _busy ? null : () => unawaited(_save()),
      tooltip: tooltip,
      style: IconButton.styleFrom(
        backgroundColor: _lyricControlSelectedBackground(scheme, _written),
      ),
      color: color,
      icon: Icon(Symbols.save, fill: _written ? 1 : 0),
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
            color: _lyricControlForeground(scheme),
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}
