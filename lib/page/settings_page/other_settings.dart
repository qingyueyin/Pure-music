import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class ReplayGainControl extends StatefulWidget {
  const ReplayGainControl({super.key});

  @override
  State<ReplayGainControl> createState() => _ReplayGainControlState();
}

class _ReplayGainControlState extends State<ReplayGainControl> {
  final pref = AppPreference.instance.playbackPref;

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: 'ReplayGain',
      action: Switch(
        value: pref.replayGainEnabled,
        onChanged: (value) async {
          setState(() => pref.replayGainEnabled = value);
          PlayService.instance.playbackService.setReplayGainEnabled(value);
          await AppPreference.instance.save();
        },
      ),
    );
  }
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
              borderRadius: AppRadius.mdCircular,
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
                ? () async {
                    recorder.snapshot(tag: 'manual');
                    await recorder.flush();
                    if (!context.mounted) return;
                    showTextOnSnackBar('已写入快照');
                  }
                : null,
            icon: const Icon(Symbols.bookmark),
          ),
          IconButton(
            tooltip: '打开日志目录',
            onPressed: () async {
              final opened = await recorder.openLogDir();
              if (!context.mounted) return;
              showTextOnSnackBar(opened ? '已打开日志目录' : '日志目录打开失败');
            },
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
                    } catch (_) {
                      if (mounted) {
                        showTextOnSnackBar(v ? '日志录制启动失败' : '日志录制停止失败');
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
