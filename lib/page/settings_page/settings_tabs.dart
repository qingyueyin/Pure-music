import 'dart:io';

import 'package:pure_music/core/design_tokens.dart';
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
import 'package:pure_music/play_service/desktop_lyric_service.dart';
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
    _SettingsTab('桌面歌词', Symbols.desktop_windows),
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
                  selected ? scheme.onSecondaryContainer : scheme.onSurface,
                ),
                backgroundColor: WidgetStatePropertyAll(
                  selected ? scheme.secondaryContainer : scheme.surfaceContainerHighest,
                ),
                side: WidgetStatePropertyAll(
                  BorderSide(
                    color: selected ? scheme.primary : scheme.outline,
                  ),
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
          child: IndexedStack(
            index: _currentIndex,
            children: const [
              _AppearanceTabContent(),
              _LyricsTabContent(),
              _DesktopLyricTabContent(),
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
        _CoverColorExtractionSwitch(),
        SizedBox(height: 16.0),
        _MonetProgressBarSwitch(),
        SizedBox(height: 16.0),
        _MonetLyricsSwitch(),
        SizedBox(height: 16.0),
        _MonetTransitionSwitch(),
        SizedBox(height: 16.0),
        _MonetControlsSwitch(),
        SizedBox(height: 16.0),
        _WavyProgressBarSwitch(),
        SizedBox(height: 16.0),
        _TopBarLyricAnimationSelector(),
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
      description: '主题',
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
      description: '主题色进度条',
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
          constraints: const BoxConstraints(minHeight: 48, minWidth: 72),
          textStyle: const TextStyle(
            fontSize: AppType.body,
            fontWeight: AppType.weightMedium,
          ),
          children: const [
            Text('竖屏'),
            Text('横屏'),
            Text('横屏沉浸'),
          ],
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
      TopBarLyricAnimation.fade: '淡入淡出',
      TopBarLyricAnimation.absorb: '吸收',
      TopBarLyricAnimation.flipX: 'X 翻转',
      TopBarLyricAnimation.flipY: 'Y 翻转',
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
      description: '主题色歌词',
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
      description: '主题色间奏动画',
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
      description: '主题色控件',
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
      description: '辉光缩放效果（实验性）',
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
      setState(() => settings.customCoverColor = result.toARGB32());
      _refreshTheme();
      await settings.saveSettings();
    } finally {
      if (mounted) {
        setState(() => _isPickingColor = false);
      }
    }
  }

  Future<void> _setAutoExtraction(bool value) async {
    setState(() => settings.enableCoverColorExtraction = value);
    _refreshTheme();
    await settings.saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    final isAuto = settings.enableCoverColorExtraction;
    final subtitle = isAuto ? '从专辑封面自动提取' : '自定义应用整体颜色';

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
                onPressed: _isPickingColor ? null : _pickCustomColor,
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: AppRadius.smCircular,
                  ),
                ),
                icon: _isPickingColor
                    ? const SizedBox(
                        width: 16.0,
                        height: 16.0,
                        child: CircularProgressIndicator(strokeWidth: 2.0),
                      )
                    : const Icon(Symbols.palette),
                label: Text(
                  _isPickingColor ? '选择中' : '自定义',
                ),
              ),
            ),
          Switch(
            value: isAuto,
            onChanged: _isPickingColor ? null : _setAutoExtraction,
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
                borderRadius: AppRadius.smCircular,
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
                      borderRadius: AppRadius.smCircular,
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
                            color:
                                scheme.onSurfaceVariant.withValues(alpha: 0.5),
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
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                onSelectionChanged: (newSelection) =>
                    _setZhConversionMode(newSelection.first),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16.0),
        const _GlowEffectSwitch(),
        const SizedBox(height: 16.0),
        const _RubyPositionSetting(),
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

class _DesktopLyricTabContent extends StatefulWidget {
  const _DesktopLyricTabContent();

  @override
  State<_DesktopLyricTabContent> createState() =>
      _DesktopLyricTabContentState();
}

class _DesktopLyricTabContentState extends State<_DesktopLyricTabContent> {
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
        ? Color(current | 0xFF000000)
        : Theme.of(context).colorScheme.primary;
    final result = await showDialog<_DesktopColorResult>(
      context: context,
      builder: (context) => _DesktopColorPickerDialog(
        initialColor: initial,
        initialOpacity: opacity,
        label: '选择颜色',
      ),
    );
    if (result != null) {
      final alpha = (result.opacity * 255).round().clamp(0, 255);
      final argb = (alpha << 24) | (result.color.toARGB32() & 0x00FFFFFF);
      setState(() {
        onPicked(argb);
        onChangedOpacity(result.opacity);
        _saveAndSend();
      });
    }
  }

  DesktopLyricService get _service =>
      PlayService.instance.desktopLyricService;

  void _sendAll() {
    if (!_service.isRunning) return;
    final scheme = Theme.of(context).colorScheme;
    final int? playedColor;
    final int? unplayedColor;
    if (settings.desktopFollowThemeColor) {
      playedColor = scheme.primary.toARGB32();
      unplayedColor = scheme.onSurface.toARGB32();
    } else {
      playedColor = settings.desktopPlayedColor;
      unplayedColor = settings.desktopUnplayedColor;
    }
    _service.sendConfig(
      lyricFontSize: settings.desktopLyricFontSize,
      translationFontSize: settings.desktopTranslationFontSize,
      lyricFontWeight: settings.desktopLyricFontWeight,
      showLyricTranslation: settings.desktopShowTranslation,
      showRoman: settings.showDesktopLyricRoman,
      romanPosition: settings.desktopLyricRomanPosition,
      showNowPlayingInfo: settings.desktopShowNowPlayingInfo,
      lyricTextAlign: settings.desktopLyricTextAlign,
      enableStroke: settings.desktopEnableStroke,
      backgroundOpacity: settings.desktopBackgroundOpacity,
      playedColor: playedColor,
      unplayedColor: unplayedColor,
    );
  }

  void _update(VoidCallback fn) {
    setState(fn);
    _saveAndSend();
  }

  void _saveAndSend() {
    settings.saveSettings();
    _sendAll();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final running = _service.isRunning;
        return ListView(
          padding: const EdgeInsets.only(bottom: 96.0, right: 20),
          children: [
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

            // ── 显示设置 ──
            SettingsTile(
              description: '歌词翻译',
              action: Switch(
                value: settings.desktopShowTranslation,
                onChanged: (v) => _update(
                  () => settings.desktopShowTranslation = v,
                ),
              ),
            ),
            const SizedBox(height: 16),
            SettingsTile(
              description: '注音',
              action: Switch(
                value: settings.showDesktopLyricRoman,
                onChanged: (v) => _update(
                  () => settings.showDesktopLyricRoman = v,
                ),
              ),
            ),
            const SizedBox(height: 16),
            SettingsTile(
              description: '注音位置',
              action: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 0, label: Text('歌词上方')),
                      ButtonSegment(value: 1, label: Text('歌词下方')),
                      ButtonSegment(value: 2, label: Text('翻译下方')),
                    ],
                    selected: {settings.desktopLyricRomanPosition},
                    onSelectionChanged: (v) => _update(
                      () => settings.desktopLyricRomanPosition = v.first,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SettingsTile(
              description: '歌曲信息',
              subtitle: settings.desktopShowNowPlayingInfo
                  ? '显示歌曲标题和艺人'
                  : '隐藏',
              action: Switch(
                value: settings.desktopShowNowPlayingInfo,
                onChanged: (v) => _update(
                  () => settings.desktopShowNowPlayingInfo = v,
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ── 文字样式 ──
            Text(
              '文字样式',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: AppType.caption,
              ),
            ),
            const SizedBox(height: 8),
            SettingsTile(
              description: '文字对齐',
              action: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 0, label: Text('左')),
                  ButtonSegment(value: 1, label: Text('中')),
                  ButtonSegment(value: 2, label: Text('右')),
                ],
                selected: {settings.desktopLyricTextAlign},
                onSelectionChanged: (v) => _update(
                  () => settings.desktopLyricTextAlign = v.first,
                ),
              ),
            ),
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
                    settings.desktopTranslationFontSize =
                        (v - 4).clamp(10, 44);
                  }),
                  onChangeEnd: (_) => _saveAndSend(),
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
                  onChanged: (v) => setState(
                    () => settings.desktopTranslationFontSize = v,
                  ),
                  onChangeEnd: (_) => _saveAndSend(),
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
                  onChanged: (v) => setState(
                    () => settings.desktopLyricFontWeight = v.round(),
                  ),
                  onChangeEnd: (_) => _saveAndSend(),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SettingsTile(
              description: '描边',
              action: Switch(
                value: settings.desktopEnableStroke,
                onChanged: (v) => _update(
                  () => settings.desktopEnableStroke = v,
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ── 歌词颜色 ──
            Text(
              '歌词颜色',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: AppType.caption,
              ),
            ),
            const SizedBox(height: 8),
            SettingsTile(
              description: '跟随主题色',
              action: Switch(
                value: settings.desktopFollowThemeColor,
                onChanged: (v) => _update(() {
                  settings.desktopFollowThemeColor = v;
                  if (v) {
                    settings.desktopPlayedColor = null;
                    settings.desktopUnplayedColor = null;
                  }
                }),
              ),
            ),
            if (!settings.desktopFollowThemeColor) ...[
              const SizedBox(height: 16),
              _DesktopColorSetting(
                label: '已播放颜色',
                color: settings.desktopPlayedColor,
                opacity: _playedOpacity,
                onPickColor: () => _pickDesktopColor(
                  settings.desktopPlayedColor,
                  _playedOpacity,
                  (c) => settings.desktopPlayedColor = c,
                  (o) => _playedOpacity = o,
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
                  (c) => settings.desktopUnplayedColor = c,
                  (o) => _unplayedOpacity = o,
                ),
              ),
            ],
          ],
        );
      },
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
      subtitle: color == null
          ? '跟随主题'
          : '自定义 · ${(opacity * 100).round()}%',
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
                color: (displayColor ?? scheme.primary)
                    .withValues(alpha: opacity),
                borderRadius: AppRadius.xsCircular,
                border: displayColor == null
                    ? Border.all(
                        color: scheme.outline.withValues(alpha: 0.4))
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: AppRadius.smCircular,
              ),
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

class _DesktopColorPickerDialogState
    extends State<_DesktopColorPickerDialog> {
  late HSVColor _hsv;
  late TextEditingController _hexCtrl;
  late double _opacity;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
    _hexCtrl = TextEditingController(
      text: _colorToHex(widget.initialColor),
    );
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
                  child: _HsvPicker(
                    hsv: _hsv,
                    onChanged: _updateColor,
                  ),
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
                            color: scheme.onSurfaceVariant
                                .withValues(alpha: 0.5),
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
                  ? () => Navigator.of(context)
                      .pop(_DesktopColorResult(color, _opacity))
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
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: const [
        ArtistSeparatorEditor(),
        SizedBox(height: 16.0),
        SelectFontCombobox(),
        SizedBox(height: 16.0),
        CreateIssueTile(),
        SizedBox(height: 16.0),
        CheckForUpdate(),
        SizedBox(height: 16.0),
        AutoUpdateToggle(),
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
        } else if (mounted) {
          showTextOnSnackBar('已应用字体');
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
        borderRadius: AppRadius.mdCircular,
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
                          selectedTileColor:
                              scheme.secondaryContainer.withValues(alpha: 0.45),
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

class NowPlayingBackgroundModeToggle extends StatefulWidget {
  const NowPlayingBackgroundModeToggle({super.key});

  @override
  State<NowPlayingBackgroundModeToggle> createState() =>
      _NowPlayingBackgroundModeToggleState();
}

class _NowPlayingBackgroundModeToggleState
    extends State<NowPlayingBackgroundModeToggle> {
  final pref = AppPreference.instance.nowPlayingPagePref;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) {
      return const SizedBox.shrink();
    }

    return SettingsTile(
      description: '播放页背景模式',
      action: SegmentedButton<NowPlayingBackgroundMode>(
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
        onSelectionChanged: (selection) {
          final nextMode = selection.first;
          if (nextMode == pref.backgroundMode) return;
          setState(() => pref.backgroundMode = nextMode);
          nowPlayingBackgroundModeNotifier.value = nextMode;
          AppPreference.instance.save();
        },
      ),
    );
  }
}
