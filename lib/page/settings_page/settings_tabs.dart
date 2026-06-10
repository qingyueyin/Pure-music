import 'dart:io';

import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/zh_converter.dart';
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
            return OutlinedButton.icon(
              onPressed: () => setState(() => _currentIndex = i),
              icon: Icon(_tabs[i].icon,
                  size: 18,
                  color: selected ? scheme.onPrimary : scheme.onSurface),
              label: Text(
                _tabs[i].label,
                style: TextStyle(
                  color: selected ? scheme.onPrimary : scheme.onSurface,
                ),
              ),
              style: OutlinedButton.styleFrom(
                backgroundColor: selected ? scheme.primary : Colors.transparent,
                side: BorderSide(
                    color: selected ? scheme.primary : scheme.outline),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
        _MonetLyricsSwitch(),
        SizedBox(height: 16.0),
        _MonetTransitionSwitch(),
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

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '主题',
      action: SegmentedButton<ThemeOption>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: ThemeOption.system, label: Text('跟随系统')),
          ButtonSegment(value: ThemeOption.light, label: Text('浅色模式')),
          ButtonSegment(value: ThemeOption.dark, label: Text('深色模式')),
        ],
        selected: {settings.themeOption},
        onSelectionChanged: (selected) {
          setState(() {
            settings.themeOption = selected.first;
          });
          ThemeProvider.instance.applyThemeOption(selected.first);
          settings.saveSettings();
        },
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

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '主题色进度条',
      subtitle: '进度条使用主题色渲染',
      action: Switch(
        value: settings.useMaterialYouForProgressBar,
        onChanged: (v) {
          setState(() {
            settings.useMaterialYouForProgressBar = v;
          });
          settings.saveSettings();
        },
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

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '主题色歌词',
      subtitle: '歌词使用主题色渲染',
      action: Switch(
        value: settings.useMaterialYouForLyrics,
        onChanged: (v) {
          setState(() {
            settings.useMaterialYouForLyrics = v;
          });
          settings.saveSettings();
          LyricViewController.instance.triggerRebuild();
        },
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

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '主题色间奏动画',
      subtitle: '间奏动画使用主题色渲染',
      action: Switch(
        value: settings.useMaterialYouForTransition,
        onChanged: (v) {
          setState(() {
            settings.useMaterialYouForTransition = v;
          });
          settings.saveSettings();
          LyricViewController.instance.triggerRebuild();
        },
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

  @override
  Widget build(BuildContext context) {
    final isAuto = settings.enableCoverColorExtraction;

    return SettingsTile(
      description: '应用主题色',
      subtitle: isAuto ? '从专辑封面自动提取' : '自定义应用整体颜色',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isAuto)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: OutlinedButton(
                onPressed: () async {
                  final result = await _openColorPicker();
                  if (result != null && mounted) {
                    setState(() {
                      settings.customCoverColor = result.toARGB32();
                    });
                    settings.saveSettings();
                    _refreshTheme();
                  }
                },
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: const Text('自定义'),
              ),
            ),
          Switch(
            value: isAuto,
            onChanged: (v) {
              setState(() => settings.enableCoverColorExtraction = v);
              settings.saveSettings();
              _refreshTheme();
            },
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
    final pickerSize = (size.width * 0.65).clamp(220.0, 300.0);

    return AlertDialog(
      title: const Text('自定义主题色'),
      content: SizedBox(
        width: pickerSize + 32,
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
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
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
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Fa-f]')),
                    ],
                    onSubmitted: _onHexSubmitted,
                    onChanged: (text) {
                      if (text.length == 6) _onHexSubmitted(text);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(color),
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

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        const DefaultLyricSourceControl(),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: '歌词模式',
          subtitle: '获取到的网络歌词格式',
          action: SegmentedButton<LyricDisplayMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment<LyricDisplayMode>(
                value: LyricDisplayMode.lineByLine,
                label: Text('逐行歌词'),
              ),
              ButtonSegment<LyricDisplayMode>(
                value: LyricDisplayMode.wordByWord,
                label: Text('逐字歌词'),
              ),
            ],
            selected: {settings.lyricDisplayMode},
            onSelectionChanged: (newSelection) {
              setState(() {
                settings.lyricDisplayMode = newSelection.first;
              });
              settings.saveSettings();
              LyricViewController.instance.triggerRebuild();
            },
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: '注音',
          subtitle: '获取网络歌词中的注音',
          action: Switch(
            value: settings.showRomanization,
            onChanged: (v) {
              setState(() {
                settings.showRomanization = v;
              });
              settings.saveSettings();
              LyricViewController.instance.triggerRebuild();
            },
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: '翻译',
          subtitle: '获取网络歌词中的翻译',
          action: Switch(
            value: settings.showTranslation,
            onChanged: (v) {
              setState(() {
                settings.showTranslation = v;
              });
              settings.saveSettings();
              LyricViewController.instance.triggerRebuild();
            },
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: '歌词转换',
          action: SegmentedButton<ZhConversionMode>(
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
            onSelectionChanged: (newSelection) {
              setState(() {
                settings.zhConversionMode = newSelection.first;
              });
              settings.saveSettings();
              LyricViewController.instance.triggerRebuild();
            },
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: '歌词写入标签提示',
          subtitle: '获取网络歌词后询问是否写入音频标签',
          action: Switch(
            value: settings.promptWriteLyricToTag,
            onChanged: (v) {
              setState(() {
                settings.promptWriteLyricToTag = v;
                if (!v) settings.autoWriteLyricToTag = false;
              });
              settings.saveSettings();
              if (!v) {
                PlayService.instance.lyricService.resetLyricWritePrompts();
              }
            },
          ),
        ),
        if (settings.promptWriteLyricToTag) ...[
          const SizedBox(height: 16.0),
          SettingsTile(
            description: '自动写入标签',
            subtitle: settings.autoWriteLyricToTag
                ? '获取歌词 ${settings.autoWriteLyricToTagDelay} 秒后自动写入，无需确认'
                : '开启后静默写入，不再弹窗询问',
            action: Switch(
              value: settings.autoWriteLyricToTag,
              onChanged: (v) {
                setState(() {
                  settings.autoWriteLyricToTag = v;
                });
                settings.saveSettings();
                PlayService.instance.lyricService.resetLyricWritePrompts();
              },
            ),
          ),
          if (settings.autoWriteLyricToTag) ...[
            const SizedBox(height: 16.0),
            SettingsTile(
              description: '自动写入延迟',
              subtitle: '获取歌词后 ${settings.autoWriteLyricToTagDelay} 秒自动写入',
              action: SizedBox(
                width: 140,
                child: Slider(
                  value: settings.autoWriteLyricToTagDelay.toDouble(),
                  min: 10,
                  max: 120,
                  divisions: 11,
                  label: '${settings.autoWriteLyricToTagDelay}秒',
                  onChanged: (v) {
                    setState(() {
                      settings.autoWriteLyricToTagDelay = v.round();
                    });
                    settings.saveSettings();
                  },
                ),
              ),
            ),
          ],
          const SizedBox(height: 16.0),
          SettingsTile(
            description: '提示延迟',
            subtitle: settings.autoWriteLyricToTag
                ? '自动写入已启用，提示不生效'
                : '获取歌词后等待 ${settings.promptWriteLyricToTagDelay} 秒再提示',
            action: SizedBox(
              width: 140,
              child: Slider(
                value: settings.promptWriteLyricToTagDelay.toDouble(),
                min: 5,
                max: 60,
                divisions: 11,
                label: '${settings.promptWriteLyricToTagDelay}秒',
                onChanged: settings.autoWriteLyricToTag
                    ? null
                    : (v) {
                        setState(() {
                          settings.promptWriteLyricToTagDelay = v.round();
                        });
                        settings.saveSettings();
                      },
              ),
            ),
          ),
        ],
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
      ],
    );
  }
}

class SelectFontCombobox extends StatelessWidget {
  const SelectFontCombobox({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '自定义字体',
      action: FilledButton.icon(
        onPressed: () async {
          final installedFont = await getInstalledFonts();
          if (installedFont == null || installedFont.isEmpty) {
            showTextOnSnackBar('无法获取字体');
            return;
          }

          if (context.mounted) {
            final selectedFont = await showDialog<InstalledFont>(
              context: context,
              builder: (context) => _FontSelector(installedFont: installedFont),
            );
            if (selectedFont == null) return;

            try {
              final fontLoader = FontLoader(selectedFont.fullName);
              fontLoader.addFont(
                File(selectedFont.path).readAsBytes().then((value) {
                  return ByteData.sublistView(value);
                }),
              );
              await fontLoader.load();
              ThemeProvider.instance.changeFontFamily(selectedFont.fullName);

              final settings = AppSettings.instance;
              settings.fontFamily = selectedFont.fullName;
              settings.fontPath = selectedFont.path;
              await settings.saveSettings();
            } catch (err) {
              ThemeProvider.instance.changeFontFamily(null);
              logger.e('[select font] $err');
              if (context.mounted) {
                showTextOnSnackBar(err.toString());
              }
            }
          }
        },
        label: const Text('选择字体'),
        icon: const Icon(Symbols.text_fields),
      ),
    );
  }
}

class _FontSelector extends StatelessWidget {
  const _FontSelector({required this.installedFont});
  final List<InstalledFont> installedFont;

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context);
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
      ),
      child: SizedBox(
        width: 350.0,
        height: 400,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Text(
                  '选择字体',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 18.0,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text("当前字体：${theme.fontFamily ?? "默认"}"),
              const SizedBox(height: 8.0),
              Expanded(
                child: Material(
                  type: MaterialType.transparency,
                  child: ListView.builder(
                    itemCount: installedFont.length,
                    itemExtent: 48,
                    itemBuilder: (context, i) => ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8.0),
                      ),
                      title: Text(installedFont[i].fullName),
                      onTap: () => Navigator.pop(context, installedFont[i]),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16.0),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
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

class DefaultLyricSourceControl extends StatefulWidget {
  const DefaultLyricSourceControl({super.key});

  @override
  State<DefaultLyricSourceControl> createState() =>
      _DefaultLyricSourceControlState();
}

class _DefaultLyricSourceControlState extends State<DefaultLyricSourceControl> {
  final settings = AppSettings.instance;

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
            onSelectionChanged: (newSelection) async {
              if (newSelection.first == settings.localLyricFirst) return;
              setState(() {
                settings.localLyricFirst = newSelection.first;
              });
              await settings.saveSettings();
            },
          ),
        ),
        // 选中"在线"时展开默认源选择
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
                onSelectionChanged: (newSelection) {
                  setState(() {
                    settings.preferredOnlineSource = newSelection.first;
                  });
                  settings.saveSettings();
                },
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
        onSelectionChanged: (selection) async {
          final nextMode = selection.first;
          if (nextMode == pref.backgroundMode) return;
          setState(() {
            pref.backgroundMode = nextMode;
          });
          nowPlayingBackgroundModeNotifier.value = nextMode;
          await AppPreference.instance.save();
        },
      ),
    );
  }
}
