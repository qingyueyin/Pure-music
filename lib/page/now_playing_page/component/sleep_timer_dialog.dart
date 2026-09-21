import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/play_service/sleep_timer.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class SleepTimerDialog extends StatefulWidget {
  const SleepTimerDialog({super.key});

  @override
  State<SleepTimerDialog> createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends State<SleepTimerDialog> {
  final _timer = SleepTimerService.instance;
  double _selectedMinutes = 30;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([
        _timer.stateNotifier,
        _timer.remainingNotifier,
      ]),
      builder: (context, _) {
        final state = _timer.state;
        final active = _timer.isActive;
        final remaining = _timer.remaining;
        final isExtending = state == SleepTimerState.extending;
        final minutes = _selectedMinutes.round();
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          title: const Text('睡眠定时'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!active) ...[
                  const SizedBox(height: 8),
                  SettingsTile(
                    description: '时长',
                    subtitle: '$minutes 分钟',
                    action: SizedBox(
                      width: 140,
                      child: Slider(
                        value: _selectedMinutes,
                        min: 1,
                        max: 180,
                        divisions: 179,
                        label: '$minutes 分钟',
                        onChanged: (v) =>
                            setState(() => _selectedMinutes = v),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SettingsTile(
                    description: '自动延长',
                    subtitle: '播完当前歌曲再暂停',
                    action: Switch(
                      value: _timer.autoExtendNotifier.value,
                      onChanged: (v) => setState(
                        () => _timer.autoExtendNotifier.value = v,
                      ),
                    ),
                  ),
                ] else ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: AppRadius.mdCircular,
                    ),
                    child: Column(
                      children: [
                        Icon(
                          isExtending ? Symbols.music_note : Symbols.timer,
                          size: 32,
                          color: scheme.primary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          isExtending
                              ? '正在等待当前歌曲播完'
                              : '剩余 ${SleepTimerService.formatDuration(remaining ?? Duration.zero)}',
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: AppType.subtitle,
                            fontWeight: AppType.weightMedium,
                          ),
                        ),
                        if (isExtending) ...[
                          const SizedBox(height: 4),
                          Text(
                            '切歌或暂停将取消定时',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: AppType.caption,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (active)
              TextButton(
                onPressed: () {
                  _timer.cancel();
                  Navigator.of(context).pop();
                },
                child: const Text('取消定时'),
              )
            else
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            if (!active)
              FilledButton(
                onPressed: () {
                  _timer.start(
                    Duration(minutes: _selectedMinutes.round()),
                  );
                },
                child: const Text('开始'),
              ),
          ],
        );
      },
    );
  }
}
