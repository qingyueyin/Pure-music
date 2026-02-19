import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

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
    return SettingsTile(
      description: "首选歌词来源",
      action: SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment<bool>(
            value: true,
            icon: Icon(Symbols.cloud_off),
            label: Text("本地"),
          ),
          ButtonSegment<bool>(
            value: false,
            icon: Icon(Symbols.cloud),
            label: Text("在线"),
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
      description: "播放高级设置",
      action: MenuAnchor(
        builder: (context, controller, child) {
          return FilledButton.icon(
            onPressed: controller.isOpen ? controller.close : controller.open,
            icon: const Icon(Symbols.tune),
            label: const Text("打开"),
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
                  "WASAPI 缓冲时长",
                  style: TextStyle(color: scheme.onSurface),
                ),
                const SizedBox(height: 8.0),
                SizedBox(
                  width: 260,
                  child: Row(
                    children: [
                      Expanded(
                        child: Slider(
                          min: 0.05,
                          max: 0.30,
                          divisions: 25,
                          value: pref.wasapiBufferSec.clamp(0.05, 0.30),
                          onChanged: (v) async {
                            pref.wasapiBufferSec = v;
                            await AppPreference.instance.save();
                          },
                        ),
                      ),
                      const SizedBox(width: 8.0),
                      Text("${pref.wasapiBufferSec.toStringAsFixed(2)}s"),
                    ],
                  ),
                ),
                const SizedBox(height: 12.0),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        "WASAPI 事件驱动缓冲",
                        style: TextStyle(color: scheme.onSurface),
                      ),
                    ),
                    Switch(
                      value: pref.wasapiEventDriven,
                      onChanged: (v) async {
                        pref.wasapiEventDriven = v;
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
                        "回声排查日志录制",
                        style: TextStyle(color: scheme.onSurface),
                      ),
                    ),
                    IconButton(
                      tooltip: "写入快照",
                      onPressed: AudioEchoLogRecorder.instance.isRecording
                          ? () => AudioEchoLogRecorder.instance
                              .snapshot(tag: 'manual')
                          : null,
                      icon: const Icon(Symbols.bookmark),
                    ),
                    IconButton(
                      tooltip: "打开日志目录",
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
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class EqBypassSwitch extends StatefulWidget {
  const EqBypassSwitch({super.key});

  @override
  State<EqBypassSwitch> createState() => _EqBypassSwitchState();
}

class _EqBypassSwitchState extends State<EqBypassSwitch> {
  final pref = AppPreference.instance.playbackPref;

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: "均衡器旁路",
      action: Switch(
        value: pref.eqBypass,
        onChanged: (v) async {
          setState(() {
            pref.eqBypass = v;
          });
          await AppPreference.instance.save();
          PlayService.instance.playbackService.refreshEQ();
        },
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

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: "回声排查日志录制",
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: "写入快照",
            onPressed: recorder.isRecording
                ? () => recorder.snapshot(tag: 'manual')
                : null,
            icon: const Icon(Symbols.bookmark),
          ),
          IconButton(
            tooltip: "打开日志目录",
            onPressed: recorder.openLogDir,
            icon: const Icon(Symbols.folder),
          ),
          Switch(
            value: recorder.isRecording,
            onChanged: (v) async {
              if (v) {
                await recorder.start();
              } else {
                await recorder.stop();
              }
              setState(() {});
            },
          ),
        ],
      ),
    );
  }
}

class _WasapiBufferControlState extends State<WasapiBufferControl> {
  final pref = AppPreference.instance.playbackPref;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = pref.wasapiBufferSec.clamp(0.05, 0.30).toDouble();
    return SettingsTile(
      description: "WASAPI 缓冲时长",
      action: SizedBox(
        width: 260,
        child: Row(
          children: [
            Expanded(
              child: Slider(
                min: 0.05,
                max: 0.30,
                divisions: 25,
                value: v,
                onChanged: (nv) {
                  setState(() {
                    pref.wasapiBufferSec = nv;
                  });
                },
                onChangeEnd: (nv) async {
                  pref.wasapiBufferSec = nv;
                  await AppPreference.instance.save();
                },
              ),
            ),
            const SizedBox(width: 8),
            Text(
              "${v.toStringAsFixed(2)}s",
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
