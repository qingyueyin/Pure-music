import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:pure_music/core/design_tokens.dart';

const List<String> alphabetIndexSections = [
  '0',
  'A',
  'B',
  'C',
  'D',
  'E',
  'F',
  'G',
  'H',
  'I',
  'J',
  'K',
  'L',
  'M',
  'N',
  'O',
  'P',
  'Q',
  'R',
  'S',
  'T',
  'U',
  'V',
  'W',
  'X',
  'Y',
  'Z',
  '#',
];

class AlphabetIndexBar extends StatefulWidget {
  const AlphabetIndexBar({
    super.key,
    required this.controller,
    required this.sectionIndexes,
    required this.indexForOffset,
    required this.onSelectIndex,
    required this.onWheel,
    this.descending = false,
  });

  final ScrollController controller;
  final Map<String, int> sectionIndexes;
  final int Function(double offset) indexForOffset;
  final ValueChanged<int> onSelectIndex;
  final ValueChanged<double> onWheel;
  final bool descending;

  @override
  State<AlphabetIndexBar> createState() => _AlphabetIndexBarState();
}

class _AlphabetIndexBarState extends State<AlphabetIndexBar>
    with SingleTickerProviderStateMixin {
  static const _railVerticalPadding = 10.0;
  static const _bubbleFollowK = 18.0;
  String? _activeSection;
  String? _pressedSection;
  late final Ticker _bubbleTicker;
  Duration _bubbleElapsed = Duration.zero;
  double _bubbleTop = 0.0;
  double _bubbleTarget = 0.0;

  List<String> get _sections =>
      (widget.descending
              ? alphabetIndexSections.reversed
              : alphabetIndexSections)
          .where(widget.sectionIndexes.containsKey)
          .toList(growable: false);

  double _cellHeight(double barHeight, int sectionCount) {
    if (barHeight <= 0 || sectionCount == 0) return 0.0;
    final availableHeight = (barHeight - _railVerticalPadding).clamp(
      0.0,
      double.infinity,
    );
    final naturalHeight = availableHeight / sectionCount;
    return naturalHeight < 18.0 ? naturalHeight : 18.0;
  }

  double _contentTop(double barHeight, double contentHeight) {
    final availableHeight = (barHeight - _railVerticalPadding)
        .clamp(0.0, double.infinity)
        .toDouble();
    return _railVerticalPadding / 2 +
        ((availableHeight - contentHeight) / 2)
            .clamp(0.0, double.infinity)
            .toDouble();
  }

  @override
  void initState() {
    super.initState();
    _bubbleTicker = createTicker(_onBubbleTick);
    widget.controller.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleScroll());
  }

  @override
  void didUpdateWidget(covariant AlphabetIndexBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleScroll);
      widget.controller.addListener(_handleScroll);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleScroll());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleScroll);
    _bubbleTicker.dispose();
    super.dispose();
  }

  void _onBubbleTick(Duration elapsed) {
    if (!mounted) return;
    var dt = (elapsed - _bubbleElapsed).inMicroseconds / 1e6;
    if (_bubbleElapsed == Duration.zero) dt = 0.0;
    _bubbleElapsed = elapsed;
    if (dt <= 0) return;
    dt = min(dt, 1 / 30);
    final next =
        _bubbleTop + (_bubbleTarget - _bubbleTop) * (1 - exp(-_bubbleFollowK * dt));
    if ((next - _bubbleTarget).abs() < 0.05) {
      if (_bubbleTop != _bubbleTarget) {
        setState(() => _bubbleTop = _bubbleTarget);
      }
      _bubbleTicker.stop();
      _bubbleElapsed = Duration.zero;
      return;
    }
    setState(() => _bubbleTop = next);
  }

  double _indicatorTopForIndex(int index, double barHeight) {
    final sections = _sections;
    final cellHeight = _cellHeight(barHeight, sections.length);
    final contentHeight = cellHeight * sections.length;
    final contentTop = _contentTop(barHeight, contentHeight);
    return (contentTop + index * cellHeight + cellHeight / 2 - 20)
        .clamp(0.0, (barHeight - 40).clamp(0.0, barHeight))
        .toDouble();
  }

  void _handleScroll() {
    if (!mounted || !widget.controller.hasClients) return;
    if (widget.sectionIndexes.isEmpty) {
      if (_activeSection != null) setState(() => _activeSection = null);
      return;
    }
    final visibleIndex = widget.indexForOffset(widget.controller.offset);
    String? section;
    var nearestIndex = -1;
    for (final entry in widget.sectionIndexes.entries) {
      if (entry.value <= visibleIndex && entry.value >= nearestIndex) {
        nearestIndex = entry.value;
        section = entry.key;
      }
    }
    section ??= widget.sectionIndexes.entries
        .reduce((a, b) => a.value < b.value ? a : b)
        .key;
    if (section != _activeSection) setState(() => _activeSection = section);
  }

  int _targetIndex(String section) {
    final exact = widget.sectionIndexes[section];
    if (exact != null) return exact;
    final sections = _sections;
    final requestedAt = sections.indexOf(section);
    if (requestedAt < 0) return 0;
    for (var i = requestedAt + 1; i < sections.length; i++) {
      final target = widget.sectionIndexes[sections[i]];
      if (target != null) return target;
    }
    for (var i = sections.length - 1; i >= 0; i--) {
      final target = widget.sectionIndexes[sections[i]];
      if (target != null) return target;
    }
    return 0;
  }

  void _selectAt(double y, double barHeight) {
    final sections = _sections;
    final cellHeight = _cellHeight(barHeight, sections.length);
    if (cellHeight <= 0) return;
    final contentHeight = cellHeight * sections.length;
    final contentTop = _contentTop(barHeight, contentHeight);
    final index = (((y - contentTop) / cellHeight).floor()).clamp(
      0,
      sections.length - 1,
    );
    final section = sections[index];
    if (_pressedSection == section) return;
    final top = _indicatorTopForIndex(index, barHeight);
    final firstShow = _pressedSection == null;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    setState(() {
      _pressedSection = section;
      _activeSection = section;
      _bubbleTarget = top;
      if (firstShow || reduceMotion) _bubbleTop = top;
    });
    if (!reduceMotion && !firstShow && !_bubbleTicker.isActive) {
      _bubbleElapsed = Duration.zero;
      _bubbleTicker.start();
    }
    widget.onSelectIndex(_targetIndex(section));
  }

  void _clearSelection() {
    if (_pressedSection == null) return;
    _bubbleTicker.stop();
    _bubbleElapsed = Duration.zero;
    setState(() => _pressedSection = null);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sections = _sections;
    final highlightedSection = _pressedSection ?? _activeSection;
    return SizedBox(
      width: 32,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final barHeight = constraints.maxHeight;
          final cellHeight = _cellHeight(barHeight, sections.length);
          final contentHeight = cellHeight * sections.length;
          final contentTop = _contentTop(barHeight, contentHeight);
          final indicatorTop = _pressedSection == null
              ? _bubbleTop
              : MediaQuery.disableAnimationsOf(context)
              ? _indicatorTopForIndex(
                  sections.indexOf(_pressedSection!),
                  barHeight,
                )
              : _bubbleTop;
          return Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                widget.onWheel(event.scrollDelta.dy);
              }
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (_pressedSection != null)
                  Positioned(
                    right: 40,
                    top: indicatorTop,
                    child: IgnorePointer(
                      child: Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer.withValues(
                            alpha: 0.92,
                          ),
                          borderRadius: AppRadius.smCircular,
                        ),
                        child: Text(
                          _pressedSection!,
                          style: TextStyle(
                            color: scheme.onSecondaryContainer,
                            fontSize: AppType.sectionTitle,
                            fontWeight: AppType.weightBold,
                          ),
                        ),
                      ),
                    ),
                  ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) =>
                      _selectAt(details.localPosition.dy, barHeight),
                  onTapUp: (_) => _clearSelection(),
                  onTapCancel: _clearSelection,
                  onVerticalDragStart: (details) =>
                      _selectAt(details.localPosition.dy, barHeight),
                  onVerticalDragUpdate: (details) =>
                      _selectAt(details.localPosition.dy, barHeight),
                  onVerticalDragEnd: (_) => _clearSelection(),
                  onVerticalDragCancel: _clearSelection,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: EdgeInsets.only(top: contentTop, right: 4),
                      child: Column(
                        children: [
                          for (final section in sections)
                            SizedBox(
                              width: 24,
                              height: cellHeight,
                              child: Center(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: section == _pressedSection
                                        ? scheme.primary.withValues(alpha: 0.12)
                                        : Colors.transparent,
                                    borderRadius: AppRadius.xsCircular,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 1,
                                    ),
                                    child: Text(
                                      section,
                                      style: TextStyle(
                                        color: section == highlightedSection
                                            ? scheme.primary
                                            : scheme.onSurfaceVariant
                                                  .withValues(alpha: 0.68),
                                        fontSize:
                                            cellHeight < AppType.microlabel
                                            ? (cellHeight * 0.72)
                                                  .clamp(7.0, 10.0)
                                                  .toDouble()
                                            : AppType.microlabel,
                                        fontWeight: section == _pressedSection
                                            ? AppType.weightSemibold
                                            : section == _activeSection
                                            ? AppType.weightSemibold
                                            : AppType.weightMedium,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
