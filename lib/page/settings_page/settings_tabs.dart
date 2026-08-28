import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/desktop_lyric_colors.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/setting_action_state.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_lifecycle.dart';
import 'package:pure_music/core/zh_converter.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/native/rust/api/installed_font.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/lyric/lyric_tag_word_format.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/component/stacked_list_view.dart'
    show SmoothScrollListView;
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/taskbar_thumbnail_service.dart';
import 'package:pure_music/play_service/desktop_lyric_service.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/page/settings_page/check_update.dart';
import 'package:pure_music/page/settings_page/create_issue.dart';
import 'package:pure_music/page/settings_page/artist_separator_editor.dart';
import 'package:pure_music/page/settings_page/settings_group_entry.dart';
import 'package:pure_music/page/settings_page/other_settings.dart'
    show AudioEchoLogRecordControl, ReplayGainControl, TransitionControl;
import 'package:pure_music/native/rust/api/utils.dart' as rust_utils;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:github/github.dart' as gh;
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;
import 'package:pure_music/core/paths.dart' as app_paths;

class SettingsTabs extends StatefulWidget {
  const SettingsTabs({super.key});

  @override
  State<SettingsTabs> createState() => _SettingsTabsState();
}

class _SettingsTabsState extends State<SettingsTabs> {
  int _currentIndex = 0;

  static const _tabs = [
    _SettingsTab('外观', Symbols.palette),
    _SettingsTab('歌词', Symbols.lyrics),
    _SettingsTab('播放', Symbols.play_circle),
    _SettingsTab('桌面歌词', Symbols.desktop_windows),
    _SettingsTab('高级', Symbols.settings),
    _SettingsTab('关于', Symbols.info),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8.0,
          runSpacing: 8.0,
          children: List.generate(_tabs.length, (i) {
            final selected = _currentIndex == i;
            final canSwitch = canSwitchTab(
              currentIndex: _currentIndex,
              targetIndex: i,
            );
            return OutlinedButton.icon(
              onPressed: canSwitch
                  ? () => setState(() => _currentIndex = i)
                  : null,
              icon: Icon(_tabs[i].icon, size: 18),
              label: Text(_tabs[i].label),
              style: ButtonStyle(
                foregroundColor: WidgetStatePropertyAll(
                  selected ? scheme.onSecondaryContainer : scheme.onSurface,
                ),
                backgroundColor: WidgetStatePropertyAll(
                  selected
                      ? scheme.secondaryContainer
                      : scheme.surfaceContainerHighest,
                ),
                side: WidgetStatePropertyAll(
                  BorderSide(color: selected ? scheme.primary : scheme.outline),
                ),
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
                ),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 24.0),
        Expanded(
          child: DirectionalTabView(
            index: _currentIndex,
            children: const [
              _AppearanceTabContent(),
              _LyricsTabContent(),
              _PlaybackTabContent(),
              _DesktopLyricTabContent(),
              _AdvancedTabContent(),
              _AboutTabContent(),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsTab {
  final String label;
  final IconData icon;
  const _SettingsTab(this.label, this.icon);
}

class _AppearanceTabContent extends StatelessWidget {
  const _AppearanceTabContent();

  @override
  Widget build(BuildContext context) {
    return const SmoothScrollListView(
      padding: EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        _GroupEntry(
          icon: Symbols.palette,
          title: '主题',
          subtitle: '明暗模式、主题色与配色来源',
          groupId: 'appearance-theme',
        ),
        SizedBox(height: 8.0),
        _GroupEntry(
          icon: Symbols.wallpaper,
          title: '应用背景',
          subtitle: '背景图片、强度与模糊',
          groupId: 'appearance-background',
        ),
        SizedBox(height: 8.0),
        _GroupEntry(
          icon: Symbols.view_agenda,
          title: '界面动效',
          subtitle: '滚动、交互与内容过渡',
          groupId: 'appearance-list',
        ),
        SizedBox(height: 8.0),
        _GroupEntry(
          icon: Symbols.auto_awesome,
          title: '播放界面',
          subtitle: '进度条、歌词动画与控件配色',
          groupId: 'appearance-player',
        ),
      ],
    );
  }
}

class _ThemeOptionControl extends StatefulWidget {
  const _ThemeOptionControl();

  @override
  State<_ThemeOptionControl> createState() => _ThemeOptionControlState();
}

class _ThemeOptionControlState extends State<_ThemeOptionControl> {
  final settings = AppSettings.instance;
  Future<void> _setThemeOption(ThemeOption option) async {
    if (option == settings.themeOption) return;
    setState(() => settings.themeOption = option);
    ThemeProvider.instance.applyThemeOption(option);
    await settings.saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '明暗模式',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<ThemeOption>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeOption.system, label: Text('跟随系统')),
              ButtonSegment(value: ThemeOption.light, label: Text('浅色模式')),
              ButtonSegment(value: ThemeOption.dark, label: Text('深色模式')),
            ],
            selected: {settings.themeOption},
            onSelectionChanged: (selected) => _setThemeOption(selected.first),
          ),
        ],
      ),
    );
  }
}

class _ThemeColorModeControl extends StatefulWidget {
  const _ThemeColorModeControl();

  @override
  State<_ThemeColorModeControl> createState() => _ThemeColorModeControlState();
}

class _ThemeColorModeControlState extends State<_ThemeColorModeControl> {
  final settings = AppSettings.instance;
  bool _updating = false;

  Future<void> _setColorMode(ThemeColorMode mode) async {
    if (_updating || mode == settings.themeColorMode) return;
    final previous = settings.themeColorMode;
    setState(() {
      _updating = true;
      settings.themeColorMode = mode;
    });
    ThemeProvider.instance.applyThemeColorMode(mode);
    try {
      if (!await settings.saveSettings()) {
        settings.themeColorMode = previous;
        ThemeProvider.instance.applyThemeColorMode(previous);
        if (mounted) {
          showTextOnSnackBar('配色设置保存失败', variant: ToastVariant.error);
        }
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '配色方式',
      subtitle: settings.themeColorMode == ThemeColorMode.independent
          ? '直接使用主题色'
          : '按 MD3 规则生成配色',
      action: SegmentedButton<ThemeColorMode>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: ThemeColorMode.material3, label: Text('MD3')),
          ButtonSegment(value: ThemeColorMode.independent, label: Text('独立')),
        ],
        selected: {settings.themeColorMode},
        onSelectionChanged: _updating
            ? null
            : (selected) => _setColorMode(selected.first),
      ),
    );
  }
}

class _AppBackgroundControl extends StatefulWidget {
  const _AppBackgroundControl();

  @override
  State<_AppBackgroundControl> createState() => _AppBackgroundControlState();
}

class _AppBackgroundControlState extends State<_AppBackgroundControl> {
  final settings = AppSettings.instance;
  bool _updating = false;
  double? _opacityBeforeDrag;
  double? _blurBeforeDrag;

  Future<void> _pickImage() async {
    if (_updating) return;
    setState(() => _updating = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      final selectedPath = result == null || result.files.isEmpty
          ? null
          : result.files.single.path;
      if (selectedPath == null || !mounted) return;

      final previous = settings.appBackgroundImagePath;
      settings.appBackgroundImagePath = selectedPath;
      AppSettings.backgroundNotifier.rebuild();
      setState(() {});
      if (!await settings.saveSettings()) {
        settings.appBackgroundImagePath = previous;
        AppSettings.backgroundNotifier.rebuild();
        if (mounted) {
          setState(() {});
          showTextOnSnackBar('背景图片保存失败', variant: ToastVariant.error);
        }
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _clearImage() async {
    final previous = settings.appBackgroundImagePath;
    if (previous == null || _updating) return;
    setState(() => _updating = true);
    settings.appBackgroundImagePath = null;
    AppSettings.backgroundNotifier.rebuild();
    try {
      if (!await settings.saveSettings()) {
        settings.appBackgroundImagePath = previous;
        AppSettings.backgroundNotifier.rebuild();
        if (mounted) {
          showTextOnSnackBar('背景设置保存失败', variant: ToastVariant.error);
        }
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  void _setOpacity(double value) {
    if (_updating) return;
    _opacityBeforeDrag ??= settings.appBackgroundImageOpacity;
    setState(() => settings.appBackgroundImageOpacity = value);
    AppSettings.backgroundNotifier.rebuild();
  }

  Future<void> _saveOpacity(double value) async {
    final previous = _opacityBeforeDrag;
    _opacityBeforeDrag = null;
    if (previous == null) return;
    setState(() => _updating = true);
    try {
      if (await settings.saveSettings()) return;
      settings.appBackgroundImageOpacity = previous;
      AppSettings.backgroundNotifier.rebuild();
      if (mounted) {
        showTextOnSnackBar('背景强度保存失败', variant: ToastVariant.error);
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  void _setBlur(double value) {
    if (_updating) return;
    _blurBeforeDrag ??= settings.appBackgroundImageBlur;
    setState(() => settings.appBackgroundImageBlur = value);
    AppSettings.backgroundNotifier.rebuild();
  }

  Future<void> _saveBlur(double value) async {
    final previous = _blurBeforeDrag;
    _blurBeforeDrag = null;
    if (previous == null) return;
    setState(() => _updating = true);
    try {
      if (await settings.saveSettings()) return;
      settings.appBackgroundImageBlur = previous;
      AppSettings.backgroundNotifier.rebuild();
      if (mounted) {
        showTextOnSnackBar('背景模糊保存失败', variant: ToastVariant.error);
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final imagePath = settings.appBackgroundImagePath;
    return Column(
      children: [
        SettingsTile(
          description: '背景图片',
          subtitle: imagePath == null ? '使用当前主题背景' : path.basename(imagePath),
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '选择背景图片',
                onPressed: _updating ? null : _pickImage,
                icon: _updating
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Symbols.wallpaper),
              ),
              IconButton(
                tooltip: '恢复默认背景',
                onPressed: imagePath == null || _updating ? null : _clearImage,
                icon: const Icon(Symbols.restart_alt),
              ),
            ],
          ),
        ),
        if (imagePath != null) ...[
          const SizedBox(height: 16),
          SettingsTile(
            description: '背景强度',
            subtitle: '${(settings.appBackgroundImageOpacity * 100).round()}%',
            action: SizedBox(
              width: 160,
              child: Slider(
                value: settings.appBackgroundImageOpacity,
                min: 0.1,
                max: 0.6,
                divisions: 10,
                label: '${(settings.appBackgroundImageOpacity * 100).round()}%',
                onChanged: _updating ? null : _setOpacity,
                onChangeEnd: _updating ? null : _saveOpacity,
              ),
            ),
          ),
          const SizedBox(height: 16),
          SettingsTile(
            description: '背景模糊',
            subtitle: settings.appBackgroundImageBlur == 0
                ? '不模糊'
                : '${settings.appBackgroundImageBlur.round()}',
            action: SizedBox(
              width: 160,
              child: Slider(
                value: settings.appBackgroundImageBlur,
                min: 0,
                max: 30,
                divisions: 15,
                label: settings.appBackgroundImageBlur == 0
                    ? '不模糊'
                    : '${settings.appBackgroundImageBlur.round()}',
                onChanged: _updating ? null : _setBlur,
                onChangeEnd: _updating ? null : _saveBlur,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _MonetProgressBarSwitch extends StatefulWidget {
  const _MonetProgressBarSwitch();

  @override
  State<_MonetProgressBarSwitch> createState() =>
      _MonetProgressBarSwitchState();
}

class _MonetProgressBarSwitchState extends State<_MonetProgressBarSwitch> {
  final settings = AppSettings.instance;

  Future<void> _setEnabled(bool value) async {
    setState(() => settings.useMaterialYouForProgressBar = value);
    await settings.saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '进度条',
      subtitle: '进度条使用主题色渲染',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: settings.useMaterialYouForProgressBar,
            onChanged: _setEnabled,
          ),
        ],
      ),
    );
  }
}

enum _MotionEffect {
  stackedScroll,
  contentTransition,
  interactiveSurface,
  detailHeaderCollapse,
  dataTransition,
}

class _MotionEffectSwitch extends StatefulWidget {
  const _MotionEffectSwitch({required this.effect});

  final _MotionEffect effect;

  @override
  State<_MotionEffectSwitch> createState() => _MotionEffectSwitchState();
}

class _MotionEffectSwitchState extends State<_MotionEffectSwitch> {
  final settings = AppSettings.instance;
  bool _updating = false;

  bool get _value => switch (widget.effect) {
    _MotionEffect.stackedScroll => settings.enableStackedScrollEffect,
    _MotionEffect.contentTransition => settings.enableContentTransitionMotion,
    _MotionEffect.interactiveSurface => settings.enableInteractiveSurfaceMotion,
    _MotionEffect.detailHeaderCollapse =>
      settings.enableDetailHeaderCollapseMotion,
    _MotionEffect.dataTransition => settings.enableDataTransitionMotion,
  };

  String get _description => switch (widget.effect) {
    _MotionEffect.stackedScroll => '堆叠滚动效果',
    _MotionEffect.contentTransition => '内容切换过渡',
    _MotionEffect.interactiveSurface => '卡片交互反馈',
    _MotionEffect.detailHeaderCollapse => '详情头部收拢',
    _MotionEffect.dataTransition => '数据更新过渡',
  };

  String get _subtitle => switch (widget.effect) {
    _MotionEffect.stackedScroll => '列表滚动时使用堆叠变换与平滑滚动',
    _MotionEffect.contentTransition => '页面切换时使用层级推入过渡',
    _MotionEffect.interactiveSurface => '专辑、艺术家、歌单和文件夹卡片悬停与按压反馈',
    _MotionEffect.detailHeaderCollapse => '详情页头部随滚动收拢',
    _MotionEffect.dataTransition => '统计页指标数值更新时使用过渡',
  };

  void _setValue(bool value) {
    switch (widget.effect) {
      case _MotionEffect.stackedScroll:
        settings.enableStackedScrollEffect = value;
      case _MotionEffect.contentTransition:
        settings.enableContentTransitionMotion = value;
      case _MotionEffect.interactiveSurface:
        settings.enableInteractiveSurfaceMotion = value;
      case _MotionEffect.detailHeaderCollapse:
        settings.enableDetailHeaderCollapseMotion = value;
      case _MotionEffect.dataTransition:
        settings.enableDataTransitionMotion = value;
    }
  }

  Future<void> _setEnabled(bool value) async {
    if (_updating || value == _value) return;
    final previous = _value;
    setState(() {
      _updating = true;
      _setValue(value);
    });
    AppSettings.listMotionNotifier.rebuild();
    try {
      if (await settings.saveSettings()) return;
      _setValue(previous);
      AppSettings.listMotionNotifier.rebuild();
      if (mounted) {
        setState(() {});
        showTextOnSnackBar('动效设置保存失败', variant: ToastVariant.error);
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: _description,
      subtitle: _subtitle,
      action: Switch(value: _value, onChanged: _updating ? null : _setEnabled),
    );
  }
}

class _WavyProgressBarSwitch extends StatefulWidget {
  const _WavyProgressBarSwitch();

  @override
  State<_WavyProgressBarSwitch> createState() => _WavyProgressBarSwitchState();
}

class _WavyProgressBarSwitchState extends State<_WavyProgressBarSwitch> {
  final settings = AppSettings.instance;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabledModes = settings.wavyBarEnabledModes;

    return SettingsTile(
      description: '波浪进度条',
      action: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: AppRadius.smCircular,
          border: Border.all(color: scheme.outline),
        ),
        child: ToggleButtons(
          isSelected: NowPlayingMode.values
              .map((m) => enabledModes.contains(m))
              .toList(),
          onPressed: (i) {
            setState(() {
              final mode = NowPlayingMode.values[i];
              if (enabledModes.contains(mode)) {
                enabledModes.remove(mode);
              } else {
                enabledModes.add(mode);
              }
            });
            settings.saveSettings();
          },
          borderRadius: AppRadius.smCircular,
          fillColor: scheme.primaryContainer,
          selectedColor: scheme.onPrimaryContainer,
          color: scheme.onSurface,
          borderColor: Colors.transparent,
          selectedBorderColor: Colors.transparent,
          constraints: const BoxConstraints(minHeight: 32, minWidth: 72),
          textStyle: const TextStyle(
            fontSize: AppType.body,
            fontWeight: AppType.weightMedium,
          ),
          children: const [Text('竖屏'), Text('横屏'), Text('横屏沉浸')],
        ),
      ),
    );
  }
}

class _TopBarLyricAnimationSelector extends StatefulWidget {
  const _TopBarLyricAnimationSelector();

  @override
  State<_TopBarLyricAnimationSelector> createState() =>
      _TopBarLyricAnimationSelectorState();
}

class _TopBarLyricAnimationSelectorState
    extends State<_TopBarLyricAnimationSelector> {
  final settings = AppSettings.instance;

  Future<void> _setAnimation(TopBarLyricAnimation animation) async {
    if (animation == settings.topBarLyricAnimation) return;
    setState(() => settings.topBarLyricAnimation = animation);
    await settings.saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    const animationItems = {
      TopBarLyricAnimation.slideUp: '上划',
      TopBarLyricAnimation.slideDown: '下划',
      TopBarLyricAnimation.slideLeft: '左划',
      TopBarLyricAnimation.slideRight: '右划',
      TopBarLyricAnimation.fade: '淡入淡出',
      TopBarLyricAnimation.absorb: '吸收',
    };

    final current = settings.topBarLyricAnimation;

    return SettingsTile(
      description: '顶部歌词切换动画',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<TopBarLyricAnimation>(
              segments: [
                for (final e in animationItems.entries)
                  ButtonSegment(value: e.key, label: Text(e.value)),
              ],
              selected: {current},
              onSelectionChanged: (v) => _setAnimation(v.first),
              showSelectedIcon: false,
            ),
          ),
        ],
      ),
    );
  }
}

class _MonetLyricsSwitch extends StatefulWidget {
  const _MonetLyricsSwitch();

  @override
  State<_MonetLyricsSwitch> createState() => _MonetLyricsSwitchState();
}

class _MonetLyricsSwitchState extends State<_MonetLyricsSwitch> {
  final settings = AppSettings.instance;

  Future<void> _setEnabled(bool value) async {
    setState(() => settings.useMaterialYouForLyrics = value);
    LyricViewController.instance.triggerRebuild();
    await settings.saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '歌词',
      subtitle: '歌词使用主题色渲染',
      action: Switch(
        value: settings.useMaterialYouForLyrics,
        onChanged: _setEnabled,
      ),
    );
  }
}

class _MonetTransitionSwitch extends StatefulWidget {
  const _MonetTransitionSwitch();

  @override
  State<_MonetTransitionSwitch> createState() => _MonetTransitionSwitchState();
}

class _MonetTransitionSwitchState extends State<_MonetTransitionSwitch> {
  final settings = AppSettings.instance;

  Future<void> _setEnabled(bool value) async {
    setState(() => settings.useMaterialYouForTransition = value);
    LyricViewController.instance.triggerRebuild();
    await settings.saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '间奏动画',
      subtitle: '间奏动画使用主题色渲染',
      action: Switch(
        value: settings.useMaterialYouForTransition,
        onChanged: _setEnabled,
      ),
    );
  }
}

class _MonetControlsSwitch extends StatefulWidget {
  const _MonetControlsSwitch();

  @override
  State<_MonetControlsSwitch> createState() => _MonetControlsSwitchState();
}

class _MonetControlsSwitchState extends State<_MonetControlsSwitch> {
  final settings = AppSettings.instance;

  Future<void> _setEnabled(bool value) async {
    setState(() => settings.useMaterialYouForControls = value);
    AppSettings.rebuildNotifier.rebuild();
    await settings.saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '播放控件',
      subtitle: '播放页控件使用主题色渲染',
      action: Switch(
        value: settings.useMaterialYouForControls,
        onChanged: _setEnabled,
      ),
    );
  }
}

class _GlowEffectSwitch extends StatefulWidget {
  const _GlowEffectSwitch();

  @override
  State<_GlowEffectSwitch> createState() => _GlowEffectSwitchState();
}

class _GlowEffectSwitchState extends State<_GlowEffectSwitch> {
  final nowPlayingPagePref = AppPreference.instance.nowPlayingPagePref;

  Future<void> _setEnabled(bool value) async {
    setState(() => nowPlayingPagePref.enableLyricGlow = value);
    LyricViewController.instance.enableLyricGlow = value;
    LyricViewController.instance.triggerRebuild();
    await AppPreference.instance.save();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '辉光缩放效果',
      subtitle: '逐字播放时的辉光缩放动画',
      action: Switch(
        value: nowPlayingPagePref.enableLyricGlow,
        onChanged: _setEnabled,
      ),
    );
  }
}

class _RubyPositionSetting extends StatefulWidget {
  const _RubyPositionSetting();

  @override
  State<_RubyPositionSetting> createState() => _RubyPositionSettingState();
}

class _RubyPositionSettingState extends State<_RubyPositionSetting> {
  @override
  Widget build(BuildContext context) {
    final rubyPosition = AppPreference.instance.nowPlayingPagePref.rubyPosition;

    return SettingsTile(
      description: '注音位置',
      subtitle: '当前：${rubyPosition.displayName}',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<RubyPosition>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment<RubyPosition>(
                value: RubyPosition.above,
                label: Text('注音在上'),
              ),
              ButtonSegment<RubyPosition>(
                value: RubyPosition.below,
                label: Text('注音在下'),
              ),
              ButtonSegment<RubyPosition>(
                value: RubyPosition.belowTranslation,
                label: Text('注音在翻译下'),
              ),
            ],
            selected: {rubyPosition},
            onSelectionChanged: (newSelection) {
              final newPos = newSelection.first;
              AppPreference.instance.nowPlayingPagePref.rubyPosition = newPos;
              LyricViewController.instance.setRubyPosition(newPos);
              AppPreference.instance.save();
              setState(() {});
            },
          ),
        ],
      ),
    );
  }
}

class _LiftStyleSelector extends StatefulWidget {
  const _LiftStyleSelector();

  @override
  State<_LiftStyleSelector> createState() => _LiftStyleSelectorState();
}

class _LiftStyleSelectorState extends State<_LiftStyleSelector> {
  final nowPlayingPagePref = AppPreference.instance.nowPlayingPagePref;

  @override
  Widget build(BuildContext context) {
    final style = nowPlayingPagePref.liftStyle;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsTile(
          description: '逐字歌词上抬方式',
          action: SegmentedButton<LyricLiftStyle>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment<LyricLiftStyle>(
                value: LyricLiftStyle.vertical,
                label: Text('垂直'),
              ),
              ButtonSegment<LyricLiftStyle>(
                value: LyricLiftStyle.cosine,
                label: Text('余弦'),
              ),
            ],
            selected: {style},
            onSelectionChanged: (newSelection) {
              setState(() => nowPlayingPagePref.liftStyle = newSelection.first);
              LyricViewController.instance.triggerRebuild();
              AppPreference.instance.save();
            },
          ),
        ),
        if (style == LyricLiftStyle.vertical ||
            style == LyricLiftStyle.cosine) ...[
          const SizedBox(height: 16.0),
          SettingsTile(
            description: '上抬幅度',
            subtitle: '${nowPlayingPagePref.liftPeak.toStringAsFixed(1)}x',
            action: SizedBox(
              width: 140,
              child: Slider(
                value: nowPlayingPagePref.liftPeak,
                min: 0.5,
                max: 6.0,
                divisions: 55,
                label: '${nowPlayingPagePref.liftPeak.toStringAsFixed(1)}x',
                onChanged: (v) {
                  setState(() => nowPlayingPagePref.liftPeak = v);
                  LyricViewController.instance.triggerRebuild();
                  AppPreference.instance.save();
                },
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _StaggerStyleSelector extends StatefulWidget {
  const _StaggerStyleSelector();

  @override
  State<_StaggerStyleSelector> createState() => _StaggerStyleSelectorState();
}

class _StaggerStyleSelectorState extends State<_StaggerStyleSelector> {
  final nowPlayingPagePref = AppPreference.instance.nowPlayingPagePref;

  @override
  Widget build(BuildContext context) {
    final style = nowPlayingPagePref.staggerStyle;

    return SettingsTile(
      description: '歌词行动效',
      action: SegmentedButton<LyricStaggerStyle>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment<LyricStaggerStyle>(
            value: LyricStaggerStyle.smooth,
            label: Text('平滑'),
          ),
          ButtonSegment<LyricStaggerStyle>(
            value: LyricStaggerStyle.spring,
            label: Text('弹簧'),
          ),
        ],
        selected: {style},
        onSelectionChanged: (newSelection) {
          setState(() => nowPlayingPagePref.staggerStyle = newSelection.first);
          LyricViewController.instance.triggerRebuild();
          AppPreference.instance.save();
        },
      ),
    );
  }
}

enum _ThemeColorSource { cover, custom }

class _ThemeColorSourceControl extends StatefulWidget {
  const _ThemeColorSourceControl();

  @override
  State<_ThemeColorSourceControl> createState() =>
      _ThemeColorSourceControlState();
}

class _ThemeColorSourceControlState extends State<_ThemeColorSourceControl> {
  final settings = AppSettings.instance;
  bool _isPickingColor = false;
  bool _updating = false;

  void _refreshTheme() {
    final audio = PlayService.instance.playbackService.nowPlaying;
    if (audio != null) {
      ThemeProvider.instance.applyThemeFromAudio(audio);
    } else {
      ThemeProvider.instance.applyThemeOption(settings.themeOption);
    }
  }

  Future<Color?> _openColorPicker() async {
    return showDialog<Color>(
      context: context,
      builder: (context) => const _ThemeColorPickerDialog(),
    );
  }

  Future<void> _pickCustomColor() async {
    if (_isPickingColor) return;
    setState(() => _isPickingColor = true);
    try {
      final result = await _openColorPicker();
      if (result == null || !mounted) return;
      final previous = settings.customCoverColor;
      setState(() => settings.customCoverColor = result.toARGB32());
      _refreshTheme();
      if (!await settings.saveSettings()) {
        settings.customCoverColor = previous;
        _refreshTheme();
        if (mounted) {
          setState(() {});
          showTextOnSnackBar('主题色保存失败', variant: ToastVariant.error);
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isPickingColor = false);
      }
    }
  }

  Future<void> _setSource(_ThemeColorSource source) async {
    if (_updating || _isPickingColor) return;
    final enableCoverColorExtraction = source == _ThemeColorSource.cover;
    if (enableCoverColorExtraction == settings.enableCoverColorExtraction) {
      return;
    }

    final previousExtraction = settings.enableCoverColorExtraction;
    final previousCustomColor = settings.customCoverColor;
    setState(() {
      _updating = true;
      settings.enableCoverColorExtraction = enableCoverColorExtraction;
      if (!enableCoverColorExtraction) {
        settings.customCoverColor ??= AppSettings.getWindowsTheme();
      }
    });
    _refreshTheme();
    try {
      if (!await settings.saveSettings()) {
        settings.enableCoverColorExtraction = previousExtraction;
        settings.customCoverColor = previousCustomColor;
        _refreshTheme();
        if (mounted) {
          showTextOnSnackBar('主题色来源保存失败', variant: ToastVariant.error);
        }
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAuto = settings.enableCoverColorExtraction;
    final source = isAuto ? _ThemeColorSource.cover : _ThemeColorSource.custom;
    final customColor = Color(
      settings.customCoverColor ?? AppSettings.getWindowsTheme(),
    );
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        SettingsTile(
          description: '主题色来源',
          subtitle: isAuto ? '当前封面' : '固定颜色',
          action: SegmentedButton<_ThemeColorSource>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _ThemeColorSource.cover, label: Text('封面')),
              ButtonSegment(
                value: _ThemeColorSource.custom,
                label: Text('自定义'),
              ),
            ],
            selected: {source},
            onSelectionChanged: _updating || _isPickingColor
                ? null
                : (selected) => _setSource(selected.first),
          ),
        ),
        if (!isAuto) ...[
          const SizedBox(height: 16),
          SettingsTile(
            description: '自定义颜色',
            subtitle: _colorToHex(customColor),
            action: OutlinedButton.icon(
              onPressed: _isPickingColor || _updating ? null : _pickCustomColor,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: AppRadius.smCircular,
                ),
              ),
              icon: _isPickingColor
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: customColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: scheme.outline.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
              label: Text(_isPickingColor ? '选择中' : '选择'),
            ),
          ),
        ],
      ],
    );
  }
}

/// 自定义主题色选择对话框 — HSV 色域 + 色相条 + Hex 输入
class _ThemeColorPickerDialog extends StatefulWidget {
  const _ThemeColorPickerDialog();

  @override
  State<_ThemeColorPickerDialog> createState() =>
      _ThemeColorPickerDialogState();
}

class _ThemeColorPickerDialogState extends State<_ThemeColorPickerDialog> {
  late HSVColor _hsv;
  late TextEditingController _hexCtrl;

  @override
  void initState() {
    super.initState();
    final custom = AppSettings.instance.customCoverColor;
    final color = custom != null
        ? Color(custom)
        : Color(AppSettings.getWindowsTheme());
    _hsv = HSVColor.fromColor(color);
    _hexCtrl = TextEditingController(text: _colorToHex(color));
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  void _updateColor(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      _hexCtrl.text = _colorToHex(hsv.toColor());
    });
  }

  bool get _hasValidHex => _parseHex(_hexCtrl.text) != null;

  void _onHexSubmitted(String text) {
    final parsed = _parseHex(text);
    if (parsed != null) {
      _updateColor(HSVColor.fromColor(parsed));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _hsv.toColor();
    final size = MediaQuery.of(context).size;
    final dialogWidth = (size.width - 64).clamp(260.0, 360.0).toDouble();
    final pickerSize = (dialogWidth - 32).clamp(220.0, 300.0).toDouble();

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('自定义主题色'),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 2D 色域 (饱和度 × 明度)
              ClipRRect(
                borderRadius: AppRadius.smCircular,
                child: SizedBox(
                  width: pickerSize,
                  height: pickerSize * 0.7,
                  child: _HsvPicker(hsv: _hsv, onChanged: _updateColor),
                ),
              ),
              const SizedBox(height: 12),
              // 色相条 + 预览
              Row(
                children: [
                  // 当前颜色预览
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: scheme.outline.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 色相条
                  Expanded(
                    child: ClipRRect(
                      borderRadius: AppRadius.smCircular,
                      child: SizedBox(
                        height: 20,
                        child: _HueSlider(
                          hue: _hsv.hue,
                          onChanged: (hue) => _updateColor(_hsv.withHue(hue)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Hex 输入
              Row(
                children: [
                  Text(
                    '#',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: AppType.sectionTitle,
                      fontWeight: AppType.weightMedium,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Focus(
                      onFocusChange: HotkeysHelper.onFocusChanges,
                      child: TextField(
                        controller: _hexCtrl,
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: AppRadius.smCircular,
                          ),
                          hintText: 'RRGGBB',
                          hintStyle: TextStyle(
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: AppType.subtitle,
                          letterSpacing: 1.2,
                        ),
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          UpperCaseTextFormatter(),
                          LengthLimitingTextInputFormatter(6),
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9A-Fa-f]'),
                          ),
                        ],
                        onSubmitted: _onHexSubmitted,
                        onChanged: (text) {
                          if (text.length == 6) {
                            _onHexSubmitted(text);
                          } else {
                            setState(() {});
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _hasValidHex
              ? () => Navigator.of(context).pop(color)
              : null,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 2D 色域选择：横轴 = 饱和度，纵轴 = 明度
class _HsvPicker extends StatelessWidget {
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  const _HsvPicker({required this.hsv, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        return GestureDetector(
          onPanDown: (d) => _pick(d.localPosition, w, h),
          onPanUpdate: (d) => _pick(d.localPosition, w, h),
          child: CustomPaint(
            painter: _HsvPainter(hsv),
            child: const RepaintBoundary(child: SizedBox.expand()),
          ),
        );
      },
    );
  }

  void _pick(Offset pos, double w, double h) {
    final saturation = (pos.dx / w).clamp(0.0, 1.0);
    final value = (1.0 - pos.dy / h).clamp(0.0, 1.0);
    onChanged(hsv.withSaturation(saturation).withValue(value));
  }
}

class _HsvPainter extends CustomPainter {
  final HSVColor hsv;
  _HsvPainter(this.hsv);

  @override
  void paint(Canvas canvas, Size size) {
    final hueColor = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();

    // 底层：从白到纯色（饱和度渐变）
    final satGradient = LinearGradient(
      colors: [Colors.white, hueColor],
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = satGradient.createShader(Offset.zero & size),
    );

    // 顶层：从透明到黑（明度渐变）
    const valGradient = LinearGradient(
      colors: [Colors.transparent, Colors.black],
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = valGradient.createShader(Offset.zero & size),
    );

    // 选取指示器
    final sx = hsv.saturation * size.width;
    final sy = (1.0 - hsv.value) * size.height;
    final indicator = Offset(sx, sy);
    canvas.drawCircle(
      indicator,
      6,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      indicator,
      6,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_HsvPainter old) => old.hsv != hsv;
}

/// 色相选择条
class _HueSlider extends StatelessWidget {
  final double hue;
  final ValueChanged<double> onChanged;

  const _HueSlider({required this.hue, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onPanDown: (d) => _pick(d.localPosition, constraints.maxWidth),
          onPanUpdate: (d) => _pick(d.localPosition, constraints.maxWidth),
          child: CustomPaint(
            painter: _HueBarPainter(hue),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }

  void _pick(Offset pos, double w) {
    final hue = (pos.dx / w * 360).clamp(0.0, 360.0);
    onChanged(hue);
  }
}

class _HueBarPainter extends CustomPainter {
  final double hue;
  _HueBarPainter(this.hue);

  @override
  void paint(Canvas canvas, Size size) {
    // 色相渐变条
    final gradient = LinearGradient(
      colors: List.generate(
        12,
        (i) => HSVColor.fromAHSV(1, i * 30.0, 1, 1).toColor(),
      ),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
      Paint()..shader = gradient.createShader(Offset.zero & size),
    );

    // 指示器
    final x = (hue / 360) * size.width;
    canvas.drawCircle(
      Offset(x, size.height / 2),
      8,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      Offset(x, size.height / 2),
      8,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_HueBarPainter old) => old.hue != hue;
}

String _colorToHex(Color color) {
  return color
      .toARGB32()
      .toRadixString(16)
      .padLeft(8, '0')
      .substring(2)
      .toUpperCase();
}

Color? _parseHex(String hex) {
  hex = hex.trim().replaceFirst('#', '');
  if (hex.length == 6) {
    final value = int.tryParse(hex, radix: 16);
    if (value != null) return Color(0xFF000000 | value);
  }
  if (hex.length == 3) {
    final r = hex[0];
    final g = hex[1];
    final b = hex[2];
    return _parseHex('$r$r$g$g$b$b');
  }
  return null;
}

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}

class _LyricsTabContent extends StatelessWidget {
  const _LyricsTabContent();

  @override
  Widget build(BuildContext context) {
    return const SmoothScrollListView(
      padding: EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        _GroupEntry(
          icon: Symbols.download,
          title: '歌词来源',
          subtitle: '本地歌词与在线歌词的获取顺序',
          groupId: 'lyric-source',
        ),
        SizedBox(height: 8.0),
        _GroupEntry(
          icon: Symbols.translate,
          title: '歌词内容',
          subtitle: '歌曲信息保留与文字转换',
          groupId: 'lyric-content',
        ),
        SizedBox(height: 8.0),
        _GroupEntry(
          icon: Symbols.save,
          title: '歌词写入',
          subtitle: '标签写入与外部 LRC 文件保存',
          groupId: 'lyric-writing',
        ),
        SizedBox(height: 8.0),
        _SettingsSectionHeader('歌词显示'),
        SizedBox(height: 4.0),
        _GroupEntry(
          icon: Symbols.animation,
          title: '显示效果',
          subtitle: '逐字播放、注音与行动效',
          groupId: 'lyric-effect',
        ),
      ],
    );
  }
}

class _PlaybackTabContent extends StatelessWidget {
  const _PlaybackTabContent();

  @override
  Widget build(BuildContext context) {
    return const SmoothScrollListView(
      padding: EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        _GroupEntry(
          icon: Symbols.play_circle,
          title: '播放行为',
          subtitle: '音量增益与切歌过渡',
          groupId: 'playback-behavior',
        ),
        SizedBox(height: 8.0),
        _SettingsSectionHeader('外部控制'),
        SizedBox(height: 4.0),
        _GroupEntry(
          icon: Symbols.keyboard_command_key,
          title: '播放控制',
          subtitle: '任务栏播放控制',
          groupId: 'playback-control',
        ),
      ],
    );
  }
}

class _DesktopLyricTabContent extends StatefulWidget {
  const _DesktopLyricTabContent();

  @override
  State<_DesktopLyricTabContent> createState() =>
      _DesktopLyricTabContentState();
}

class _DesktopLyricTabContentState extends State<_DesktopLyricTabContent> {
  DesktopLyricService get _service => PlayService.instance.desktopLyricService;

  Future<void> _toggleDesktopLyric(bool enabled) async {
    if (_service.isKilling) return;
    if (enabled) {
      await _service.startDesktopLyric();
    } else {
      await _service.killDesktopLyric();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final running = _service.isRunning;
        final busy = _service.isKilling;
        return SmoothScrollListView(
          padding: const EdgeInsets.only(bottom: 96.0, right: 20),
          children: [
            SettingsTile(
              description: '桌面歌词',
              action: Switch(
                value: running,
                onChanged: busy ? null : _toggleDesktopLyric,
              ),
            ),
            const SizedBox(height: 16),
            if (running && _service.isLocked) ...[
              _DesktopLyricUnlockTile(onUnlock: _service.sendUnlockMessage),
              const SizedBox(height: 16),
            ],
            if (!running)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  '桌面歌词未启动，修改将在下次启动时生效',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: AppType.caption,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            const _SettingsSectionHeader('内容与布局'),
            const SizedBox(height: 4),
            const _GroupEntry(
              icon: Symbols.lyrics,
              title: '歌词内容',
              subtitle: '翻译、注音与信息显示',
              groupId: 'desktop-basic',
            ),
            const SizedBox(height: 8),
            const _GroupEntry(
              icon: Symbols.view_week,
              title: '布局与动画',
              subtitle: '布局、对齐与切换动画',
              groupId: 'desktop-display',
            ),
            const SizedBox(height: 8),
            const _GroupEntry(
              icon: Symbols.desktop_windows,
              title: '窗口行为',
              subtitle: '隐藏、置顶与交互',
              groupId: 'desktop-window',
            ),
            const SizedBox(height: 8),
            const _SettingsSectionHeader('视觉样式'),
            const SizedBox(height: 4),
            const _GroupEntry(
              icon: Symbols.format_size,
              title: '文字样式',
              subtitle: '字号、字重与描边',
              groupId: 'desktop-style',
            ),
            const SizedBox(height: 8),
            const _GroupEntry(
              icon: Symbols.palette,
              title: '颜色',
              subtitle: '主题色与自定义配色',
              groupId: 'desktop-color',
            ),
          ],
        );
      },
    );
  }
}

class _DesktopLyricPreview extends StatelessWidget {
  const _DesktopLyricPreview();

  static const _mainLyric = '时光的河入海流';
  static const _romanLyric = 'shí guāng de hé';
  static const _translation = 'The river of time flows';
  static const _nextLyric = '终于我们分头走';
  static const _nextRomanLyric = 'zhong yu wo men';
  static const _nextTranslation = 'At last, we walk apart';

  static final _alphanumeric = RegExp(
    r'''^[A-Za-z0-9 !"'?.,:;()\[\]\-《》「」（）：/“”]+$''',
  );

  FontWeight _weight(int w) {
    final clamped = w.clamp(100, 900);
    return switch (clamped) {
      100 => FontWeight.w100,
      200 => FontWeight.w200,
      300 => FontWeight.w300,
      400 => FontWeight.w400,
      500 => FontWeight.w500,
      600 => FontWeight.w600,
      700 => FontWeight.w700,
      800 => FontWeight.w800,
      _ => FontWeight.w900,
    };
  }

  Widget _verticalText(String text, TextStyle style) {
    return Flex(
      direction: Axis.vertical,
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (final char in text.split(''))
          if (_alphanumeric.hasMatch(char))
            RotatedBox(quarterTurns: 1, child: Text(char, style: style))
          else
            Text(char, style: style),
      ],
    );
  }

  Widget _lineText(String text, TextStyle style, bool vertical) {
    if (!vertical) {
      return Text(
        text,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.clip,
        softWrap: false,
      );
    }
    return _verticalText(text, style);
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final scheme = Theme.of(context).colorScheme;
    final colors = resolveDesktopLyricColors(
      followThemeColor: settings.desktopFollowThemeColor,
      brightnessMode: settings.desktopLyricBrightnessMode,
      scheme: scheme,
      customPlayedColor: settings.desktopPlayedColor,
      customUnplayedColor: settings.desktopUnplayedColor,
    );
    final played = colors.played;
    final unplayed = colors.unplayed;
    final weight = _weight(settings.desktopLyricFontWeight);
    final vertical = settings.desktopUseVerticalDisplayMode;
    final doubleLine = settings.desktopShowDoubleLine;

    final outlineColor = shouldUseLightDesktopLyricOutline(played)
        ? Colors.white.withValues(alpha: 0.55)
        : Colors.black.withValues(alpha: 0.85);
    final shadows = settings.desktopEnableStroke
        ? [
            for (final (dx, dy) in const [
              (1.0, 0.0),
              (-1.0, 0.0),
              (0.0, 1.0),
              (0.0, -1.0),
            ])
              Shadow(
                color: outlineColor,
                offset: Offset(dx, dy),
                blurRadius: 1,
              ),
          ]
        : null;

    TextStyle mainStyle(Color color) => TextStyle(
      fontSize: settings.desktopLyricFontSize,
      color: color,
      fontWeight: weight,
      height: 1.1,
      shadows: shadows,
    );
    TextStyle subStyle(Color color) => TextStyle(
      fontSize: settings.desktopTranslationFontSize,
      color: color,
      fontWeight: weight,
      height: 1.1,
      shadows: shadows,
    );

    final hasRoman = settings.showDesktopLyricRoman;
    final hasTranslation = settings.desktopShowTranslation;
    final translationPosition = vertical
        ? settings.desktopLyricTranslationPosition
        : 1;
    final romanPosition =
        hasTranslation || settings.desktopLyricRomanPosition != 2
        ? settings.desktopLyricRomanPosition
        : 1;

    List<Widget> lineChildren(
      String lyric,
      String roman,
      String translation,
      Color color,
    ) => [
      if (hasRoman && romanPosition == 0)
        _lineText(roman, subStyle(color), vertical),
      if (hasTranslation && translationPosition == 0)
        _lineText(translation, subStyle(color), vertical),
      _lineText(lyric, mainStyle(color), vertical),
      if (hasRoman && romanPosition == 1)
        _lineText(roman, subStyle(color), vertical),
      if (hasTranslation && translationPosition == 1)
        _lineText(translation, subStyle(color), vertical),
      if (hasRoman && romanPosition == 2)
        _lineText(roman, subStyle(color), vertical),
    ];

    Widget lineBlock(List<Widget> children, int alignment) {
      final crossAxis = switch (alignment) {
        0 => CrossAxisAlignment.start,
        1 => CrossAxisAlignment.center,
        _ => CrossAxisAlignment.end,
      };
      final line = Flex(
        direction: vertical ? Axis.horizontal : Axis.vertical,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: crossAxis,
        children: children,
      );
      return Align(
        alignment: vertical
            ? switch (alignment) {
                0 => Alignment.topCenter,
                1 => Alignment.center,
                _ => Alignment.bottomCenter,
              }
            : switch (alignment) {
                0 => Alignment.centerLeft,
                1 => Alignment.center,
                _ => Alignment.centerRight,
              },
        child: line,
      );
    }

    final current = lineChildren(_mainLyric, _romanLyric, _translation, played);
    final currentAlign = settings.desktopLyricTextAlign == 3
        ? 0
        : settings.desktopLyricTextAlign;
    final nextAlign = settings.desktopLyricTextAlign == 3
        ? 2
        : settings.desktopLyricTextAlign;
    final inner = doubleLine
        ? Flex(
            direction: vertical ? Axis.horizontal : Axis.vertical,
            children: [
              Expanded(child: lineBlock(current, currentAlign)),
              Expanded(
                child: lineBlock(
                  lineChildren(
                    _nextLyric,
                    _nextRomanLyric,
                    _nextTranslation,
                    unplayed,
                  ),
                  nextAlign,
                ),
              ),
            ],
          )
        : lineBlock(current, currentAlign);

    return Container(
      height: vertical ? 190 : 130,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      padding: const EdgeInsets.all(12),
      child: Opacity(
        opacity: settings.desktopFontOpacity,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: vertical ? 110 : 320,
            height: vertical ? 150 : 80,
            child: inner,
          ),
        ),
      ),
    );
  }
}

class _DesktopLyricUnlockTile extends StatelessWidget {
  const _DesktopLyricUnlockTile({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '桌面歌词已锁定',
      subtitle: '锁定后不接收鼠标操作',
      action: Switch(value: true, onChanged: (_) => onUnlock()),
    );
  }
}

class _DesktopColorSetting extends StatelessWidget {
  final String label;
  final int? color;
  final double opacity;
  final VoidCallback onPickColor;

  const _DesktopColorSetting({
    required this.label,
    required this.color,
    required this.opacity,
    required this.onPickColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final displayColor = color != null
        ? Color((color! | 0xFF000000).toUnsigned(32))
        : null;

    return SettingsTile(
      description: label,
      subtitle: color == null ? '跟随主题' : '自定义 · ${(opacity * 100).round()}%',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onPickColor,
            borderRadius: AppRadius.smCircular,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: (displayColor ?? scheme.primary).withValues(
                  alpha: opacity,
                ),
                borderRadius: AppRadius.xsCircular,
                border: displayColor == null
                    ? Border.all(color: scheme.outline.withValues(alpha: 0.4))
                    : null,
              ),
              child: displayColor == null
                  ? Icon(
                      Icons.not_interested,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    )
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: onPickColor,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
            ),
            child: const Text('自定义'),
          ),
        ],
      ),
    );
  }
}

class _DesktopColorResult {
  final Color color;
  final double opacity;
  const _DesktopColorResult(this.color, this.opacity);
}

/// Desktop 歌词颜色选择器 — HSV 色域 + 色相条 + Hex 输入 + 不透明度
class _DesktopColorPickerDialog extends StatefulWidget {
  final Color initialColor;
  final double initialOpacity;
  final String label;
  const _DesktopColorPickerDialog({
    required this.initialColor,
    required this.initialOpacity,
    required this.label,
  });

  @override
  State<_DesktopColorPickerDialog> createState() =>
      _DesktopColorPickerDialogState();
}

class _DesktopColorPickerDialogState extends State<_DesktopColorPickerDialog> {
  late HSVColor _hsv;
  late TextEditingController _hexCtrl;
  late double _opacity;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
    _hexCtrl = TextEditingController(text: _colorToHex(widget.initialColor));
    _opacity = widget.initialOpacity;
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  void _updateColor(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      _hexCtrl.text = _colorToHex(hsv.toColor());
    });
  }

  bool get _hasValidHex => _parseHex(_hexCtrl.text) != null;

  void _onHexSubmitted(String text) {
    final parsed = _parseHex(text);
    if (parsed != null) {
      _updateColor(HSVColor.fromColor(parsed));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _hsv.toColor();
    final size = MediaQuery.of(context).size;
    final dialogWidth = (size.width - 64).clamp(260.0, 360.0).toDouble();
    final pickerSize = (dialogWidth - 32).clamp(220.0, 300.0).toDouble();

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(widget.label),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: AppRadius.smCircular,
                child: SizedBox(
                  width: pickerSize,
                  height: pickerSize * 0.7,
                  child: _HsvPicker(hsv: _hsv, onChanged: _updateColor),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: _opacity),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: scheme.outline.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: AppRadius.smCircular,
                      child: SizedBox(
                        height: 20,
                        child: _HueSlider(
                          hue: _hsv.hue,
                          onChanged: (hue) => _updateColor(_hsv.withHue(hue)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    '#',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: AppType.sectionTitle,
                      fontWeight: AppType.weightMedium,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Focus(
                      onFocusChange: HotkeysHelper.onFocusChanges,
                      child: TextField(
                        controller: _hexCtrl,
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: AppRadius.smCircular,
                          ),
                          hintText: 'RRGGBB',
                          hintStyle: TextStyle(
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: AppType.subtitle,
                          letterSpacing: 1.2,
                        ),
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          UpperCaseTextFormatter(),
                          LengthLimitingTextInputFormatter(6),
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9A-Fa-f]'),
                          ),
                        ],
                        onSubmitted: _onHexSubmitted,
                        onChanged: (text) {
                          if (text.length == 6) {
                            _onHexSubmitted(text);
                          } else {
                            setState(() {});
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        Row(
          children: [
            const SizedBox(width: 4),
            Text(
              '不透明度',
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: Slider(
                value: _opacity,
                min: 0,
                max: 1,
                divisions: 20,
                onChanged: (v) => setState(() => _opacity = v),
              ),
            ),
            SizedBox(
              width: 36,
              child: Text(
                '${(_opacity * 100).round()}%',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: _hasValidHex
                  ? () => Navigator.of(
                      context,
                    ).pop(_DesktopColorResult(color, _opacity))
                  : null,
              child: const Text('确定'),
            ),
          ],
        ),
      ],
    );
  }
}

class _AdvancedTabContent extends StatelessWidget {
  const _AdvancedTabContent();

  @override
  Widget build(BuildContext context) {
    return const SmoothScrollListView(
      padding: EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        _GroupEntry(
          icon: Symbols.settings_suggest,
          title: '系统行为',
          subtitle: '关闭窗口行为与日志',
          groupId: 'advanced-system',
        ),
        SizedBox(height: 8.0),
        _SettingsSectionHeader('媒体与字体'),
        SizedBox(height: 4.0),
        _GroupEntry(
          icon: Symbols.interests,
          title: '媒体解析',
          subtitle: '艺术家名称的分隔规则',
          groupId: 'advanced-custom',
        ),
        SizedBox(height: 8.0),
        _GroupEntry(
          icon: Symbols.text_fields,
          title: '字体',
          subtitle: '歌词与界面字体',
          groupId: 'advanced-font',
        ),
      ],
    );
  }
}

class _TaskbarThumbnailControl extends StatefulWidget {
  const _TaskbarThumbnailControl();

  @override
  State<_TaskbarThumbnailControl> createState() =>
      _TaskbarThumbnailControlState();
}

class _TaskbarThumbnailControlState extends State<_TaskbarThumbnailControl> {
  final pref = AppPreference.instance;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SettingsTile(
          description: '任务栏播放控制',
          subtitle: pref.taskbarPlaybackControls ? '显示上一首、播放和下一首按钮' : '隐藏播放按钮',
          action: Switch(
            value: pref.taskbarPlaybackControls,
            onChanged: (value) => setState(() {
              TaskbarThumbnailService.instance.setPlaybackControlsEnabled(
                value,
              );
            }),
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: 'Alt+Tab 封面预览',
          subtitle: pref.taskbarCoverPreview ? '显示当前歌曲封面' : '显示窗口预览',
          action: Switch(
            value: pref.taskbarCoverPreview,
            onChanged: (value) => setState(() {
              TaskbarThumbnailService.instance.setCoverPreviewEnabled(value);
            }),
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: '封面预览大小',
          subtitle: '${(pref.taskbarCoverScale * 100).round()}%（放大可能降低清晰度）',
          action: SizedBox(
            width: 220.0,
            child: Slider(
              value: pref.taskbarCoverScale,
              min: 0.5,
              max: 2.0,
              divisions: 6,
              label: '${(pref.taskbarCoverScale * 100).round()}%',
              onChanged: (value) {
                setState(() {
                  TaskbarThumbnailService.instance.setCoverScale(value);
                });
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _WindowCloseBehaviorControl extends StatefulWidget {
  const _WindowCloseBehaviorControl();

  @override
  State<_WindowCloseBehaviorControl> createState() =>
      _WindowCloseBehaviorControlState();
}

class _WindowCloseBehaviorControlState
    extends State<_WindowCloseBehaviorControl> {
  final settings = AppSettings.instance;
  bool _updating = false;

  Future<void> _setBehavior(WindowCloseBehavior behavior) async {
    if (_updating || behavior == settings.windowCloseBehavior) return;
    final previous = settings.windowCloseBehavior;
    setState(() {
      _updating = true;
      settings.windowCloseBehavior = behavior;
    });
    try {
      final trayUpdated = await WindowLifecycleService.instance.syncTrayIcon();
      if (!trayUpdated && behavior == WindowCloseBehavior.minimizeToTray) {
        await _restoreBehavior(previous);
        _showSaveError('通知区初始化失败');
        return;
      }
      if (!await settings.saveSettings()) {
        await _restoreBehavior(previous);
        _showSaveError('关闭行为保存失败');
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _restoreBehavior(WindowCloseBehavior behavior) async {
    settings.windowCloseBehavior = behavior;
    await WindowLifecycleService.instance.syncTrayIcon();
  }

  void _showSaveError(String message) {
    if (mounted) showTextOnSnackBar(message, variant: ToastVariant.error);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '关闭主窗口时',
      subtitle: settings.windowCloseBehavior == WindowCloseBehavior.exit
          ? '退出程序并停止播放'
          : '隐藏到通知区并继续播放',
      action: SegmentedButton<WindowCloseBehavior>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: WindowCloseBehavior.exit, label: Text('退出程序')),
          ButtonSegment(
            value: WindowCloseBehavior.minimizeToTray,
            label: Text('通知区'),
          ),
        ],
        selected: {settings.windowCloseBehavior},
        onSelectionChanged: _updating
            ? null
            : (value) => _setBehavior(value.first),
      ),
    );
  }
}

class SelectFontCombobox extends StatefulWidget {
  const SelectFontCombobox({super.key});

  @override
  State<SelectFontCombobox> createState() => _SelectFontComboboxState();
}

class _SelectFontComboboxState extends State<SelectFontCombobox> {
  String? _busyLabel;

  bool get _isBusy => _busyLabel != null;

  void _setBusyLabel(String? label) {
    if (mounted) {
      setState(() => _busyLabel = label);
    }
  }

  Future<void> _selectFont() async {
    if (_isBusy) return;
    _setBusyLabel('获取中');
    try {
      final installedFont = await getInstalledFonts();
      if (!mounted) return;
      if (installedFont == null || installedFont.isEmpty) {
        showTextOnSnackBar('无法获取字体', variant: ToastVariant.error);
        return;
      }

      final selection = await showDialog<_FontSelection>(
        context: context,
        builder: (context) => _FontSelector(installedFont: installedFont),
      );
      if (!mounted || selection == null) return;

      final selectedFont = selection.font;
      final settings = AppSettings.instance;
      final oldFontFamily = settings.fontFamily;
      final oldFontPath = settings.fontPath;
      if (selectedFont == null) {
        try {
          _setBusyLabel('恢复默认');
          ThemeProvider.instance.changeFontFamily(null);

          _setBusyLabel('保存中');
          settings.fontFamily = null;
          settings.fontPath = null;
          final saved = await settings.saveSettings();
          if (!saved) {
            settings.fontFamily = oldFontFamily;
            settings.fontPath = oldFontPath;
            ThemeProvider.instance.changeFontFamily(oldFontFamily);
            showTextOnSnackBar('保存字体设置失败', variant: ToastVariant.error);
          } else if (mounted) {
            showTextOnSnackBar('已恢复默认字体', variant: ToastVariant.success);
          }
        } catch (err, trace) {
          logger.e('恢复默认字体失败', error: err, stackTrace: trace);
          if (mounted) {
            showTextOnSnackBar('恢复默认字体失败，请查看日志');
          }
        }
        return;
      }

      try {
        _setBusyLabel('应用中');
        final fontLoader = FontLoader(selectedFont.fullName);
        fontLoader.addFont(
          File(selectedFont.path).readAsBytes().then((value) {
            return ByteData.sublistView(value);
          }),
        );
        await fontLoader.load();
        ThemeProvider.instance.changeFontFamily(selectedFont.fullName);

        _setBusyLabel('保存中');
        settings.fontFamily = selectedFont.fullName;
        settings.fontPath = selectedFont.path;
        final saved = await settings.saveSettings();
        if (!saved) {
          settings.fontFamily = oldFontFamily;
          settings.fontPath = oldFontPath;
          ThemeProvider.instance.changeFontFamily(oldFontFamily);
          showTextOnSnackBar('保存字体设置失败');
        } else if (mounted) {
          showTextOnSnackBar('已应用字体');
        }
      } catch (err, trace) {
        ThemeProvider.instance.changeFontFamily(null);
        logger.e('应用字体失败', error: err, stackTrace: trace);
        if (mounted) {
          showTextOnSnackBar('应用字体失败，请查看日志');
        }
      }
    } finally {
      _setBusyLabel(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '自定义字体',
      subtitle: _busyLabel,
      action: FilledButton.icon(
        onPressed: _isBusy ? null : _selectFont,
        label: Text(_busyLabel ?? '选择字体'),
        icon: _isBusy
            ? const SizedBox(
                width: 16.0,
                height: 16.0,
                child: CircularProgressIndicator(strokeWidth: 2.0),
              )
            : const Icon(Symbols.text_fields),
      ),
    );
  }
}

class _FontSelection {
  const _FontSelection(this.font);

  final InstalledFont? font;
}

class _FontSelector extends StatelessWidget {
  const _FontSelector({required this.installedFont});
  final List<InstalledFont> installedFont;

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context);
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48.0).clamp(300.0, 520.0).toDouble();
    final height = (size.height - 96.0).clamp(320.0, 560.0).toDouble();
    final currentFont = theme.fontFamily;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 24.0,
        vertical: 24.0,
      ),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Wrap(
                  spacing: 8.0,
                  runSpacing: 8.0,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '\u9009\u62e9\u5b57\u4f53',
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: AppType.sectionTitle,
                        fontWeight: AppType.weightBold,
                      ),
                    ),
                    _CurrentFontPill(label: currentFont ?? '\u9ed8\u8ba4'),
                  ],
                ),
              ),
              Expanded(
                child: Material(
                  type: MaterialType.transparency,
                  child: ListView.builder(
                    itemCount: installedFont.length + 1,
                    itemExtent: 56.0,
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        final selected = currentFont == null;
                        return ListTile(
                          selected: selected,
                          selectedTileColor: scheme.secondaryContainer
                              .withValues(alpha: 0.45),
                          shape: RoundedRectangleBorder(
                            borderRadius: AppRadius.mdCircular,
                          ),
                          leading: Icon(
                            selected
                                ? Symbols.check_circle
                                : Symbols.format_clear,
                            color: selected
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                          title: const Text('默认字体'),
                          trailing: selected ? const Icon(Symbols.check) : null,
                          onTap:
                              !canResetOptionalSetting<String>(
                                current: currentFont,
                                isSaving: false,
                              )
                              ? null
                              : () => Navigator.pop(
                                  context,
                                  const _FontSelection(null),
                                ),
                        );
                      }

                      final fontIndex = i - 1;
                      final font = installedFont[fontIndex];
                      final selected = font.fullName == currentFont;
                      return ListTile(
                        selected: selected,
                        selectedTileColor: scheme.secondaryContainer.withValues(
                          alpha: 0.45,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: AppRadius.mdCircular,
                        ),
                        leading: Icon(
                          selected ? Symbols.check_circle : Symbols.text_fields,
                          color: selected
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                        title: Text(
                          font.fullName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: selected ? const Icon(Symbols.check) : null,
                        onTap: selected
                            ? null
                            : () =>
                                  Navigator.pop(context, _FontSelection(font)),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16.0),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8.0,
                overflowSpacing: 8.0,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('\u53d6\u6d88'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CurrentFontPill extends StatelessWidget {
  const _CurrentFontPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Text(
      '\u5f53\u524d\uff1a$label',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: scheme.onSurfaceVariant,
        fontSize: AppType.caption,
      ),
    );
  }
}

class DefaultLyricSourceControl extends StatefulWidget {
  const DefaultLyricSourceControl({super.key});

  @override
  State<DefaultLyricSourceControl> createState() =>
      _DefaultLyricSourceControlState();
}

class _DefaultLyricSourceControlState extends State<DefaultLyricSourceControl> {
  final settings = AppSettings.instance;

  Future<void> _setLocalLyricFirst(bool value) async {
    if (value == settings.localLyricFirst) return;
    setState(() => settings.localLyricFirst = value);
    await settings.saveSettings();
  }

  Future<void> _setPreferredOnlineSource(LyricSourceType value) async {
    if (value == settings.preferredOnlineSource) return;
    setState(() => settings.preferredOnlineSource = value);
    await settings.saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsTile(
          description: '首选歌词来源',
          action: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment<bool>(
                value: true,
                icon: Icon(Symbols.cloud_off),
                label: Text('本地'),
              ),
              ButtonSegment<bool>(
                value: false,
                icon: Icon(Symbols.cloud),
                label: Text('在线'),
              ),
            ],
            selected: {settings.localLyricFirst},
            onSelectionChanged: (newSelection) =>
                _setLocalLyricFirst(newSelection.first),
          ),
        ),
        if (!settings.localLyricFirst) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: SettingsTile(
              description: '默认在线源',
              action: SegmentedButton<LyricSourceType>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: LyricSourceType.qq, label: Text('QQ')),
                  ButtonSegment(
                    value: LyricSourceType.kugou,
                    label: Text('酷狗'),
                  ),
                  ButtonSegment(value: LyricSourceType.ne, label: Text('网易')),
                  ButtonSegment(
                    value: LyricSourceType.amll,
                    label: Text('AMLL'),
                  ),
                ],
                selected: {settings.preferredOnlineSource},
                onSelectionChanged: (newSelection) =>
                    _setPreferredOnlineSource(newSelection.first),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _AboutTabContent extends StatelessWidget {
  const _AboutTabContent();

  @override
  Widget build(BuildContext context) {
    return const SmoothScrollListView(
      padding: EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        _SettingsSectionHeader('更新'),
        SizedBox(height: 4.0),
        _AboutVersionItem(),
        SizedBox(height: 16.0),
        _AboutAutoUpdateItem(),
        SizedBox(height: 24.0),
        _SettingsSectionHeader('相关链接'),
        SizedBox(height: 4.0),
        _AboutLinkItem(
          title: '官方网站',
          url: 'https://qingyueyin.github.io/Pure-music/',
          actionLabel: '访问官网',
          icon: Symbols.language,
        ),
        SizedBox(height: 16.0),
        _AboutLinkItem(
          title: '项目主页',
          url: 'https://github.com/qingyueyin/Pure-music',
          actionLabel: '打开仓库',
          icon: Symbols.code,
        ),
        SizedBox(height: 16.0),
        CreateIssueTile(),
        _AboutContributorsSection(),
      ],
    );
  }
}

class _AboutContributorsSection extends StatefulWidget {
  const _AboutContributorsSection();

  @override
  State<_AboutContributorsSection> createState() =>
      _AboutContributorsSectionState();
}

class _AboutContributorsSectionState extends State<_AboutContributorsSection> {
  static List<_AboutContributor>? _cachedContributors;
  static Future<List<_AboutContributor>>? _pendingRequest;

  late List<_AboutContributor> _contributors;

  @override
  void initState() {
    super.initState();
    _contributors = _cachedContributors ?? const [];
    if (_cachedContributors == null) _loadContributors();
  }

  Future<void> _loadContributors() async {
    try {
      final contributors = await _getContributors();
      if (!mounted) return;
      setState(() => _contributors = contributors);
    } catch (error, trace) {
      logger.w('[About] contributors request failed: ${error.runtimeType}');
      logger.d(trace.toString());
    }
  }

  static Future<List<_AboutContributor>> _getContributors() async {
    final cached = _cachedContributors;
    if (cached != null) return cached;

    final pending = _pendingRequest;
    if (pending != null) return pending;

    final request = _fetchContributors();
    _pendingRequest = request;
    try {
      final contributors = await request;
      _cachedContributors = contributors;
      return contributors;
    } finally {
      if (identical(_pendingRequest, request)) _pendingRequest = null;
    }
  }

  static Future<List<_AboutContributor>> _fetchContributors() async {
    final slug = gh.RepositorySlug.full(AppPreference.defaultUpdateRepoSlug);
    final response = await AppSettings.github.repositories
        .listContributors(slug, anon: true)
        .toList()
        .timeout(const Duration(seconds: 15));
    final contributors = response
        .where((item) {
          final login = item.login?.trim();
          final type = item.type?.toLowerCase();
          return login != null &&
              login.isNotEmpty &&
              type != 'bot' &&
              !login.toLowerCase().endsWith('[bot]');
        })
        .map(_AboutContributor.fromGitHub)
        .toList();
    contributors.sort((left, right) {
      final contributionOrder = right.contributions.compareTo(
        left.contributions,
      );
      if (contributionOrder != 0) return contributionOrder;
      return left.login.toLowerCase().compareTo(right.login.toLowerCase());
    });
    return List.unmodifiable(contributors);
  }

  @override
  Widget build(BuildContext context) {
    if (_contributors.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SettingsSectionHeader('贡献者'),
          const SizedBox(height: 8.0),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 720
                  ? 3
                  : constraints.maxWidth >= 460
                  ? 2
                  : 1;
              final tileWidth =
                  (constraints.maxWidth - (columns - 1) * Spacing.sm) / columns;
              return Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: [
                  for (final contributor in _contributors)
                    _ContributorTile(
                      contributor: contributor,
                      width: tileWidth,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AboutContributor {
  const _AboutContributor({
    required this.login,
    required this.avatarUrl,
    required this.profileUrl,
    required this.contributions,
  });

  factory _AboutContributor.fromGitHub(gh.Contributor contributor) {
    final login = contributor.login!.trim();
    return _AboutContributor(
      login: login,
      avatarUrl: contributor.avatarUrl?.trim(),
      profileUrl: contributor.htmlUrl?.trim().isNotEmpty == true
          ? contributor.htmlUrl!.trim()
          : 'https://github.com/$login',
      contributions: contributor.contributions ?? 0,
    );
  }

  final String login;
  final String? avatarUrl;
  final String profileUrl;
  final int contributions;
}

class _ContributorTile extends StatelessWidget {
  const _ContributorTile({required this.contributor, required this.width});

  final _AboutContributor contributor;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: 60.0,
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: AppRadius.smCircular,
        child: InkWell(
          borderRadius: AppRadius.smCircular,
          onTap: () async {
            final opened = await rust_utils.launchInBrowser(
              uri: contributor.profileUrl,
            );
            if (!opened && context.mounted) {
              showTextOnSnackBar('打开链接失败');
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            child: Row(
              children: [
                _ContributorAvatar(contributor: contributor),
                const SizedBox(width: 10.0),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        contributor.login,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: AppType.body,
                          fontWeight: AppType.weightSemibold,
                        ),
                      ),
                      Text(
                        '${contributor.contributions} 次贡献',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: AppType.caption,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Symbols.open_in_new, size: 16, color: scheme.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ContributorAvatar extends StatelessWidget {
  const _ContributorAvatar({required this.contributor});

  final _AboutContributor contributor;

  @override
  Widget build(BuildContext context) {
    final login = contributor.login;
    final initials = login.substring(0, login.length > 2 ? 2 : login.length);
    final avatarUrl = contributor.avatarUrl;
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: 18,
      backgroundColor: scheme.secondaryContainer,
      foregroundColor: scheme.onSecondaryContainer,
      child: avatarUrl?.isNotEmpty == true
          ? ClipOval(
              child: Image.network(
                avatarUrl!,
                width: 36,
                height: 36,
                fit: BoxFit.cover,
                cacheWidth: 72,
                cacheHeight: 72,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => Text(initials.toUpperCase()),
              ),
            )
          : Text(initials.toUpperCase()),
    );
  }
}

class _SettingsSectionHeader extends StatelessWidget {
  final String label;
  const _SettingsSectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        label,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: AppType.caption,
          fontWeight: AppType.weightSemibold,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class SettingsEmptyState extends StatelessWidget {
  const SettingsEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: AppRadius.smCircular,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: AppType.subtitle,
                    fontWeight: AppType.weightSemibold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: AppType.body,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutVersionItem extends StatefulWidget {
  const _AboutVersionItem();

  @override
  State<_AboutVersionItem> createState() => _AboutVersionItemState();
}

class _AboutVersionItemState extends State<_AboutVersionItem> {
  bool _isChecking = false;

  Future<void> _check() async {
    if (_isChecking) return;
    setState(() => _isChecking = true);

    try {
      final newest = await UpdateChecker.checkForUpdate();
      if (!mounted) return;

      if (newest != null &&
          UpdateChecker.hasNewVersion(newest.tagName, AppSettings.version)) {
        showDialog(
          context: context,
          builder: (context) => NewestUpdateView(info: newest),
        );
      } else {
        showTextOnSnackBar('无新版本');
      }
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
      if (mounted) showTextOnSnackBar('网络异常');
    }

    if (mounted) setState(() => _isChecking = false);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '当前版本',
      subtitle: AppSettings.version,
      action: FilledButton.tonalIcon(
        onPressed: _isChecking ? null : _check,
        icon: _isChecking
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Symbols.update, size: 18),
        label: Text(_isChecking ? '检查中' : '检查更新'),
      ),
    );
  }
}

class _AboutAutoUpdateItem extends StatefulWidget {
  const _AboutAutoUpdateItem();

  @override
  State<_AboutAutoUpdateItem> createState() => _AboutAutoUpdateItemState();
}

class _AboutAutoUpdateItemState extends State<_AboutAutoUpdateItem> {
  @override
  Widget build(BuildContext context) {
    final enabled = AppPreference.instance.autoCheckUpdate;
    return SettingsTile(
      description: '启动时自动检查更新',
      subtitle: enabled ? '已开启' : '已关闭',
      action: Switch(
        value: enabled,
        onChanged: (value) async {
          setState(() => AppPreference.instance.autoCheckUpdate = value);
          await AppPreference.instance.save();
        },
      ),
    );
  }
}

class _AboutLinkItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String url;
  final String actionLabel;

  const _AboutLinkItem({
    required this.icon,
    required this.title,
    required this.url,
    required this.actionLabel,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: title,
      action: FilledButton.tonalIcon(
        onPressed: () async {
          final opened = await rust_utils.launchInBrowser(uri: url);
          if (!opened) {
            showTextOnSnackBar('打开链接失败');
          }
        },
        icon: Icon(icon, size: 18),
        label: Text(actionLabel),
      ),
    );
  }
}

/// 设置分组入口行，点击进入对应二级页面
class _GroupEntry extends StatelessWidget {
  const _GroupEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.groupId,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String groupId;

  @override
  Widget build(BuildContext context) {
    return SettingsGroupEntry(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: () => context.push('${app_paths.SETTINGS_GROUP_PAGE}/$groupId'),
    );
  }
}

/// 设置二级页面：分组内容
class SettingsGroupPage extends StatelessWidget {
  const SettingsGroupPage({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context) {
    final group = _settingsGroups[groupId];
    return PageScaffold(
      title: group?.title ?? '设置',
      subtitle: group?.subtitle,
      actions: const [],
      body: group?.body ?? const SizedBox.shrink(),
    );
  }
}

class _SettingsGroupDesc {
  final String title;
  final String subtitle;
  final Widget body;

  const _SettingsGroupDesc(this.title, this.subtitle, this.body);
}

const _settingsGroups = <String, _SettingsGroupDesc>{
  'appearance-theme': _SettingsGroupDesc(
    '主题',
    '明暗模式、主题色与配色来源',
    _AppearanceThemeGroup(),
  ),
  'appearance-display': _SettingsGroupDesc(
    '显示模式',
    '明暗模式',
    _AppearanceDisplayGroup(),
  ),
  'appearance-color': _SettingsGroupDesc(
    '配色',
    '主题色生成方式与颜色来源',
    _AppearanceColorGroup(),
  ),
  'appearance-background': _SettingsGroupDesc(
    '应用背景',
    '背景图片、强度与模糊',
    _AppearanceBackgroundGroup(),
  ),
  'appearance-list': _SettingsGroupDesc(
    '界面动效',
    '滚动、交互与内容过渡',
    _AppearanceListGroup(),
  ),
  'appearance-monet': _SettingsGroupDesc(
    '播放界面配色',
    '主题色在播放界面的应用范围',
    _AppearanceMonetGroup(),
  ),
  'appearance-progress': _SettingsGroupDesc(
    '进度与顶部歌词',
    '波浪进度条与顶部歌词动画',
    _AppearanceProgressGroup(),
  ),
  'appearance-player': _SettingsGroupDesc(
    '播放界面',
    '进度条、歌词动画与控件配色',
    _AppearancePlayerGroup(),
  ),
  'lyric-source': _SettingsGroupDesc(
    '歌词来源',
    '本地歌词与在线歌词的获取顺序',
    _LyricSourceGroup(),
  ),
  'lyric-content': _SettingsGroupDesc(
    '歌词内容',
    '歌曲信息保留与文字转换',
    _LyricContentGroup(),
  ),
  'lyric-writing': _SettingsGroupDesc(
    '歌词写入',
    '标签写入与外部 LRC 文件保存',
    _LyricWritingGroup(),
  ),
  'lyric-effect': _SettingsGroupDesc(
    '显示效果',
    '逐字播放、注音与行动效',
    _LyricEffectGroup(),
  ),
  'playback-behavior': _SettingsGroupDesc(
    '播放行为',
    '音量增益与切歌过渡',
    _PlaybackBehaviorGroup(),
  ),
  'playback-control': _SettingsGroupDesc(
    '播放控制',
    '任务栏播放控制',
    _PlaybackControlGroup(),
  ),
  'desktop-basic': _SettingsGroupDesc(
    '歌词内容',
    '翻译、注音与信息显示',
    _DesktopBasicGroup(),
  ),
  'desktop-display': _SettingsGroupDesc(
    '布局与动画',
    '布局、对齐与切换动画',
    _DesktopDisplayGroup(),
  ),
  'desktop-window': _SettingsGroupDesc(
    '窗口行为',
    '隐藏、置顶与交互',
    _DesktopWindowGroup(),
  ),
  'desktop-style': _SettingsGroupDesc('文字样式', '字号、字重与描边', _DesktopStyleGroup()),
  'desktop-color': _SettingsGroupDesc('颜色', '主题色与自定义配色', _DesktopColorGroup()),
  'advanced-system': _SettingsGroupDesc(
    '系统行为',
    '关闭窗口行为与日志',
    _AdvancedSystemGroup(),
  ),
  'advanced-custom': _SettingsGroupDesc(
    '媒体解析',
    '艺术家名称的分隔规则',
    _AdvancedLibraryGroup(),
  ),
  'advanced-font': _SettingsGroupDesc('字体', '歌词与界面字体', _AdvancedFontGroup()),
};

/// 把桌面歌词配置同步到桌面歌词窗口
void syncDesktopLyricConfig(BuildContext context) {
  final settings = AppSettings.instance;
  final service = PlayService.instance.desktopLyricService;
  if (!service.isRunning) return;
  final scheme = Theme.of(context).colorScheme;
  final colors = resolveDesktopLyricColors(
    followThemeColor: settings.desktopFollowThemeColor,
    brightnessMode: settings.desktopLyricBrightnessMode,
    scheme: scheme,
    customPlayedColor: settings.desktopPlayedColor,
    customUnplayedColor: settings.desktopUnplayedColor,
  );
  service.sendConfig(
    lyricFontSize: settings.desktopLyricFontSize,
    translationFontSize: settings.desktopTranslationFontSize,
    lyricFontWeight: settings.desktopLyricFontWeight,
    showLyricTranslation: settings.desktopShowTranslation,
    showRoman: settings.showDesktopLyricRoman,
    romanPosition: settings.desktopLyricRomanPosition,
    translationPosition: settings.desktopUseVerticalDisplayMode
        ? settings.desktopLyricTranslationPosition
        : 1,
    showNowPlayingInfo: settings.desktopShowNowPlayingInfo,
    hideOnPause: settings.desktopHideOnPause,
    lyricTextAlign:
        settings.desktopShowDoubleLine && settings.desktopLyricTextAlign == 3
        ? 3
        : settings.desktopLyricTextAlign.clamp(0, 2).toInt(),
    lyricAnimation: settings.desktopLyricAnimation.index,
    enableStroke: settings.desktopEnableStroke,
    backgroundOpacity: settings.desktopBackgroundOpacity,
    playedColor: colors.played.toARGB32(),
    unplayedColor: colors.unplayed.toARGB32(),
    followThemeColor: settings.desktopFollowThemeColor,
    useLightOutline: shouldUseLightDesktopLyricOutline(colors.played),
    useVerticalDisplayMode: settings.desktopUseVerticalDisplayMode,
    showDoubleLine: settings.desktopShowDoubleLine,
    hoverHide: settings.desktopHoverHide,
    fullscreenHide: settings.desktopFullscreenHide,
    lineGap: settings.desktopLineGap,
    enablePinTop: settings.desktopEnablePinTop,
    useMultiLineMode: settings.desktopUseMultiLineMode,
    multiLineAnimation: settings.desktopMultiLineAnimation.index,
    hidePlayedLines: settings.desktopHidePlayedLines,
    fontOpacity: settings.desktopFontOpacity,
  );
}

/// 桌面歌词分组页公共行为：修改后保存并同步到桌面歌词窗口
mixin _DesktopLyricConfigMixin<T extends StatefulWidget> on State<T> {
  void updateDesktopLyricConfig(VoidCallback fn) {
    setState(fn);
    AppSettings.instance.saveSettings();
    syncDesktopLyricConfig(context);
  }
}

class _AppearanceDisplayGroup extends StatelessWidget {
  const _AppearanceDisplayGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('显示模式'),
        SizedBox(height: 4.0),
        _ThemeOptionControl(),
      ],
    );
  }
}

class _AppearanceThemeGroup extends StatelessWidget {
  const _AppearanceThemeGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('主题'),
        SizedBox(height: 4.0),
        _ThemeOptionControl(),
        SizedBox(height: 16.0),
        _ThemeColorModeControl(),
        SizedBox(height: 16.0),
        _ThemeColorSourceControl(),
      ],
    );
  }
}

class _AppearanceColorGroup extends StatelessWidget {
  const _AppearanceColorGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('配色'),
        SizedBox(height: 4.0),
        _ThemeColorModeControl(),
        SizedBox(height: 16.0),
        _ThemeColorSourceControl(),
      ],
    );
  }
}

class _AppearanceBackgroundGroup extends StatelessWidget {
  const _AppearanceBackgroundGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('应用背景'),
        SizedBox(height: 4.0),
        _AppBackgroundControl(),
      ],
    );
  }
}

class _AppearanceListGroup extends StatelessWidget {
  const _AppearanceListGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('界面动效'),
        SizedBox(height: 4.0),
        _MotionEffectSwitch(effect: _MotionEffect.stackedScroll),
        SizedBox(height: 16.0),
        _MotionEffectSwitch(effect: _MotionEffect.contentTransition),
        SizedBox(height: 16.0),
        _MotionEffectSwitch(effect: _MotionEffect.interactiveSurface),
        SizedBox(height: 16.0),
        _MotionEffectSwitch(effect: _MotionEffect.detailHeaderCollapse),
        SizedBox(height: 16.0),
        _MotionEffectSwitch(effect: _MotionEffect.dataTransition),
      ],
    );
  }
}

class _AppearanceMonetGroup extends StatelessWidget {
  const _AppearanceMonetGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('播放界面配色'),
        SizedBox(height: 4.0),
        _MonetProgressBarSwitch(),
        SizedBox(height: 16.0),
        _MonetLyricsSwitch(),
        SizedBox(height: 16.0),
        _MonetTransitionSwitch(),
        SizedBox(height: 16.0),
        _MonetControlsSwitch(),
      ],
    );
  }
}

class _AlwaysShowNowPlayingControlsSwitch extends StatefulWidget {
  const _AlwaysShowNowPlayingControlsSwitch();

  @override
  State<_AlwaysShowNowPlayingControlsSwitch> createState() =>
      _AlwaysShowNowPlayingControlsSwitchState();
}

class _AlwaysShowNowPlayingControlsSwitchState
    extends State<_AlwaysShowNowPlayingControlsSwitch> {
  final settings = AppSettings.instance;

  Future<void> _setEnabled(bool value) async {
    setState(() => settings.alwaysShowNowPlayingControls = value);
    AppSettings.rebuildNotifier.rebuild();
    final saved = await settings.saveSettings();
    if (!saved && mounted) {
      setState(() => settings.alwaysShowNowPlayingControls = !value);
      AppSettings.rebuildNotifier.rebuild();
      showTextOnSnackBar('播放控件设置保存失败', variant: ToastVariant.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '始终显示播放控件',
      subtitle: settings.alwaysShowNowPlayingControls
          ? '播放页底部控件保持显示'
          : '鼠标移入播放页底部时显示控件',
      action: Switch(
        value: settings.alwaysShowNowPlayingControls,
        onChanged: _setEnabled,
      ),
    );
  }
}

class _AppearanceProgressGroup extends StatelessWidget {
  const _AppearanceProgressGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('进度与顶部歌词'),
        SizedBox(height: 4.0),
        _WavyProgressBarSwitch(),
        SizedBox(height: 16.0),
        _TopBarLyricAnimationSelector(),
      ],
    );
  }
}

class _AppearancePlayerGroup extends StatelessWidget {
  const _AppearancePlayerGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('播放界面'),
        SizedBox(height: 4.0),
        _WavyProgressBarSwitch(),
        SizedBox(height: 16.0),
        _MonetProgressBarSwitch(),
        SizedBox(height: 16.0),
        _TopBarLyricAnimationSelector(),
        SizedBox(height: 16.0),
        _MonetLyricsSwitch(),
        SizedBox(height: 16.0),
        _MonetTransitionSwitch(),
        SizedBox(height: 16.0),
        _MonetControlsSwitch(),
        SizedBox(height: 16.0),
        _AlwaysShowNowPlayingControlsSwitch(),
      ],
    );
  }
}

class _LyricSourceGroup extends StatelessWidget {
  const _LyricSourceGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('来源'),
        SizedBox(height: 4.0),
        DefaultLyricSourceControl(),
      ],
    );
  }
}

class _LyricContentGroup extends StatefulWidget {
  const _LyricContentGroup();

  @override
  State<_LyricContentGroup> createState() => _LyricContentGroupState();
}

class _LyricContentGroupState extends State<_LyricContentGroup> {
  final settings = AppSettings.instance;

  Future<void> _setZhConversionMode(ZhConversionMode mode) async {
    if (mode == settings.zhConversionMode) return;
    setState(() => settings.zhConversionMode = mode);
    LyricViewController.instance.triggerRebuild();
    await settings.saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        const _SettingsSectionHeader('歌曲信息'),
        const SizedBox(height: 4.0),
        SettingsTile(
          description: '保留歌词歌曲信息',
          subtitle: settings.keepLyricMetadata ? '显示词曲作者等信息' : '隐藏歌曲信息',
          action: Switch(
            value: settings.keepLyricMetadata,
            onChanged: (value) {
              setState(() => settings.keepLyricMetadata = value);
              settings.saveSettings();
              PlayService.instance.lyricService
                  .reloadAfterMetadataSettingChange();
            },
          ),
        ),
        const SizedBox(height: 24.0),
        const _SettingsSectionHeader('文字转换'),
        const SizedBox(height: 4.0),
        SettingsTile(
          description: '歌词转换',
          action: SegmentedButton<ZhConversionMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ZhConversionMode.none, label: Text('不转换')),
              ButtonSegment(
                value: ZhConversionMode.traditionalToSimplified,
                label: Text('繁转简'),
              ),
              ButtonSegment(
                value: ZhConversionMode.simplifiedToTraditional,
                label: Text('简转繁'),
              ),
            ],
            selected: {settings.zhConversionMode},
            onSelectionChanged: (selection) =>
                _setZhConversionMode(selection.first),
          ),
        ),
      ],
    );
  }
}

class _LyricWritingGroup extends StatefulWidget {
  const _LyricWritingGroup();

  @override
  State<_LyricWritingGroup> createState() => _LyricWritingGroupState();
}

class _LyricWritingGroupState extends State<_LyricWritingGroup> {
  final settings = AppSettings.instance;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        const _SettingsSectionHeader('写入方式'),
        const SizedBox(height: 4.0),
        if (!enableOnlineLyricWriting)
          const SettingsEmptyState(
            icon: Symbols.lyrics,
            title: '在线歌词写入未启用',
            subtitle: '当前版本未开放在线歌词写入设置',
          )
        else ...[
          SettingsTile(
            description: '写入格式',
            subtitle: '决定歌词写入标签或导出 LRC 时的格式',
            action: SegmentedButton<LyricTagWordFormat>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: LyricTagWordFormat.standard,
                  label: Text('标准 LRC'),
                ),
                ButtonSegment(
                  value: LyricTagWordFormat.wordByWord,
                  label: Text('逐字 LRC'),
                ),
                ButtonSegment(
                  value: LyricTagWordFormat.enhanced,
                  label: Text('增强 LRC'),
                ),
              ],
              selected: {settings.lyricTagWordFormat},
              onSelectionChanged: (selection) {
                setState(() => settings.lyricTagWordFormat = selection.first);
                settings.saveSettings();
              },
            ),
          ),
          const SizedBox(height: 16.0),
          SettingsTile(
            description: '写入翻译',
            subtitle: '歌词写入时附带翻译行',
            action: Switch(
              value: settings.lyricTagIncludeTranslation,
              onChanged: (value) {
                setState(() => settings.lyricTagIncludeTranslation = value);
                settings.saveSettings();
              },
            ),
          ),
          const SizedBox(height: 16.0),
          SettingsTile(
            description: '写入罗马音',
            subtitle: '歌词写入时附带罗马音行',
            action: Switch(
              value: settings.lyricTagIncludeRomanization,
              onChanged: (value) {
                setState(() => settings.lyricTagIncludeRomanization = value);
                settings.saveSettings();
              },
            ),
          ),
          const SizedBox(height: 24.0),
          const _SettingsSectionHeader('自动化'),
          const SizedBox(height: 4.0),
          SettingsTile(
            description: '获取网络歌词后自动写入标签',
            subtitle: '开启后静默写入，不再弹窗询问',
            action: Switch(
              value: settings.autoWriteLyricToTag,
              onChanged: (value) {
                setState(() => settings.autoWriteLyricToTag = value);
                settings.saveSettings();
                PlayService.instance.lyricService.resetLyricWritePrompts();
              },
            ),
          ),
          const SizedBox(height: 16.0),
          SettingsTile(
            description: settings.autoWriteLyricToTag ? '自动写入延迟' : '提示延迟',
            subtitle: settings.autoWriteLyricToTag
                ? '获取歌词后等待 ${settings.autoWriteLyricToTagDelay} 秒再写入'
                : '获取歌词后等待 ${settings.promptWriteLyricToTagDelay} 秒再提示',
            action: SizedBox(
              width: 140,
              child: Slider(
                value:
                    (settings.autoWriteLyricToTag
                            ? settings.autoWriteLyricToTagDelay
                            : settings.promptWriteLyricToTagDelay)
                        .toDouble(),
                min: settings.autoWriteLyricToTag ? 10 : 5,
                max: settings.autoWriteLyricToTag ? 120 : 60,
                divisions: 11,
                label:
                    '${settings.autoWriteLyricToTag ? settings.autoWriteLyricToTagDelay : settings.promptWriteLyricToTagDelay}秒',
                onChanged: (value) {
                  setState(() {
                    if (settings.autoWriteLyricToTag) {
                      settings.autoWriteLyricToTagDelay = value.round();
                    } else {
                      settings.promptWriteLyricToTagDelay = value.round();
                    }
                  });
                  settings.saveSettings();
                },
              ),
            ),
          ),
          const SizedBox(height: 16.0),
          SettingsTile(
            description: '自动保存外部 LRC',
            subtitle: '保存到歌曲目录，覆盖前备份原文件',
            action: Switch(
              value: settings.autoSaveExternalLyric,
              onChanged: (value) {
                setState(() => settings.autoSaveExternalLyric = value);
                settings.saveSettings();
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _LyricEffectGroup extends StatelessWidget {
  const _LyricEffectGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('显示效果'),
        SizedBox(height: 4.0),
        _GlowEffectSwitch(),
        SizedBox(height: 16.0),
        _RubyPositionSetting(),
        SizedBox(height: 16.0),
        _StaggerStyleSelector(),
        SizedBox(height: 16.0),
        _LiftStyleSelector(),
      ],
    );
  }
}

class _PlaybackBehaviorGroup extends StatelessWidget {
  const _PlaybackBehaviorGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('播放行为'),
        SizedBox(height: 4.0),
        ReplayGainControl(),
        SizedBox(height: 16.0),
        TransitionControl(),
      ],
    );
  }
}

class _PlaybackControlGroup extends StatelessWidget {
  const _PlaybackControlGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('播放控制'),
        SizedBox(height: 4.0),
        _TaskbarThumbnailControl(),
      ],
    );
  }
}

class _DesktopBasicGroup extends StatefulWidget {
  const _DesktopBasicGroup();

  @override
  State<_DesktopBasicGroup> createState() => _DesktopBasicGroupState();
}

class _DesktopBasicGroupState extends State<_DesktopBasicGroup>
    with _DesktopLyricConfigMixin {
  final settings = AppSettings.instance;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        const _SettingsSectionHeader('歌词内容'),
        const SizedBox(height: 4.0),
        SettingsTile(
          description: '歌词翻译',
          action: Switch(
            value: settings.desktopShowTranslation,
            onChanged: (v) => updateDesktopLyricConfig(
              () => settings.desktopShowTranslation = v,
            ),
          ),
        ),
        const SizedBox(height: 16),
        SettingsTile(
          description: '注音',
          action: Switch(
            value: settings.showDesktopLyricRoman,
            onChanged: (v) => updateDesktopLyricConfig(
              () => settings.showDesktopLyricRoman = v,
            ),
          ),
        ),
        const SizedBox(height: 16),
        SettingsTile(
          description: '歌曲信息',
          subtitle: settings.desktopShowNowPlayingInfo ? '显示歌曲标题和艺人' : '隐藏',
          action: Switch(
            value: settings.desktopShowNowPlayingInfo,
            onChanged: (v) => updateDesktopLyricConfig(
              () => settings.desktopShowNowPlayingInfo = v,
            ),
          ),
        ),
      ],
    );
  }
}

class _DesktopDisplayGroup extends StatefulWidget {
  const _DesktopDisplayGroup();

  @override
  State<_DesktopDisplayGroup> createState() => _DesktopDisplayGroupState();
}

class _DesktopDisplayGroupState extends State<_DesktopDisplayGroup>
    with _DesktopLyricConfigMixin {
  final settings = AppSettings.instance;

  @override
  Widget build(BuildContext context) {
    const animationItems = {
      DesktopLyricAnimation.slideUp: '上划',
      DesktopLyricAnimation.slideDown: '下划',
      DesktopLyricAnimation.slideLeft: '左划',
      DesktopLyricAnimation.slideRight: '右划',
      DesktopLyricAnimation.fade: '淡入淡出',
      DesktopLyricAnimation.absorb: '吸收',
    };
    final showTranslationPosition =
        settings.desktopShowTranslation &&
        settings.desktopUseVerticalDisplayMode;
    final showRomanPosition = settings.showDesktopLyricRoman;
    final showLineGap = settings.desktopUseMultiLineMode;
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        const _SettingsSectionHeader('布局与动画'),
        const SizedBox(height: 4.0),
        if (showTranslationPosition) ...[
          SettingsTile(
            description: '翻译位置',
            action: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, label: Text('原文之前')),
                ButtonSegment(value: 1, label: Text('原文之后')),
              ],
              selected: {settings.desktopLyricTranslationPosition},
              onSelectionChanged: (v) => updateDesktopLyricConfig(
                () => settings.desktopLyricTranslationPosition = v.first,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (showRomanPosition) ...[
          SettingsTile(
            description: '注音位置',
            action: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(value: 0, label: Text('歌词上方')),
                const ButtonSegment(value: 1, label: Text('歌词下方')),
                if (settings.desktopShowTranslation)
                  const ButtonSegment(value: 2, label: Text('翻译下方')),
              ],
              selected: {
                settings.desktopShowTranslation ||
                        settings.desktopLyricRomanPosition != 2
                    ? settings.desktopLyricRomanPosition
                    : 1,
              },
              onSelectionChanged: (v) => updateDesktopLyricConfig(
                () => settings.desktopLyricRomanPosition = v.first,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        const SizedBox(height: 16),
        SettingsTile(
          description: '竖排显示',
          subtitle: '歌词逐字竖排，英文和数字横排旋转',
          action: Switch(
            value: settings.desktopUseVerticalDisplayMode,
            onChanged: (v) => updateDesktopLyricConfig(
              () => settings.desktopUseVerticalDisplayMode = v,
            ),
          ),
        ),
        const SizedBox(height: 16),
        SettingsTile(
          description: '双行显示',
          subtitle: '同时显示当前行和下一行歌词',
          action: Switch(
            value: settings.desktopShowDoubleLine,
            onChanged: (v) => updateDesktopLyricConfig(() {
              settings.desktopShowDoubleLine = v;
              if (!v && settings.desktopLyricTextAlign == 3) {
                settings.desktopLyricTextAlign = 1;
              }
            }),
          ),
        ),
        const SizedBox(height: 16),
        SettingsTile(
          description: '多行模式',
          action: Switch(
            value: settings.desktopUseMultiLineMode,
            onChanged: (v) => updateDesktopLyricConfig(
              () => settings.desktopUseMultiLineMode = v,
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (showLineGap) ...[
          SettingsTile(
            description: '歌词行距',
            subtitle: '${settings.desktopLineGap.toStringAsFixed(0)}px',
            action: SizedBox(
              width: 180,
              child: Slider(
                value: settings.desktopLineGap,
                min: 0,
                max: 16,
                divisions: 16,
                label: '${settings.desktopLineGap.toStringAsFixed(0)}px',
                onChanged: (v) {
                  setState(() => settings.desktopLineGap = v);
                  syncDesktopLyricConfig(context);
                },
                onChangeEnd: (_) => settings.saveSettings(),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        SettingsTile(
          description: '文字对齐',
          action: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(value: 0, label: Text('左')),
              const ButtonSegment(value: 1, label: Text('中')),
              const ButtonSegment(value: 2, label: Text('右')),
              if (settings.desktopShowDoubleLine)
                const ButtonSegment(value: 3, label: Text('交错')),
            ],
            selected: {
              settings.desktopShowDoubleLine ||
                      settings.desktopLyricTextAlign != 3
                  ? settings.desktopLyricTextAlign
                  : 1,
            },
            onSelectionChanged: (v) => updateDesktopLyricConfig(
              () => settings.desktopLyricTextAlign = v.first,
            ),
          ),
        ),
        const SizedBox(height: 16),
        SettingsTile(
          description: '桌面歌词切换动画',
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<DesktopLyricAnimation>(
                  segments: [
                    for (final entry in animationItems.entries)
                      ButtonSegment(value: entry.key, label: Text(entry.value)),
                  ],
                  selected: {settings.desktopLyricAnimation},
                  onSelectionChanged: (value) => updateDesktopLyricConfig(
                    () => settings.desktopLyricAnimation = value.first,
                  ),
                  showSelectedIcon: false,
                ),
              ),
            ],
          ),
        ),
        if (settings.desktopUseMultiLineMode) ...[
          const SizedBox(height: 16),
          SettingsTile(
            description: '隐藏已播放歌词',
            action: Switch(
              value: settings.desktopHidePlayedLines,
              onChanged: (value) => updateDesktopLyricConfig(
                () => settings.desktopHidePlayedLines = value,
              ),
            ),
          ),
          const SizedBox(height: 16),
          SettingsTile(
            description: '多行模式行切换动画',
            action: SegmentedButton<LyricStaggerStyle>(
              segments: const [
                ButtonSegment(
                  value: LyricStaggerStyle.smooth,
                  label: Text('平滑'),
                ),
                ButtonSegment(
                  value: LyricStaggerStyle.spring,
                  label: Text('弹簧'),
                ),
              ],
              selected: {settings.desktopMultiLineAnimation},
              onSelectionChanged: (value) => updateDesktopLyricConfig(
                () => settings.desktopMultiLineAnimation = value.first,
              ),
              showSelectedIcon: false,
            ),
          ),
        ],
      ],
    );
  }
}

class _DesktopWindowGroup extends StatefulWidget {
  const _DesktopWindowGroup();

  @override
  State<_DesktopWindowGroup> createState() => _DesktopWindowGroupState();
}

class _DesktopWindowGroupState extends State<_DesktopWindowGroup>
    with _DesktopLyricConfigMixin {
  final settings = AppSettings.instance;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        const _SettingsSectionHeader('窗口行为'),
        const SizedBox(height: 4.0),
        SettingsTile(
          description: '暂停时隐藏桌面歌词',
          action: Switch(
            value: settings.desktopHideOnPause,
            onChanged: (v) =>
                updateDesktopLyricConfig(() => settings.desktopHideOnPause = v),
          ),
        ),
        const SizedBox(height: 16),
        SettingsTile(
          description: '锁定时鼠标移入显示',
          action: Switch(
            value: settings.desktopHoverHide,
            onChanged: (v) =>
                updateDesktopLyricConfig(() => settings.desktopHoverHide = v),
          ),
        ),
        const SizedBox(height: 16),
        SettingsTile(
          description: '全屏时隐藏桌面歌词',
          action: Switch(
            value: settings.desktopFullscreenHide,
            onChanged: (v) => updateDesktopLyricConfig(
              () => settings.desktopFullscreenHide = v,
            ),
          ),
        ),
        const SizedBox(height: 16),
        SettingsTile(
          description: '置顶显示',
          action: Switch(
            value: settings.desktopEnablePinTop,
            onChanged: (v) => updateDesktopLyricConfig(
              () => settings.desktopEnablePinTop = v,
            ),
          ),
        ),
      ],
    );
  }
}

class _DesktopStyleGroup extends StatefulWidget {
  const _DesktopStyleGroup();

  @override
  State<_DesktopStyleGroup> createState() => _DesktopStyleGroupState();
}

class _DesktopStyleGroupState extends State<_DesktopStyleGroup>
    with _DesktopLyricConfigMixin {
  final settings = AppSettings.instance;

  void _saveAndSync() {
    settings.saveSettings();
    syncDesktopLyricConfig(context);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        const _SettingsSectionHeader('文字样式'),
        const SizedBox(height: 8),
        const _DesktopLyricPreview(),
        const SizedBox(height: 16),
        SettingsTile(
          description: '歌词字号',
          subtitle: '${settings.desktopLyricFontSize.toStringAsFixed(0)}px',
          action: SizedBox(
            width: 160,
            child: Slider(
              value: settings.desktopLyricFontSize,
              min: 14,
              max: 48,
              divisions: 34,
              label: '${settings.desktopLyricFontSize.toStringAsFixed(0)}px',
              onChanged: (v) => setState(() {
                settings.desktopLyricFontSize = v;
                settings.desktopTranslationFontSize = (v - 4).clamp(10, 44);
              }),
              onChangeEnd: (_) => _saveAndSync(),
            ),
          ),
        ),
        const SizedBox(height: 16),
        SettingsTile(
          description: '翻译/注音字号',
          subtitle:
              '${settings.desktopTranslationFontSize.toStringAsFixed(0)}px',
          action: SizedBox(
            width: 160,
            child: Slider(
              value: settings.desktopTranslationFontSize,
              min: 10,
              max: 44,
              divisions: 34,
              label:
                  '${settings.desktopTranslationFontSize.toStringAsFixed(0)}px',
              onChanged: (v) =>
                  setState(() => settings.desktopTranslationFontSize = v),
              onChangeEnd: (_) => _saveAndSync(),
            ),
          ),
        ),
        const SizedBox(height: 16),
        SettingsTile(
          description: '字重',
          subtitle: '${settings.desktopLyricFontWeight}',
          action: SizedBox(
            width: 160,
            child: Slider(
              value: settings.desktopLyricFontWeight.toDouble(),
              min: 100,
              max: 900,
              divisions: 8,
              label: '${settings.desktopLyricFontWeight}',
              onChanged: (v) =>
                  setState(() => settings.desktopLyricFontWeight = v.round()),
              onChangeEnd: (_) => _saveAndSync(),
            ),
          ),
        ),
        const SizedBox(height: 16),
        SettingsTile(
          description: '字体不透明度',
          subtitle: '${(settings.desktopFontOpacity * 100).round()}%',
          action: SizedBox(
            width: 160,
            child: Slider(
              value: settings.desktopFontOpacity,
              min: 0,
              max: 1,
              divisions: 20,
              label: '${(settings.desktopFontOpacity * 100).round()}%',
              onChanged: (value) {
                setState(() => settings.desktopFontOpacity = value);
                syncDesktopLyricConfig(context);
              },
              onChangeEnd: (_) => settings.saveSettings(),
            ),
          ),
        ),
        const SizedBox(height: 16),
        SettingsTile(
          description: '文字描边',
          action: Switch(
            value: settings.desktopEnableStroke,
            onChanged: (value) => updateDesktopLyricConfig(
              () => settings.desktopEnableStroke = value,
            ),
          ),
        ),
      ],
    );
  }
}

class _DesktopColorGroup extends StatefulWidget {
  const _DesktopColorGroup();

  @override
  State<_DesktopColorGroup> createState() => _DesktopColorGroupState();
}

class _DesktopColorGroupState extends State<_DesktopColorGroup> {
  final settings = AppSettings.instance;
  double _playedOpacity = 1.0;
  double _unplayedOpacity = 1.0;

  @override
  void initState() {
    super.initState();
    _playedOpacity = _alphaFromColor(settings.desktopPlayedColor);
    _unplayedOpacity = _alphaFromColor(settings.desktopUnplayedColor);
  }

  double _alphaFromColor(int? color) {
    if (color == null) return 1.0;
    return ((color >> 24) & 0xFF) / 255.0;
  }

  Future<void> _pickDesktopColor(
    int? current,
    double opacity,
    ValueChanged<int> onPicked,
    ValueChanged<double> onChangedOpacity,
  ) async {
    final initial = current != null
        ? Color(current.toUnsigned(32))
        : Theme.of(context).colorScheme.primary;
    final result = await showDialog<_DesktopColorResult>(
      context: context,
      builder: (context) => _DesktopColorPickerDialog(
        initialColor: initial,
        initialOpacity: opacity,
        label: '选择颜色',
      ),
    );
    if (!mounted || result == null) return;
    final alpha = (result.opacity * 255).round().clamp(0, 255);
    final argb = (alpha << 24) | (result.color.toARGB32() & 0x00FFFFFF);
    _update(() {
      onPicked(argb);
      onChangedOpacity(result.opacity);
    });
  }

  void _update(VoidCallback fn) {
    setState(fn);
    AppSettings.instance.saveSettings();
    syncDesktopLyricConfig(context);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        const _SettingsSectionHeader('颜色'),
        const SizedBox(height: 4.0),
        SettingsTile(
          description: '跟随主题色',
          action: Switch(
            value: settings.desktopFollowThemeColor,
            onChanged: (v) => _update(() {
              settings.desktopFollowThemeColor = v;
            }),
          ),
        ),
        if (!settings.desktopFollowThemeColor) ...[
          const SizedBox(height: 16),
          SettingsTile(
            description: '明暗配色',
            action: SegmentedButton<DesktopLyricBrightnessMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: DesktopLyricBrightnessMode.follow,
                  label: Text('跟随'),
                ),
                ButtonSegment(
                  value: DesktopLyricBrightnessMode.light,
                  label: Text('浅色'),
                ),
                ButtonSegment(
                  value: DesktopLyricBrightnessMode.dark,
                  label: Text('深色'),
                ),
              ],
              selected: {settings.desktopLyricBrightnessMode},
              onSelectionChanged: (value) => _update(() {
                settings.desktopLyricBrightnessMode = value.first;
                settings.desktopPlayedColor = null;
                settings.desktopUnplayedColor = null;
                _playedOpacity = 1.0;
                _unplayedOpacity = 1.0;
              }),
            ),
          ),
          const SizedBox(height: 16),
          _DesktopColorSetting(
            label: '已播放颜色',
            color: settings.desktopPlayedColor,
            opacity: _playedOpacity,
            onPickColor: () => _pickDesktopColor(
              settings.desktopPlayedColor,
              _playedOpacity,
              (color) => settings.desktopPlayedColor = color,
              (opacity) => _playedOpacity = opacity,
            ),
          ),
          const SizedBox(height: 16),
          _DesktopColorSetting(
            label: '未播放颜色',
            color: settings.desktopUnplayedColor,
            opacity: _unplayedOpacity,
            onPickColor: () => _pickDesktopColor(
              settings.desktopUnplayedColor,
              _unplayedOpacity,
              (color) => settings.desktopUnplayedColor = color,
              (opacity) => _unplayedOpacity = opacity,
            ),
          ),
        ],
      ],
    );
  }
}

class _AdvancedSystemGroup extends StatelessWidget {
  const _AdvancedSystemGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('系统行为'),
        SizedBox(height: 4.0),
        _WindowCloseBehaviorControl(),
        SizedBox(height: 16.0),
        AudioEchoLogRecordControl(),
      ],
    );
  }
}

class _AdvancedLibraryGroup extends StatelessWidget {
  const _AdvancedLibraryGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('媒体解析'),
        SizedBox(height: 4.0),
        ArtistSeparatorEditor(),
      ],
    );
  }
}

class _AdvancedFontGroup extends StatelessWidget {
  const _AdvancedFontGroup();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _SettingsSectionHeader('字体'),
        SizedBox(height: 4.0),
        SelectFontCombobox(),
      ],
    );
  }
}
