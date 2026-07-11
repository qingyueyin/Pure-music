import 'package:flutter/material.dart';
import 'package:pure_music/core/enums.dart';

class LyricLineOrderSheet extends StatefulWidget {
  final List<LyricLineTrack> currentOrder;
  final ValueChanged<List<LyricLineTrack>> onOrderChanged;

  const LyricLineOrderSheet({
    super.key,
    required this.currentOrder,
    required this.onOrderChanged,
  });

  @override
  State<LyricLineOrderSheet> createState() => _LyricLineOrderSheetState();
}

class _LyricLineOrderSheetState extends State<LyricLineOrderSheet> {
  late List<LyricLineTrack> _items;

  @override
  void initState() {
    super.initState();
    _items = List.of(normalizedLyricLineOrder(widget.currentOrder));
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final item = _items.removeAt(oldIndex);
      _items.insert(newIndex, item);
    });
  }

  static const _labels = {
    LyricLineTrack.original: '原文',
    LyricLineTrack.romanization: '注音',
    LyricLineTrack.translation: '翻译',
  };

  static const _icons = {
    LyricLineTrack.original: Icons.text_fields,
    LyricLineTrack.romanization: Icons.language,
    LyricLineTrack.translation: Icons.translate,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: 360,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '歌词内容顺序',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      widget.onOrderChanged(_items);
                      Navigator.of(context).pop();
                    },
                    child: const Text('完成'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '拖动调整原文、注音、翻译的显示顺序',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
            const Divider(height: 16),
            Expanded(
              child:               ReorderableListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: _items.length,
                onReorderItem: _onReorder,
                buildDefaultDragHandles: false,
                itemBuilder: (context, index) {
                  final track = _items[index];
                  return ReorderableDragStartListener(
                    key: ValueKey(track),
                    index: index,
                    child: ListTile(
                      leading: Icon(_icons[track]),
                      title: Text(_labels[track] ?? track.name),
                      trailing: const Icon(Icons.drag_handle),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
