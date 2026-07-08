import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/setting_action_state.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class ArtistSeparatorEditor extends StatelessWidget {
  const ArtistSeparatorEditor({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '自定义艺术家分隔符',
      action: FilledButton.icon(
        icon: const Icon(Symbols.edit),
        label: const Text('管理艺术家分隔符'),
        onPressed: () {
          showDialog(
            context: context,
            builder: (context) => const _ArtistSeparatorEditDialog(),
          );
        },
      ),
    );
  }
}

class _ArtistSeparatorEditDialog extends StatefulWidget {
  const _ArtistSeparatorEditDialog();

  @override
  State<_ArtistSeparatorEditDialog> createState() =>
      __ArtistSeparatorEditDialogState();
}

class __ArtistSeparatorEditDialogState
    extends State<_ArtistSeparatorEditDialog> {
  final appSettings = AppSettings.instance;
  late final List<String> separators =
      uniqueTextListItems(appSettings.artistSeparator);
  final currEditController = TextEditingController();
  bool editing = false;
  bool _isSaving = false;

  bool get _canAddArtistSeparator {
    return canAddUniqueTextListItem(
      existingItems: separators,
      input: currEditController.text,
      isSaving: _isSaving,
    );
  }

  bool get _hasSeparatorChanges {
    final original = appSettings.artistSeparator;
    if (separators.length != original.length) return true;
    for (var i = 0; i < separators.length; i++) {
      if (separators[i] != original[i]) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    currEditController.addListener(_onEditingTextChanged);
  }

  void _onEditingTextChanged() {
    if (editing) setState(() {});
  }

  void _addArtistSeparator() {
    final separator = currEditController.text.trim();
    if (!_canAddArtistSeparator) return;

    setState(() {
      separators.add(separator);
      editing = false;
      currEditController.clear();
    });
  }

  void _removeArtistSeparator(String separator) {
    setState(() {
      separators.remove(separator);
    });
  }

  void _toggleEditingSeparator() {
    if (_isSaving) return;
    setState(() {
      if (editing) {
        editing = false;
        currEditController.clear();
      } else {
        editing = true;
      }
    });
  }

  Widget _buildSeparatorTile(String separator) {
    return ListTile(
      title: Text(separator),
      trailing: IconButton(
        tooltip: '移除',
        onPressed: _isSaving ? null : () => _removeArtistSeparator(separator),
        icon: const Icon(Symbols.remove_circle),
      ),
    );
  }

  Widget _buildEditingTile() {
    return ListTile(
      title: Focus(
        onFocusChange: HotkeysHelper.onFocusChanges,
        child: TextField(
          controller: currEditController,
          autofocus: true,
          enabled: !_isSaving,
          decoration: InputDecoration(
            labelText: '新的分隔符',
            suffixIcon: IconButton(
              tooltip: '添加',
              onPressed: !_isSaving && _canAddArtistSeparator
                  ? _addArtistSeparator
                  : null,
              icon: const Icon(Symbols.done),
            ),
          ),
          onSubmitted: (_) {
            if (!_isSaving && _canAddArtistSeparator) _addArtistSeparator();
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    currEditController.removeListener(_onEditingTextChanged);
    currEditController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48.0).clamp(300.0, 420.0).toDouble();
    final height = (size.height - 96.0).clamp(300.0, 420.0).toDouble();
    final canApplyChanges = canSaveListSettingChanges(
      isEditing: editing,
      isSaving: _isSaving,
      hasChanges: _hasSeparatorChanges,
    );
    final canToggleEditing = canTogglePendingListItem(isSaving: _isSaving);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 24.0,
        vertical: 24.0,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
      ),
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Wrap(
                  spacing: 8.0,
                  runSpacing: 8.0,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '管理艺术家分隔符',
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 18.0,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    _SeparatorCountPill(count: separators.length),
                  ],
                ),
              ),
              Expanded(
                child: separators.isEmpty && !editing
                    ? const _EmptySeparatorState()
                    : ListView(
                        children: [
                          ...separators.map(_buildSeparatorTile),
                          if (editing) _buildEditingTile(),
                        ],
                      ),
              ),
              const SizedBox(height: 16.0),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8.0,
                overflowSpacing: 8.0,
                children: [
                  TextButton.icon(
                    onPressed:
                        canToggleEditing ? _toggleEditingSeparator : null,
                    icon: Icon(editing ? Symbols.close : Symbols.add),
                    label: Text(editing ? '取消新增' : '新增'),
                  ),
                  TextButton(
                    onPressed: _isSaving ? null : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  FilledButton.icon(
                    onPressed: !canApplyChanges
                        ? null
                        : () async {
                            setState(() => _isSaving = true);
                            try {
                              final oldSeparators = List<String>.from(
                                appSettings.artistSeparator,
                              );
                              final oldPattern = appSettings.artistSplitPattern;
                              appSettings.artistSeparator =
                                  List.from(separators);
                              appSettings.artistSplitPattern =
                                  appSettings.artistSeparator.join('|');
                              final saved = await appSettings.saveSettings();
                              if (!saved) {
                                appSettings.artistSeparator = oldSeparators;
                                appSettings.artistSplitPattern = oldPattern;
                                if (context.mounted) {
                                  showTextOnSnackBar('保存艺术家分隔符失败');
                                }
                                return;
                              }
                              await AudioLibrary.initFromIndex();
                              if (context.mounted) {
                                Navigator.pop(context);
                              }
                            } finally {
                              if (mounted) {
                                setState(() => _isSaving = false);
                              }
                            }
                          },
                    icon: _isSaving
                        ? const SizedBox(
                            width: 18.0,
                            height: 18.0,
                            child: CircularProgressIndicator(strokeWidth: 2.0),
                          )
                        : const Icon(Symbols.check),
                    label: Text(_isSaving ? '保存中' : '确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeparatorCountPill extends StatelessWidget {
  const _SeparatorCountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      height: 28.0,
      padding: const EdgeInsets.symmetric(horizontal: 10.0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(14.0),
      ),
      child: Text(
        '$count 个',
        style: TextStyle(
          color: scheme.onSecondaryContainer,
          fontSize: 12.0,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptySeparatorState extends StatelessWidget {
  const _EmptySeparatorState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 28.0),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20.0),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.group,
              size: 40.0,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12.0),
            Text(
              '还没有自定义分隔符',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4.0),
            Text(
              '新增后会用于拆分多艺术家名称',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
