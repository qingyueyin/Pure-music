import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

class _AlphabetIndexBarState extends State<AlphabetIndexBar> {
  String? _activeSection;
  String? _pressedSection;

  List<String> get _sections => widget.descending
      ? alphabetIndexSections.reversed.toList(growable: false)
      : alphabetIndexSections;

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  void _handleScroll() {
    if (!mounted || !widget.controller.hasClients) return;
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
    if (barHeight <= 0) return;
    final sections = _sections;
    const cellHeight = 18.0;
    final contentHeight = cellHeight * sections.length;
    final contentTop = ((barHeight - contentHeight) / 2)
        .clamp(0.0, double.infinity)
        .toDouble();
    final index = (((y - contentTop) / cellHeight).floor()).clamp(
      0,
      sections.length - 1,
    );
    final section = sections[index];
    if (_pressedSection == section) return;
    setState(() {
      _pressedSection = section;
      _activeSection = section;
    });
    widget.onSelectIndex(_targetIndex(section));
  }

  void _clearSelection() {
    if (_pressedSection != null) setState(() => _pressedSection = null);
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
          const cellHeight = 18.0;
          final contentHeight = cellHeight * sections.length;
          final contentTop = ((barHeight - contentHeight) / 2)
              .clamp(0.0, double.infinity)
              .toDouble();
          final selectedAt = _pressedSection == null
              ? -1
              : sections.indexOf(_pressedSection!);
          final indicatorTop = selectedAt < 0
              ? 0.0
              : (contentTop + selectedAt * cellHeight + cellHeight / 2 - 20)
                    .clamp(0.0, (barHeight - 40).clamp(0.0, barHeight))
                    .toDouble();
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
                      padding: EdgeInsets.only(top: contentTop),
                      child: Column(
                        children: [
                          for (final section in sections)
                            SizedBox(
                              width: 32,
                              height: cellHeight,
                              child: Center(
                                child: Text(
                                  section,
                                  style: TextStyle(
                                    color: section == highlightedSection
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant.withValues(
                                            alpha:
                                                widget.sectionIndexes
                                                    .containsKey(section)
                                                ? 0.82
                                                : 0.3,
                                          ),
                                    fontSize: AppType.microlabel,
                                    fontWeight: section == highlightedSection
                                        ? AppType.weightBold
                                        : AppType.weightMedium,
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
