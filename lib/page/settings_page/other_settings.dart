import 'dart:io';

import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/setting_action_state.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/zh_converter.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class OnlineLyricSettings extends StatefulWidget {
  const OnlineLyricSettings({super.key});

  @override
  State<OnlineLyricSettings> createState() => _OnlineLyricSettingsState();
}

class _OnlineLyricSettingsState extends State<OnlineLyricSettings> {
  final settings = AppSettings.instance;
  bool _isSaving = false;

  Future<void> _saveChangedSetting(VoidCallback update) async {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
      update();
    });
    try {
      final saved = await settings.saveSettings();
      if (!saved && mounted) showTextOnSnackBar('保存设置失败');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsTile(
      description: '在线歌词设置',
      subtitle: _isSaving ? '保存中' : null,
      action: MenuAnchor(
        builder: (context, controller, _) {
          return FilledButton.icon(
            onPressed: _isSaving
                ? null
                : controller.isOpen
                    ? controller.close
                    : controller.open,
            icon: _isSaving
                ? const SizedBox(
                    width: 16.0,
                    height: 16.0,
                    child: CircularProgressIndicator(strokeWidth: 2.0),
                  )
                : const Icon(Symbols.tune),
            label: Text(_isSaving ? '保存中' : '打开'),
          );
        },
        menuChildren: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '歌词模式',
                  style: TextStyle(color: scheme.onSurface),
                ),
                const SizedBox(height: 8.0),
                SegmentedButton<LyricDisplayMode>(
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
                  onSelectionChanged: _isSaving
                      ? null
                      : (newSelection) => _saveChangedSetting(
                            () =>
                                settings.lyricDisplayMode = newSelection.first,
                          ),
                ),
                const SizedBox(height: 16.0),
                Text(
                  '简繁转换',
                  style: TextStyle(color: scheme.onSurface),
                ),
                const SizedBox(height: 8.0),
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
                  onSelectionChanged: _isSaving
                      ? null
                      : (newSelection) => _saveChangedSetting(
                            () =>
                                settings.zhConversionMode = newSelection.first,
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

class DefaultLyricSourceControl extends StatefulWidget {
  const DefaultLyricSourceControl({super.key});

  @override
  State<DefaultLyricSourceControl> createState() =>
      _DefaultLyricSourceControlState();
}

class _DefaultLyricSourceControlState extends State<DefaultLyricSourceControl> {
  final settings = AppSettings.instance;
  bool _isSaving = false;

  @override
  Widget build(BuildContext context) {
    final canChange = canChangeSetting(isSaving: _isSaving);
    return SettingsTile(
      description: '首选歌词来源',
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
            const SizedBox(width: 8.0),
          ],
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
            onSelectionChanged: !canChange
                ? null
                : (newSelection) async {
                    if (newSelection.first == settings.localLyricFirst) return;

                    setState(() {
                      _isSaving = true;
                      settings.localLyricFirst = newSelection.first;
                    });
                    try {
                      final saved = await settings.saveSettings();
                      if (!saved && mounted) showTextOnSnackBar('保存设置失败');
                    } finally {
                      if (mounted) setState(() => _isSaving = false);
                    }
                  },
          ),
        ],
      ),
    );
  }
}

class AdvancedPlaybackSettingsTile extends StatelessWidget {
  const AdvancedPlaybackSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    final pref = AppPreference.instance.playbackPref;
    final scheme = Theme.of(context).colorScheme;
    return SettingsTile(
      description: '播放高级设置',
      action: MenuAnchor(
        builder: (context, controller, child) {
          return FilledButton.icon(
            onPressed: controller.isOpen ? controller.close : controller.open,
            icon: const Icon(Symbols.tune),
            label: const Text('打开'),
          );
        },
        menuChildren: [
          StatefulBuilder(
            builder: (context, menuSetState) => Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'WASAPI 缓冲时长',
                    style: TextStyle(color: scheme.onSurface),
                  ),
                  const SizedBox(height: 8.0),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Slider(
                            min: 0.05,
                            max: 0.30,
                            divisions: 25,
                            value: pref.wasapiBufferSec.clamp(0.05, 0.30),
                            onChanged: (v) async {
                              menuSetState(() => pref.wasapiBufferSec = v);
                              await AppPreference.instance.save();
                            },
                          ),
                        ),
                        const SizedBox(width: 8.0),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10.0,
                            vertical: 6.0,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(14.0),
                          ),
                          child: Text(
                            '${pref.wasapiBufferSec.toStringAsFixed(2)}s',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12.0),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'WASAPI 事件驱动缓冲',
                          style: TextStyle(color: scheme.onSurface),
                        ),
                      ),
                      Switch(
                        value: pref.wasapiEventDriven,
                        onChanged: (v) async {
                          menuSetState(() => pref.wasapiEventDriven = v);
                          await AppPreference.instance.save();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12.0),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '回声排查日志录制',
                          style: TextStyle(color: scheme.onSurface),
                        ),
                      ),
                      IconButton(
                        tooltip: '写入快照',
                        onPressed: AudioEchoLogRecorder.instance.isRecording
                            ? () => AudioEchoLogRecorder.instance
                                .snapshot(tag: 'manual')
                            : null,
                        icon: const Icon(Symbols.bookmark),
                      ),
                      IconButton(
                        tooltip: '打开日志目录',
                        onPressed: AudioEchoLogRecorder.instance.openLogDir,
                        icon: const Icon(Symbols.folder),
                      ),
                      Switch(
                        value: AudioEchoLogRecorder.instance.isRecording,
                        onChanged: (v) async {
                          if (v) {
                            await AudioEchoLogRecorder.instance.start();
                          } else {
                            await AudioEchoLogRecorder.instance.stop();
                          }
                          menuSetState(() {});
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class WasapiBufferControl extends StatefulWidget {
  const WasapiBufferControl({super.key});

  @override
  State<WasapiBufferControl> createState() => _WasapiBufferControlState();
}

class AudioEchoLogRecordControl extends StatefulWidget {
  const AudioEchoLogRecordControl({super.key});

  @override
  State<AudioEchoLogRecordControl> createState() =>
      _AudioEchoLogRecordControlState();
}

class _AudioEchoLogRecordControlState extends State<AudioEchoLogRecordControl> {
  final recorder = AudioEchoLogRecorder.instance;
  bool _isChangingRecording = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isRecording = recorder.isRecording;
    final isBusy = _isChangingRecording;
    final statusLabel = isBusy
        ? isRecording
            ? '正在停止'
            : '正在开启'
        : isRecording
            ? '录制中'
            : '未开启';

    return SettingsTile(
      description: '回声排查日志录制',
      action: Wrap(
        spacing: 4.0,
        runSpacing: 8.0,
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Container(
            height: 32.0,
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            decoration: BoxDecoration(
              color: isRecording
                  ? scheme.tertiaryContainer
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16.0),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isBusy)
                  SizedBox(
                    width: 14.0,
                    height: 14.0,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.0,
                      color: isRecording
                          ? scheme.onTertiaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  )
                else
                  Icon(
                    isRecording ? Symbols.radio_button_checked : Symbols.circle,
                    size: 14.0,
                    color: isRecording
                        ? scheme.onTertiaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                const SizedBox(width: 6.0),
                Text(
                  statusLabel,
                  style: TextStyle(
                    color: isRecording
                        ? scheme.onTertiaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '写入快照',
            onPressed: isRecording && !isBusy
                ? () => recorder.snapshot(tag: 'manual')
                : null,
            icon: const Icon(Symbols.bookmark),
          ),
          IconButton(
            tooltip: '打开日志目录',
            onPressed: recorder.openLogDir,
            icon: const Icon(Symbols.folder),
          ),
          Switch(
            value: isRecording,
            onChanged: isBusy
                ? null
                : (v) async {
                    setState(() => _isChangingRecording = true);
                    try {
                      if (v) {
                        await recorder.start();
                      } else {
                        await recorder.stop();
                      }
                    } finally {
                      if (mounted) {
                        setState(() => _isChangingRecording = false);
                      }
                    }
                  },
          ),
        ],
      ),
    );
  }
}

class _WasapiBufferControlState extends State<WasapiBufferControl> {
  final pref = AppPreference.instance.playbackPref;
  late double _lastSavedValue = pref.wasapiBufferSec;
  bool _isSaving = false;

  Future<void> _saveBufferSec(double value) async {
    final next = value.clamp(0.05, 0.30).toDouble();
    if (!canSaveChangedDoubleSetting(
      current: _lastSavedValue,
      next: next,
      isSaving: _isSaving,
    )) {
      return;
    }

    final previous = _lastSavedValue;
    setState(() {
      _isSaving = true;
      pref.wasapiBufferSec = next;
    });
    try {
      final saved = await AppPreference.instance.save();
      if (saved) {
        _lastSavedValue = next;
      } else {
        pref.wasapiBufferSec = previous;
        if (mounted) showTextOnSnackBar('保存播放设置失败');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = pref.wasapiBufferSec.clamp(0.05, 0.30).toDouble();
    return SettingsTile(
      description: 'WASAPI 缓冲时长',
      subtitle: _isSaving ? '保存中' : null,
      action: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320.0),
        child: Row(
          children: [
            if (_isSaving) ...[
              const SizedBox(
                width: 16.0,
                height: 16.0,
                child: CircularProgressIndicator(strokeWidth: 2.0),
              ),
              const SizedBox(width: 8.0),
            ],
            Expanded(
              child: Slider(
                min: 0.05,
                max: 0.30,
                divisions: 25,
                value: v,
                onChanged: _isSaving
                    ? null
                    : (nv) {
                        setState(() {
                          pref.wasapiBufferSec = nv;
                        });
                      },
                onChangeEnd: _isSaving ? null : _saveBufferSec,
              ),
            ),
            const SizedBox(width: 8.0),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10.0,
                vertical: 6.0,
              ),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14.0),
              ),
              child: Text(
                '${v.toStringAsFixed(2)}s',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 播放页背景模式（Windows only）
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
    /// Only show on Windows platform
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
                label: Text('动态'),
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
                    final previousMode = pref.backgroundMode;
                    setState(() {
                      _isSaving = true;
                      pref.backgroundMode = nextMode;
                    });
                    nowPlayingBackgroundModeNotifier.value = nextMode;
                    try {
                      final saved = await AppPreference.instance.save();
                      if (!saved) {
                        pref.backgroundMode = previousMode;
                        nowPlayingBackgroundModeNotifier.value = previousMode;
                        if (mounted) showTextOnSnackBar('保存播放页背景失败');
                      }
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
