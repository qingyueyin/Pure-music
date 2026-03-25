import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';

class LyricEffectsSettingsTile extends StatelessWidget {
  const LyricEffectsSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: "歌词效果",
      action: FilledButton.icon(
        onPressed: () {
          showDialog(
            context: context,
            builder: (context) => const _LyricEffectsDialog(),
          );
        },
        icon: const Icon(Symbols.tune),
        label: const Text("打开"),
      ),
    );
  }
}

class _LyricEffectsDialog extends StatelessWidget {
  const _LyricEffectsDialog();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = LyricViewController.instance;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 840,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "歌词效果",
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          _LyricEffectCard(
                            title: "启用歌词模糊效果",
                            description: "对性能影响较高，如果遇到性能问题，可以尝试关闭此项。默认开启。",
                            value: controller.enableLyricBlur,
                            onChanged: (_) => controller.toggleLyricBlur(),
                          ),
                          const SizedBox(height: 12),
                          _LyricEffectCard(
                            title: "启用歌词缩放效果",
                            description: "对性能无影响，非当前播放歌词行会略微缩小。默认开启。",
                            value: controller.enableLyricScale,
                            onChanged: (_) => controller.toggleLyricScale(),
                          ),
                          const SizedBox(height: 12),
                          _LyricEffectCard(
                            title: "启用歌词行弹簧动画效果",
                            description: "对性能影响较高，如果遇到性能问题，可以尝试关闭此项。默认开启。",
                            value: controller.enableLyricSpring,
                            onChanged: (_) => controller.toggleLyricSpring(),
                          ),
                          const SizedBox(height: 12),
                          _LyricEffectCard(
                            title: "提前歌词行时序",
                            description:
                                "即将原歌词行的初始时间时序提前，以便在歌词滚动结束后刚好开始播放（逐词）歌词效果。这个行为更加接近 Apple Music 的效果，但大部分情况下会导致歌词行末尾的歌词尚未播放完成便被切换到下一行。",
                            value: controller.enableAdvanceLyricTiming,
                            onChanged: (_) =>
                                controller.toggleAdvanceLyricTiming(),
                          ),
                          const SizedBox(height: 12),
                          _LyricFadePresetCard(controller: controller),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text("关闭"),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _LyricEffectCard extends StatelessWidget {
  const _LyricEffectCard({
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  description,
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.78),
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Switch(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _LyricFadePresetCard extends StatelessWidget {
  const _LyricFadePresetCard({required this.controller});

  final LyricViewController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "逐词渐变宽度",
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "调节逐词歌词时单词的渐变过渡宽度，单位为一个全角字的宽度。默认 0.5。\n如果要模拟 Apple Music for Android 的效果，可以设置为 1。\n如果要模拟 Apple Music for iPad 的效果，可以设置为 0.5。\n如需关闭逐词歌词时单词的渐变过渡效果，可以设置为 0。",
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: 0.78),
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 14),
          SegmentedButton<double>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment<double>(
                value: 0.0,
                label: Text("关闭"),
              ),
              ButtonSegment<double>(
                value: 0.5,
                label: Text("iPad"),
              ),
              ButtonSegment<double>(
                value: 1.0,
                label: Text("Android"),
              ),
            ],
            selected: {controller.wordFadeWidth},
            onSelectionChanged: (selection) {
              controller.setWordFadeWidth(selection.first);
            },
          ),
        ],
      ),
    );
  }
}
