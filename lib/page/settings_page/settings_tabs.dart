import 'dart:io';

import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/setting_action_state.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/zh_converter.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/native/rust/api/installed_font.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/settings_page/check_update.dart';
import 'package:pure_music/page/settings_page/create_issue.dart';
import 'package:pure_music/page/settings_page/artist_separator_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

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
    _SettingsTab('高级', Symbols.settings),
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
            final canSwitch =
                canSwitchTab(currentIndex: _currentIndex, targetIndex: i);
            return OutlinedButton.icon(
              onPressed:
                  canSwitch ? () => setState(() => _currentIndex = i) : null,
              icon: Icon(_tabs[i].icon, size: 18),
              label: Text(_tabs[i].label),
              style: ButtonStyle(
                foregroundColor: WidgetStatePropertyAll(
                  selected ? scheme.onPrimary : scheme.onSurface,
                ),
                backgroundColor: WidgetStatePropertyAll(
                  selected ? scheme.primary : Colors.transparent,
                ),
                side: WidgetStatePropertyAll(
                  BorderSide(
                    color: selected ? scheme.primary : scheme.outline,
                  ),
                ),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 24.0),
        Expanded(
          child: IndexedStack(
            index: _currentIndex,
            children: const [
              _AppearanceTabContent(),
              _LyricsTabContent(),
              _AdvancedTabContent(),
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
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        _ThemeOptionControl(),
        SizedBox(height: 16.0),
        NowPlayingBackgroundModeToggle(),
        SizedBox(height: 16.0),
        _MonetProgressBarSwitch(),
        SizedBox(height: 16.0),
        _WavyProgressBarSwitch(),
        SizedBox(height: 16.0),
        _TopBarLyricAnimationSelector(),
        SizedBox(height: 16.0),
        _MonetTransitionSwitch(),
        SizedBox(height: 16.0),
        _MonetControlsSwitch(),
        SizedBox(height: 16.0),
        _CoverColorExtractionSwitch(),
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
  bool _isSaving = false;

  Future<void> _setThemeOption(ThemeOption option) async {
    if (_isSaving || option == settings.themeOption) return;
    setState(() {
      _isSaving = true;
      settings.themeOption = option;
    });
    ThemeProvider.instance.applyThemeOption(option);
    try {
      await settings.saveSettings();
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '主题',
      subtitle: _isSaving ? '保存中' : null,
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isSaving) ...[
            const SizedBox(
              width: 16.0,
              height: 16.0,
              child: CircularProgressIndicator(strokeWidth: 2.0),
            ),
            const SizedBox(width: 10.0),
          ],
          SegmentedButton<ThemeOption>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeOption.system, label: Text('跟随系统')),
              ButtonSegment(value: ThemeOption.light, label: Text('浅色模式')),
              ButtonSegment(value: ThemeOption.dark, label: Text('深色模式')),
            ],
            selected: {settings.themeOption},
            onSelectionChanged: _isSaving
                ? null
                : (selected) => _setThemeOption(selected.first),
          ),
        ],
      ),
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
  bool _isSaving = false;

  Future<void> _setEnabled(bool value) async {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
      settings.useMaterialYouForProgressBar = value;
    });
    try {
      await settings.saveSettings();
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '主题色进度条',
      subtitle: _isSaving ? '保存中' : '进度条使用主题色渲染',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isSaving) ...[
            const SizedBox(
              width: 16.0,
              height: 16.0,
              child: CircularProgressIndicator(strokeWidth: 2.0),
            ),
            const SizedBox(width: 8.0),
          ],
          Switch(
            value: settings.useMaterialYouForProgressBar,
            onChanged: _isSaving ? null : _setEnabled,
          ),
        ],
      ),
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
  NowPlayingMode? _savingMode;

  Future<void> _setWavyBarMode(NowPlayingMode mode, bool enabled) async {
    if (_savingMode != null) return;
    setState(() {
      _savingMode = mode;
      if (enabled) {
        settings.wavyBarEnabledModes.add(mode);
      } else {
        settings.wavyBarEnabledModes.remove(mode);
      }
    });
    try {
      await settings.saveSettings();
    } finally {
      if (mounted) {
        setState(() => _savingMode = null);
      }
    }
  }

  Widget _savingSwitch({
    required NowPlayingMode mode,
    required bool value,
  }) {
    final isSavingThis = _savingMode == mode;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isSavingThis) ...[
          const SizedBox(
            width: 16.0,
            height: 16.0,
            child: CircularProgressIndicator(strokeWidth: 2.0),
          ),
          const SizedBox(width: 8.0),
        ],
        Switch(
          value: value,
          onChanged:
              _savingMode == null ? (v) => _setWavyBarMode(mode, v) : null,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final savingPortrait = _savingMode == NowPlayingMode.portrait;
    final savingImmersive = _savingMode == NowPlayingMode.immersive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: Text(
            '波浪进度条',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface, fontSize: 18.0),
          ),
        ),
        SettingsTile(
          description: '竖屏播放页',
          subtitle: savingPortrait ? '保存中' : null,
          action: _savingSwitch(
            mode: NowPlayingMode.portrait,
            value:
                settings.wavyBarEnabledModes.contains(NowPlayingMode.portrait),
          ),
        ),
        const SizedBox(height: 8.0),
        SettingsTile(
          description: '横屏沉浸模式',
          subtitle: savingImmersive ? '保存中' : null,
          action: _savingSwitch(
            mode: NowPlayingMode.immersive,
            value:
                settings.wavyBarEnabledModes.contains(NowPlayingMode.immersive),
          ),
        ),
      ],
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
  bool _isSaving = false;

  Future<void> _setAnimation(TopBarLyricAnimation animation) async {
    if (_isSaving || animation == settings.topBarLyricAnimation) return;
    setState(() {
      _isSaving = true;
      settings.topBarLyricAnimation = animation;
    });
    try {
      await settings.saveSettings();
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const row1 = {
      TopBarLyricAnimation.slideUp: '上划',
      TopBarLyricAnimation.slideDown: '下划',
      TopBarLyricAnimation.slideLeft: '左划',
      TopBarLyricAnimation.slideRight: '右划',
    };
    const row2 = {
      TopBarLyricAnimation.fade: '淡入淡出',
      TopBarLyricAnimation.absorb: '吸收',
      TopBarLyricAnimation.flipX: 'X 翻转',
      TopBarLyricAnimation.flipY: 'Y 翻转',
    };

    final current = settings.topBarLyricAnimation;

    Widget segRow(Map<TopBarLyricAnimation, String> items) {
      return SizedBox(
        width: double.infinity,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<TopBarLyricAnimation>(
            segments: [
              for (final e in items.entries)
                ButtonSegment(value: e.key, label: Text(e.value)),
            ],
            selected: {current},
            onSelectionChanged:
                _isSaving ? null : (v) => _setAnimation(v.first),
            showSelectedIcon: false,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '顶部歌词切换动画',
                style: TextStyle(color: scheme.onSurface, fontSize: 18.0),
              ),
              if (_isSaving) ...[
                const SizedBox(width: 10.0),
                SizedBox(
                  width: 14.0,
                  height: 14.0,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.0,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 6.0),
                Text(
                  '保存中',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13.0,
                  ),
                ),
              ],
            ],
          ),
        ),
        segRow(row1),
        const SizedBox(height: 8.0),
        segRow(row2),
      ],
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
  bool _isSaving = false;

  Future<void> _setEnabled(bool value) async {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
      settings.useMaterialYouForLyrics = value;
    });
    LyricViewController.instance.triggerRebuild();
    try {
      await settings.saveSettings();
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '主题色歌词',
      subtitle: _isSaving ? '保存中' : '歌词使用主题色渲染',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isSaving) ...[
            const SizedBox(
              width: 16.0,
              height: 16.0,
              child: CircularProgressIndicator(strokeWidth: 2.0),
            ),
            const SizedBox(width: 8.0),
          ],
          Switch(
            value: settings.useMaterialYouForLyrics,
            onChanged: _isSaving ? null : _setEnabled,
          ),
        ],
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
  bool _isSaving = false;

  Future<void> _setEnabled(bool value) async {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
      settings.useMaterialYouForTransition = value;
    });
    LyricViewController.instance.triggerRebuild();
    try {
      await settings.saveSettings();
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '主题色间奏动画',
      subtitle: _isSaving ? '保存中' : '间奏动画使用主题色渲染',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isSaving) ...[
            const SizedBox(
              width: 16.0,
              height: 16.0,
              child: CircularProgressIndicator(strokeWidth: 2.0),
            ),
            const SizedBox(width: 8.0),
          ],
          Switch(
            value: settings.useMaterialYouForTransition,
            onChanged: _isSaving ? null : _setEnabled,
          ),
        ],
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
  bool _isSaving = false;

  Future<void> _setEnabled(bool value) async {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
      settings.useMaterialYouForControls = value;
    });
    AppSettings.rebuildNotifier.rebuild();
    try {
      await settings.saveSettings();
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '主题色控件',
      subtitle: _isSaving ? '保存中' : '播放页控件使用主题色渲染',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isSaving) ...[
            const SizedBox(
              width: 16.0,
              height: 16.0,
              child: CircularProgressIndicator(strokeWidth: 2.0),
            ),
            const SizedBox(width: 8.0),
          ],
          Switch(
            value: settings.useMaterialYouForControls,
            onChanged: _isSaving ? null : _setEnabled,
          ),
        ],
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
  bool _isSaving = false;

  Future<void> _setEnabled(bool value) async {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
      nowPlayingPagePref.enableLyricGlow = value;
    });
    LyricViewController.instance.enableLyricGlow = value;
    LyricViewController.instance.triggerRebuild();
    try {
      await AppPreference.instance.save();
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '辉光缩放效果（实验性）',
      subtitle: _isSaving ? '保存中' : '逐字播放时的辉光缩放动画',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isSaving) ...[
            const SizedBox(
              width: 16.0,
              height: 16.0,
              child: CircularProgressIndicator(strokeWidth: 2.0),
            ),
            const SizedBox(width: 8.0),
          ],
          Switch(
            value: nowPlayingPagePref.enableLyricGlow,
            onChanged: _isSaving ? null : _setEnabled,
          ),
        ],
      ),
    );
  }
}

class _CoverColorExtractionSwitch extends StatefulWidget {
  const _CoverColorExtractionSwitch();

  @override
  State<_CoverColorExtractionSwitch> createState() =>
      _CoverColorExtractionSwitchState();
}

class _CoverColorExtractionSwitchState
    extends State<_CoverColorExtractionSwitch> {
  final settings = AppSettings.instance;
  bool _isPickingColor = false;
  bool _isSavingCustomColor = false;
  bool _isSavingAutoMode = false;

  bool get _isBusy =>
      _isPickingColor || _isSavingCustomColor || _isSavingAutoMode;

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
    if (_isBusy) return;
    setState(() => _isPickingColor = true);
    try {
      final result = await _openColorPicker();
      if (result == null || !mounted) return;
      setState(() {
        _isPickingColor = false;
        _isSavingCustomColor = true;
        settings.customCoverColor = result.toARGB32();
      });
      _refreshTheme();
      await settings.saveSettings();
    } finally {
      if (mounted) {
        setState(() {
          _isPickingColor = false;
          _isSavingCustomColor = false;
        });
      }
    }
  }

  Future<void> _setAutoExtraction(bool value) async {
    if (_isBusy) return;
    setState(() {
      _isSavingAutoMode = true;
      settings.enableCoverColorExtraction = value;
    });
    _refreshTheme();
    try {
      await settings.saveSettings();
    } finally {
      if (mounted) {
        setState(() => _isSavingAutoMode = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAuto = settings.enableCoverColorExtraction;
    final subtitle = _isSavingAutoMode || _isSavingCustomColor
        ? '保存中'
        : isAuto
            ? '从专辑封面自动提取'
            : '自定义应用整体颜色';

    return SettingsTile(
      description: '应用主题色',
      subtitle: subtitle,
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isAuto)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: OutlinedButton.icon(
                onPressed: _isBusy ? null : _pickCustomColor,
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: _isPickingColor || _isSavingCustomColor
                    ? const SizedBox(
                        width: 16.0,
                        height: 16.0,
                        child: CircularProgressIndicator(strokeWidth: 2.0),
                      )
                    : const Icon(Symbols.palette),
                label: Text(
                  _isPickingColor
                      ? '选择中'
                      : _isSavingCustomColor
                          ? '保存中'
                          : '自定义',
                ),
              ),
            ),
          if (_isSavingAutoMode) ...[
            const SizedBox(
              width: 16.0,
              height: 16.0,
              child: CircularProgressIndicator(strokeWidth: 2.0),
            ),
            const SizedBox(width: 8.0),
          ],
          Switch(
            value: isAuto,
            onChanged: _isBusy ? null : _setAutoExtraction,
          ),
        ],
      ),
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
    final color =
        custom != null ? Color(custom) : Theme.of(context).colorScheme.primary;
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
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: pickerSize,
                  height: pickerSize * 0.7,
                  child: _HsvPicker(
                    hsv: _hsv,
                    onChanged: _updateColor,
                  ),
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
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        height: 20,
                        child: _HueSlider(
                          hue: _hsv.hue,
                          onChanged: (hue) => _updateColor(
                            _hsv.withHue(hue),
                          ),
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
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
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
                            borderRadius: BorderRadius.circular(8),
                          ),
                          hintText: 'RRGGBB',
                          hintStyle: TextStyle(
                            color:
                                scheme.onSurfaceVariant.withValues(alpha: 0.5),
                          ),
                        ),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 16,
                          letterSpacing: 1.2,
                        ),
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          UpperCaseTextFormatter(),
                          LengthLimitingTextInputFormatter(6),
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9A-Fa-f]')),
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
          onPressed:
              _hasValidHex ? () => Navigator.of(context).pop(color) : null,
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
            child: const RepaintBoundary(
              child: SizedBox.expand(),
            ),
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

class _LyricsTabContent extends StatefulWidget {
  const _LyricsTabContent();

  @override
  State<_LyricsTabContent> createState() => _LyricsTabContentState();
}

class _LyricsTabContentState extends State<_LyricsTabContent> {
  final settings = AppSettings.instance;
  bool _isSavingZhConversion = false;

  Future<void> _setZhConversionMode(ZhConversionMode mode) async {
    if (!canSaveChangedSetting(
      current: settings.zhConversionMode,
      next: mode,
      isSaving: _isSavingZhConversion,
    )) {
      return;
    }

    setState(() {
      _isSavingZhConversion = true;
      settings.zhConversionMode = mode;
    });
    LyricViewController.instance.triggerRebuild();
    try {
      await settings.saveSettings();
    } finally {
      if (mounted) {
        setState(() => _isSavingZhConversion = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        const DefaultLyricSourceControl(),
        const SizedBox(height: 16.0),
        // 注释：歌词模式设置暂时隐藏，功能未实现
        // 问题：用户设置后没有实际效果，渲染器直接根据歌词数据类型（SyncLyricLine/LrcLine）决定显示方式
        // TODO: 实现强制显示模式转换（例如：把逐字歌词降级显示为逐行）
        // SettingsTile(
        //   description: '歌词模式',
        //   subtitle: '获取到的网络歌词格式',
        //   action: SegmentedButton<LyricDisplayMode>(
        //     showSelectedIcon: false,
        //     segments: const [
        //       ButtonSegment<LyricDisplayMode>(
        //         value: LyricDisplayMode.lineByLine,
        //         label: Text('逐行歌词'),
        //       ),
        //       ButtonSegment<LyricDisplayMode>(
        //         value: LyricDisplayMode.wordByWord,
        //         label: Text('逐字歌词'),
        //       ),
        //     ],
        //     selected: {settings.lyricDisplayMode},
        //     onSelectionChanged: (newSelection) {
        //       setState(() {
        //         settings.lyricDisplayMode = newSelection.first;
        //       });
        //       settings.saveSettings();
        //       LyricViewController.instance.triggerRebuild();
        //     },
        //   ),
        // ),
        // const SizedBox(height: 16.0),
        // 注释：这两个设置暂时隐藏，因为第三方歌词 API 总是返回全部数据（主歌词+翻译+注音），
        // 无法单独控制是否获取翻译和注音。播放页面已有显示/隐藏开关，这里的设置是冗余的。
        // TODO: 未来如果 API 支持分别请求，可以重新启用
        // SettingsTile(
        //   description: '注音',
        //   subtitle: '获取网络歌词中的注音',
        //   action: Switch(
        //     value: settings.showRomanization,
        //     onChanged: (v) {
        //       setState(() {
        //         settings.showRomanization = v;
        //       });
        //       settings.saveSettings();
        //       LyricViewController.instance.triggerRebuild();
        //     },
        //   ),
        // ),
        // const SizedBox(height: 16.0),
        // SettingsTile(
        //   description: '翻译',
        //   subtitle: '获取网络歌词中的翻译',
        //   action: Switch(
        //     value: settings.showTranslation,
        //     onChanged: (v) {
        //       setState(() {
        //         settings.showTranslation = v;
        //       });
        //       settings.saveSettings();
        //       LyricViewController.instance.triggerRebuild();
        //     },
        //   ),
        // ),
        // const SizedBox(height: 16.0),
        SettingsTile(
          description: '歌词转换',
          subtitle: _isSavingZhConversion ? '保存中' : null,
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isSavingZhConversion) ...[
                const SizedBox(
                  width: 16.0,
                  height: 16.0,
                  child: CircularProgressIndicator(strokeWidth: 2.0),
                ),
                const SizedBox(width: 10.0),
              ],
              SegmentedButton<ZhConversionMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment<ZhConversionMode>(
                    value: ZhConversionMode.none,
                    label: Text('不转换'),
                  ),
                  ButtonSegment<ZhConversionMode>(
                    value: ZhConversionMode.traditionalToSimplified,
                    label: Text('繁转简'),
                  ),
                  ButtonSegment<ZhConversionMode>(
                    value: ZhConversionMode.simplifiedToTraditional,
                    label: Text('简转繁'),
                  ),
                ],
                selected: {settings.zhConversionMode},
                onSelectionChanged: _isSavingZhConversion
                    ? null
                    : (newSelection) =>
                        _setZhConversionMode(newSelection.first),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16.0),
        const _GlowEffectSwitch(),
        const SizedBox(height: 16.0),
        // 注释：歌词写入标签功能暂时隐藏，功能未完全实现
        // TODO: 完善歌词写入标签功能后重新启用
        // SettingsTile(
        //   description: '歌词写入标签提示',
        //   subtitle: '获取网络歌词后询问是否写入音频标签',
        //   action: Switch(
        //     value: settings.promptWriteLyricToTag,
        //     onChanged: (v) {
        //       setState(() {
        //         settings.promptWriteLyricToTag = v;
        //         if (!v) settings.autoWriteLyricToTag = false;
        //       });
        //       settings.saveSettings();
        //       if (!v) {
        //         PlayService.instance.lyricService.resetLyricWritePrompts();
        //       }
        //     },
        //   ),
        // ),
        // if (settings.promptWriteLyricToTag) ...[
        //   const SizedBox(height: 16.0),
        //   SettingsTile(
        //     description: '自动写入标签',
        //     subtitle: settings.autoWriteLyricToTag
        //         ? '获取歌词 ${settings.autoWriteLyricToTagDelay} 秒后自动写入，无需确认'
        //         : '开启后静默写入，不再弹窗询问',
        //     action: Switch(
        //       value: settings.autoWriteLyricToTag,
        //       onChanged: (v) {
        //         setState(() {
        //           settings.autoWriteLyricToTag = v;
        //         });
        //         settings.saveSettings();
        //         PlayService.instance.lyricService.resetLyricWritePrompts();
        //       },
        //     ),
        //   ),
        //   if (settings.autoWriteLyricToTag) ...[
        //     const SizedBox(height: 16.0),
        //     SettingsTile(
        //       description: '自动写入延迟',
        //       subtitle: '获取歌词后 ${settings.autoWriteLyricToTagDelay} 秒自动写入',
        //       action: SizedBox(
        //         width: 140,
        //         child: Slider(
        //           value: settings.autoWriteLyricToTagDelay.toDouble(),
        //           min: 10,
        //           max: 120,
        //           divisions: 11,
        //           label: '${settings.autoWriteLyricToTagDelay}秒',
        //           onChanged: (v) {
        //             setState(() {
        //               settings.autoWriteLyricToTagDelay = v.round();
        //             });
        //             settings.saveSettings();
        //           },
        //         ),
        //       ),
        //     ),
        //   ],
        //   const SizedBox(height: 16.0),
        //   SettingsTile(
        //     description: '提示延迟',
        //     subtitle: settings.autoWriteLyricToTag
        //         ? '自动写入已启用，提示不生效'
        //         : '获取歌词后等待 ${settings.promptWriteLyricToTagDelay} 秒再提示',
        //     action: SizedBox(
        //       width: 140,
        //       child: Slider(
        //         value: settings.promptWriteLyricToTagDelay.toDouble(),
        //         min: 5,
        //         max: 60,
        //         divisions: 11,
        //         label: '${settings.promptWriteLyricToTagDelay}秒',
        //         onChanged: settings.autoWriteLyricToTag
        //             ? null
        //             : (v) {
        //                 setState(() {
        //                   settings.promptWriteLyricToTagDelay = v.round();
        //                 });
        //                 settings.saveSettings();
        //               },
        //       ),
        //     ),
        //   ),
        // ],
      ],
    );
  }
}

class _AdvancedTabContent extends StatelessWidget {
  const _AdvancedTabContent();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        ArtistSeparatorEditor(),
        SizedBox(height: 16.0),
        SelectFontCombobox(),
        SizedBox(height: 16.0),
        CreateIssueTile(),
        SizedBox(height: 16.0),
        AutoUpdateToggle(),
        SizedBox(height: 16.0),
        CheckForUpdate(),
      ],
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
        showTextOnSnackBar('无法获取字体');
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
            showTextOnSnackBar('保存字体设置失败');
          }
        } catch (err) {
          logger.e('[reset font] $err');
          if (mounted) {
            showTextOnSnackBar(err.toString());
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
        }
      } catch (err) {
        ThemeProvider.instance.changeFontFamily(null);
        logger.e('[select font] $err');
        if (mounted) {
          showTextOnSnackBar(err.toString());
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
      ),
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
                        fontSize: 18.0,
                        fontWeight: FontWeight.bold,
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
                          selectedTileColor:
                              scheme.secondaryContainer.withValues(alpha: 0.45),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12.0),
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
                          onTap: !canResetOptionalSetting<String>(
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
                        selectedTileColor:
                            scheme.secondaryContainer.withValues(alpha: 0.45),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12.0),
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
                            : () => Navigator.pop(
                                  context,
                                  _FontSelection(font),
                                ),
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

    return Container(
      height: 28.0,
      constraints: const BoxConstraints(maxWidth: 260.0),
      padding: const EdgeInsets.symmetric(horizontal: 10.0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(14.0),
      ),
      child: Text(
        '\u5f53\u524d\uff1a$label',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: scheme.onSecondaryContainer,
          fontSize: 12.0,
          fontWeight: FontWeight.w600,
        ),
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
  bool _isSavingSourceMode = false;
  bool _isSavingOnlineSource = false;

  bool get _isSaving => _isSavingSourceMode || _isSavingOnlineSource;

  Future<void> _setLocalLyricFirst(bool value) async {
    if (_isSaving || value == settings.localLyricFirst) return;
    setState(() {
      _isSavingSourceMode = true;
      settings.localLyricFirst = value;
    });
    try {
      await settings.saveSettings();
    } finally {
      if (mounted) {
        setState(() => _isSavingSourceMode = false);
      }
    }
  }

  Future<void> _setPreferredOnlineSource(LyricSourceType value) async {
    if (_isSaving || value == settings.preferredOnlineSource) return;
    setState(() {
      _isSavingOnlineSource = true;
      settings.preferredOnlineSource = value;
    });
    try {
      await settings.saveSettings();
    } finally {
      if (mounted) {
        setState(() => _isSavingOnlineSource = false);
      }
    }
  }

  Widget _savingPrefix(bool visible) {
    if (!visible) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(right: 10.0),
      child: SizedBox(
        width: 16.0,
        height: 16.0,
        child: CircularProgressIndicator(strokeWidth: 2.0),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsTile(
          description: '首选歌词来源',
          subtitle: _isSavingSourceMode ? '保存中' : null,
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _savingPrefix(_isSavingSourceMode),
              SegmentedButton<bool>(
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
                onSelectionChanged: _isSaving
                    ? null
                    : (newSelection) => _setLocalLyricFirst(newSelection.first),
              ),
            ],
          ),
        ),
        // 选中“在线”时展开默认源选择
        if (!settings.localLyricFirst) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: SettingsTile(
              description: '默认在线源',
              subtitle: _isSavingOnlineSource ? '保存中' : null,
              action: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _savingPrefix(_isSavingOnlineSource),
                  SegmentedButton<LyricSourceType>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: LyricSourceType.qq,
                        label: Text('QQ'),
                      ),
                      ButtonSegment(
                        value: LyricSourceType.kugou,
                        label: Text('酷狗'),
                      ),
                      ButtonSegment(
                        value: LyricSourceType.ne,
                        label: Text('网易'),
                      ),
                    ],
                    selected: {settings.preferredOnlineSource},
                    onSelectionChanged: _isSaving
                        ? null
                        : (newSelection) =>
                            _setPreferredOnlineSource(newSelection.first),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class NowPlayingBackgroundModeToggle extends StatefulWidget {
  const NowPlayingBackgroundModeToggle({super.key});

  @override
  State<NowPlayingBackgroundModeToggle> createState() =>
      _NowPlayingBackgroundModeToggleState();
}

class _NowPlayingBackgroundModeToggleState
    extends State<NowPlayingBackgroundModeToggle> {
  final pref = AppPreference.instance.nowPlayingPagePref;
  bool _isSaving = false;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) {
      return const SizedBox.shrink();
    }

    return SettingsTile(
      description: '播放页背景模式',
      subtitle: _isSaving ? '保存中' : null,
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isSaving) ...[
            const SizedBox(
              width: 16.0,
              height: 16.0,
              child: CircularProgressIndicator(strokeWidth: 2.0),
            ),
            const SizedBox(width: 10.0),
          ],
          SegmentedButton<NowPlayingBackgroundMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment<NowPlayingBackgroundMode>(
                value: NowPlayingBackgroundMode.meshGradient,
                label: Text('动态背景'),
              ),
              ButtonSegment<NowPlayingBackgroundMode>(
                value: NowPlayingBackgroundMode.blurCover,
                label: Text('封面模糊'),
              ),
            ],
            selected: {pref.backgroundMode},
            onSelectionChanged: _isSaving
                ? null
                : (selection) async {
                    final nextMode = selection.first;
                    if (nextMode == pref.backgroundMode) return;
                    setState(() {
                      _isSaving = true;
                      pref.backgroundMode = nextMode;
                    });
                    nowPlayingBackgroundModeNotifier.value = nextMode;
                    try {
                      await AppPreference.instance.save();
                    } finally {
                      if (mounted) {
                        setState(() {
                          _isSaving = false;
                        });
                      }
                    }
                  },
          ),
        ],
      ),
    );
  }
}
