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
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/settings_page/check_update.dart';
import 'package:pure_music/page/settings_page/create_issue.dart';
import 'package:pure_music/page/settings_page/artist_separator_editor.dart';
import 'package:pure_music/play_service/play_service.dart';
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
                side:
                    BorderSide(color: selected ? scheme.primary : scheme.outline),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
  State<_MonetProgressBarSwitch> createState() => _MonetProgressBarSwitchState();
}

class _MonetProgressBarSwitchState extends State<_MonetProgressBarSwitch> {
  final settings = AppSettings.instance;

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '进度条莫奈取色',
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
      description: '莫奈取色歌词',
      subtitle: '启用后歌词使用主题色渲染',
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
      description: '间奏动画莫奈取色',
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
          description: '移除空行',
          action: Switch(
            value: settings.removeEmptyLines,
            onChanged: (v) {
              setState(() {
                settings.removeEmptyLines = v;
              });
              settings.saveSettings();
              LyricViewController.instance.setRemoveEmptyLines(v);
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
