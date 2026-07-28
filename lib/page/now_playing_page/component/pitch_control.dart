import 'dart:async';

import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class NowPlayingPitchControl extends StatefulWidget {
  const NowPlayingPitchControl({super.key});

  @override
  State<NowPlayingPitchControl> createState() => _NowPlayingPitchControlState();
}

class _NowPlayingPitchControlState extends State<NowPlayingPitchControl> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final panelWidth =
        (MediaQuery.sizeOf(context).width - 64).clamp(240.0, 300.0).toDouble();

    return MenuAnchor(
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
        ),
      ),
      builder: (context, controller, child) {
        return IconButton(
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          tooltip: '音调',
          icon: const Icon(Symbols.music_note),
          color: useMonet ? scheme.primary : scheme.onSurface,
        );
      },
      menuChildren: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
          child: NowPlayingPitchPanel(width: panelWidth),
        ),
      ],
    );
  }
}

class NowPlayingPitchPanel extends StatefulWidget {
  const NowPlayingPitchPanel({super.key, required this.width});

  final double width;

  @override
  State<NowPlayingPitchPanel> createState() => _NowPlayingPitchPanelState();
}

class _NowPlayingPitchPanelState extends State<NowPlayingPitchPanel> {
  Timer? _pitchIndicatorTimer;
  Timer? _rateIndicatorTimer;
  bool _showPitchIndicator = false;
  bool _showRateIndicator = false;
  bool _isPitchHovering = false;
  bool _isRateHovering = false;

  void _triggerPitchIndicator() {
    setState(() => _showPitchIndicator = true);
    _pitchIndicatorTimer?.cancel();
    _pitchIndicatorTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) {
        setState(() => _showPitchIndicator = false);
      }
    });
  }

  void _triggerRateIndicator() {
    setState(() => _showRateIndicator = true);
    _rateIndicatorTimer?.cancel();
    _rateIndicatorTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) {
        setState(() => _showRateIndicator = false);
      }
    });
  }

  @override
  void dispose() {
    _pitchIndicatorTimer?.cancel();
    _rateIndicatorTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playbackService = PlayService.instance.playbackService;
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final keepPitch = AppSettings.instance.keepPitch;

    return SizedBox(
      width: widget.width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!playbackService.isBassFxLoaded)
            Container(
              margin: const EdgeInsets.only(bottom: 8.0),
              padding: const EdgeInsets.all(8.0),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: AppRadius.smCircular,
              ),
              child: Text(
                'BASS_FX missing',
                style: TextStyle(color: scheme.onErrorContainer, fontSize: AppType.caption),
              ),
            ),
          // 保持音调开关
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '保持音调',
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: AppType.weightSemibold,
                ),
              ),
              Switch(
                value: keepPitch,
                onChanged: (value) {
                  setState(() {
                    AppSettings.instance.keepPitch = value;
                  });
                  AppSettings.instance.saveSettings();
                },
                activeThumbColor: useMonet ? scheme.primary : null,
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 音调调节
          ValueListenableBuilder(
            valueListenable: playbackService.pitch,
            builder: (context, pitchValue, _) {
              final canReset = playbackService.isBassFxLoaded &&
                  pitchValue.abs() > 0.001 &&
                  !keepPitch;
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '变调',
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontWeight: AppType.weightSemibold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _PitchValuePill(value: pitchValue),
                    ],
                  ),
                  _PitchResetButton(
                    extended: widget.width >= 300,
                    onPressed: canReset
                        ? () {
                            playbackService.setPitch(0.0);
                            _triggerPitchIndicator();
                          }
                        : null,
                  ),
                ],
              );
            },
          ),
          SliderTheme(
            data: const SliderThemeData(
              showValueIndicator: ShowValueIndicator.never,
            ),
            child: ValueListenableBuilder(
              valueListenable: playbackService.pitch,
              builder: (context, pitchValue, _) => Row(
                children: [
                  IconButton(
                    onPressed:
                        playbackService.isBassFxLoaded && pitchValue > -12.0 && !keepPitch
                            ? () {
                                final newValue =
                                    (pitchValue - 1.0).clamp(-12.0, 12.0);
                                playbackService.setPitch(newValue);
                                _triggerPitchIndicator();
                              }
                            : null,
                    icon: const Icon(Symbols.remove),
                    color: useMonet ? scheme.primary : scheme.onSurface,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  Expanded(
                    child: LayoutBuilder(builder: (context, constraints) {
                      const double padding = 24.0;
                      final double trackWidth =
                          constraints.maxWidth - (padding * 2);
                      const double min = -12.0;
                      const double max = 12.0;
                      final double percent = (pitchValue - min) / (max - min);
                      final double leftOffset =
                          padding + (trackWidth * percent);

                      return MouseRegion(
                        onEnter: (_) => setState(() => _isPitchHovering = true),
                        onExit: (_) => setState(() => _isPitchHovering = false),
                        child: Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.centerLeft,
                          children: [
                            Slider(
                              min: min,
                              max: max,
                              divisions: 24,
                              value: pitchValue,
                              onChanged: playbackService.isBassFxLoaded && !keepPitch
                                  ? (value) {
                                      playbackService.setPitch(value);
                                    }
                                  : null,
                            ),
                            if (_showPitchIndicator || _isPitchHovering)
                              Positioned(
                                left: leftOffset - 24.0,
                                top: -40,
                                child: IgnorePointer(
                                  child: _CustomValueIndicator(
                                    value: pitchValue,
                                    color: scheme.primary,
                                    textColor: scheme.onPrimary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                  ),
                  IconButton(
                    onPressed:
                        playbackService.isBassFxLoaded && pitchValue < 12.0 && !keepPitch
                            ? () {
                                final newValue =
                                    (pitchValue + 1.0).clamp(-12.0, 12.0);
                                playbackService.setPitch(newValue);
                                _triggerPitchIndicator();
                              }
                            : null,
                    icon: const Icon(Symbols.add),
                    color: useMonet ? scheme.primary : scheme.onSurface,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 变速调节
          ValueListenableBuilder(
            valueListenable: playbackService.rate,
            builder: (context, rateValue, _) {
              final canReset =
                  playbackService.isBassFxLoaded && (rateValue - 1.0).abs() > 0.001;
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '变速',
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontWeight: AppType.weightSemibold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _RateValuePill(value: rateValue),
                    ],
                  ),
                  _RateResetButton(
                    extended: widget.width >= 300,
                    onPressed: canReset
                        ? () {
                            playbackService.setRate(1.0);
                            _triggerRateIndicator();
                          }
                        : null,
                  ),
                ],
              );
            },
          ),
          SliderTheme(
            data: const SliderThemeData(
              showValueIndicator: ShowValueIndicator.never,
            ),
            child: ValueListenableBuilder(
              valueListenable: playbackService.rate,
              builder: (context, rateValue, _) => Row(
                children: [
                  IconButton(
                    onPressed:
                        playbackService.isBassFxLoaded && rateValue > 0.5
                            ? () {
                                final newValue =
                                    (rateValue - 0.1).clamp(0.5, 2.0);
                                playbackService.setRate(newValue);
                                _triggerRateIndicator();
                              }
                            : null,
                    icon: const Icon(Symbols.remove),
                    color: useMonet ? scheme.primary : scheme.onSurface,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  Expanded(
                    child: LayoutBuilder(builder: (context, constraints) {
                      const double padding = 24.0;
                      final double trackWidth =
                          constraints.maxWidth - (padding * 2);
                      const double min = 0.5;
                      const double max = 2.0;
                      final double percent = (rateValue - min) / (max - min);
                      final double leftOffset =
                          padding + (trackWidth * percent);

                      return MouseRegion(
                        onEnter: (_) => setState(() => _isRateHovering = true),
                        onExit: (_) => setState(() => _isRateHovering = false),
                        child: Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.centerLeft,
                          children: [
                            Slider(
                              min: min,
                              max: max,
                              divisions: 15,
                              value: rateValue,
                              onChanged: playbackService.isBassFxLoaded
                                  ? (value) {
                                      playbackService.setRate(value);
                                    }
                                  : null,
                            ),
                            if (_showRateIndicator || _isRateHovering)
                              Positioned(
                                left: leftOffset - 24.0,
                                top: -40,
                                child: IgnorePointer(
                                  child: _CustomValueIndicator(
                                    value: rateValue,
                                    color: scheme.primary,
                                    textColor: scheme.onPrimary,
                                    isInteger: false,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                  ),
                  IconButton(
                    onPressed:
                        playbackService.isBassFxLoaded && rateValue < 2.0
                            ? () {
                                final newValue =
                                    (rateValue + 0.1).clamp(0.5, 2.0);
                                playbackService.setRate(newValue);
                                _triggerRateIndicator();
                              }
                            : null,
                    icon: const Icon(Symbols.add),
                    color: useMonet ? scheme.primary : scheme.onSurface,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
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

String _formatPitchValue(double value) {
  final semitones = value.round();
  if (semitones == 0) {
    return '0 半音';
  }

  return '${semitones > 0 ? '+' : ''}$semitones 半音';
}

String _formatRateValue(double value) {
  final percent = ((value - 1.0) * 100).round();
  if (percent == 0) {
    return '1.0x';
  }

  return '${value.toStringAsFixed(1)}x';
}

class _PitchValuePill extends StatelessWidget {
  const _PitchValuePill({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: AppRadius.mdCircular,
      ),
      child: Text(
        _formatPitchValue(value),
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontSize: AppType.caption,
          fontWeight: AppType.weightSemibold,
        ),
      ),
    );
  }
}

class _PitchResetButton extends StatelessWidget {
  const _PitchResetButton({
    required this.extended,
    required this.onPressed,
  });

  final bool extended;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final foreground = useMonet ? scheme.primary : scheme.onSurfaceVariant;
    final style = TextButton.styleFrom(
      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      foregroundColor: foreground,
      minimumSize: const Size(0, 32),
      padding: EdgeInsets.symmetric(horizontal: extended ? 10 : 8),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const TextStyle(fontSize: AppType.caption, fontWeight: AppType.weightSemibold),
      visualDensity: VisualDensity.compact,
    );

    final icon = Icon(Symbols.restart_alt, size: 16, color: foreground);

    if (!extended) {
      return Tooltip(
        message: '重置音调',
        child: TextButton(
          onPressed: onPressed,
          style: style,
          child: icon,
        ),
      );
    }

    return TextButton.icon(
      onPressed: onPressed,
      style: style,
      icon: icon,
      label: const Text('归零'),
    );
  }
}

class _RateValuePill extends StatelessWidget {
  const _RateValuePill({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: AppRadius.mdCircular,
      ),
      child: Text(
        _formatRateValue(value),
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontSize: AppType.caption,
          fontWeight: AppType.weightSemibold,
        ),
      ),
    );
  }
}

class _RateResetButton extends StatelessWidget {
  const _RateResetButton({
    required this.extended,
    required this.onPressed,
  });

  final bool extended;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final foreground = useMonet ? scheme.primary : scheme.onSurfaceVariant;
    final style = TextButton.styleFrom(
      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      foregroundColor: foreground,
      minimumSize: const Size(0, 32),
      padding: EdgeInsets.symmetric(horizontal: extended ? 10 : 8),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const TextStyle(fontSize: AppType.caption, fontWeight: AppType.weightSemibold),
      visualDensity: VisualDensity.compact,
    );

    final icon = Icon(Symbols.restart_alt, size: 16, color: foreground);

    if (!extended) {
      return Tooltip(
        message: '重置变速',
        child: TextButton(
          onPressed: onPressed,
          style: style,
          child: icon,
        ),
      );
    }

    return TextButton.icon(
      onPressed: onPressed,
      style: style,
      icon: icon,
      label: const Text('归零'),
    );
  }
}

class _CustomValueIndicator extends StatelessWidget {
  final double value;
  final Color color;
  final Color textColor;
  final bool isInteger;

  const _CustomValueIndicator({
    required this.value,
    required this.color,
    required this.textColor,
    this.isInteger = true,
  });

  @override
  Widget build(BuildContext context) {
    final displayText = isInteger
        ? "${value > 0 ? '+' : ''}${value.toInt()}"
        : value.toStringAsFixed(1);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: AppRadius.smCircular,
          ),
          child: Text(
            displayText,
            style: TextStyle(
              color: textColor,
              fontWeight: AppType.weightBold,
              fontSize: AppType.body,
            ),
          ),
        ),
        CustomPaint(
          size: const Size(12, 6),
          painter: _TrianglePainter(color),
        ),
      ],
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color color;

  _TrianglePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(0, 0);
    path.lineTo(size.width / 2, size.height);
    path.lineTo(size.width, 0);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
