import 'package:flutter/material.dart';

class LyricWordEmphasis extends StatefulWidget {
  final String text;
  final double progress;
  final TextStyle style;
  final TextStyle? emphasisStyle;
  final bool isMainLine;

  const LyricWordEmphasis({
    super.key,
    required this.text,
    required this.progress,
    required this.style,
    this.emphasisStyle,
    this.isMainLine = false,
  });

  @override
  State<LyricWordEmphasis> createState() => _LyricWordEmphasisState();
}

class _LyricWordEmphasisState extends State<LyricWordEmphasis> {
  @override
  Widget build(BuildContext context) {
    final scale = 1.0 + 0.1 * Curves.easeInOutCubic.transform(widget.progress);
    final offsetY = -1.5 * Curves.easeOutCubic.transform(widget.progress);

    return Transform.translate(
      offset: Offset(0, offsetY),
      child: Transform.scale(
        scale: scale,
        child: Text(
          widget.text,
          style: widget.style,
        ),
      ),
    );
  }
}
