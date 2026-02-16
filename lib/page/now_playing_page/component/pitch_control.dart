import 'dart:async';

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

    return MenuAnchor(
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
          tooltip: "音调",
          icon: const Icon(Symbols.music_note),
          color: scheme.onSecondaryContainer,
        );
      },
      menuChildren: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
          child: NowPlayingPitchPanel(width: 300),
        ),
      ],
    );
  }
}

class NowPlayingPitchDialog extends StatelessWidget {
  const NowPlayingPitchDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: NowPlayingPitchPanel(width: 360),
      ),
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
  Timer? _indicatorTimer;
  bool _showCustomIndicator = false;
  bool _isHovering = false;

  void _triggerIndicator() {
    setState(() => _showCustomIndicator = true);
    _indicatorTimer?.cancel();
    _indicatorTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) {
        setState(() => _showCustomIndicator = false);
      }
    });
  }

  @override
  void dispose() {
    _indicatorTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playbackService = PlayService.instance.playbackService;

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
                borderRadius: BorderRadius.circular(8.0),
              ),
              child: Text(
                "BASS_FX missing",
                style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text("音调(半音)", style: TextStyle(color: scheme.onSurface)),
              IconButton(
                icon: const Icon(Symbols.restart_alt, size: 16),
                onPressed: () => playbackService.setPitch(0.0),
                tooltip: "重置音调",
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
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
                    onPressed: playbackService.isBassFxLoaded
                        ? () {
                            final newValue =
                                (pitchValue - 1.0).clamp(-12.0, 12.0);
                            playbackService.setPitch(newValue);
                            _triggerIndicator();
                          }
                        : null,
                    icon: const Icon(Symbols.remove),
                    color: scheme.onSurface,
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
                      final double leftOffset = padding + (trackWidth * percent);

                      return MouseRegion(
                        onEnter: (_) => setState(() => _isHovering = true),
                        onExit: (_) => setState(() => _isHovering = false),
                        child: Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.centerLeft,
                          children: [
                            Slider(
                              thumbColor: scheme.primary,
                              activeColor: scheme.primary,
                              inactiveColor: scheme.outline,
                              min: min,
                              max: max,
                              divisions: 24,
                              value: pitchValue,
                              onChanged: playbackService.isBassFxLoaded
                                  ? (value) {
                                      playbackService.setPitch(value);
                                    }
                                  : null,
                            ),
                            if (_showCustomIndicator || _isHovering)
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
                    onPressed: playbackService.isBassFxLoaded
                        ? () {
                            final newValue =
                                (pitchValue + 1.0).clamp(-12.0, 12.0);
                            playbackService.setPitch(newValue);
                            _triggerIndicator();
                          }
                        : null,
                    icon: const Icon(Symbols.add),
                    color: scheme.onSurface,
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

class _CustomValueIndicator extends StatelessWidget {
  final double value;
  final Color color;
  final Color textColor;

  const _CustomValueIndicator({
    required this.value,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            "${value > 0 ? '+' : ''}${value.toInt()}",
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.bold,
              fontSize: 14,
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
