import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/setting_action_state.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class ArtistNoSplitEditor extends StatelessWidget {
  const ArtistNoSplitEditor({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '不拆分的艺术家',
      subtitle: '名称里带分隔符、但仍是一个人',
      action: FilledButton.icon(
        icon: const Icon(Symbols.edit),
        label: const Text('编辑名单'),
        onPressed: () {
          showDialog(
            context: context,
            builder: (context) => const _ArtistNoSplitEditDialog(),
          );
        },
      ),
    );
  }
}

class _ArtistNoSplitEditDialog extends StatefulWidget {
  const _ArtistNoSplitEditDialog();

  @override
  State<_ArtistNoSplitEditDialog> createState() =>
      _ArtistNoSplitEditDialogState();
}

class _ArtistNoSplitEditDialogState extends State<_ArtistNoSplitEditDialog> {
  final appSettings = AppSettings.instance;
  late final List<String> names = uniqueTextListItems(
    appSettings.artistNoSplitNames,
  );
  final currEditController = TextEditingController();
  bool editing = false;

  bool get _canAddName {
    return canAddUniqueTextListItem(
      existingItems: names,
      input: currEditController.text,
      isSaving: false,
    );
  }

  bool get _hasChanges {
    final original = appSettings.artistNoSplitNames;
    if (names.length != original.length) return true;
    for (var i = 0; i < names.length; i++) {
      if (names[i] != original[i]) return true;
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

  void _addName() {
    final name = currEditController.text.trim();
    if (!_canAddName) return;
    setState(() {
      names.add(name);
      editing = false;
      currEditController.clear();
    });
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
      isSaving: false,
      hasChanges: _hasChanges,
    );

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 24.0,
        vertical: 24.0,
      ),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '不拆分的艺术家',
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: AppType.sectionTitle,
                        fontWeight: AppType.weightBold,
                      ),
                    ),
                    Text(
                      '${names.length} 个名字',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: AppType.caption,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _nameList(scheme)),
              const SizedBox(height: 16.0),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8.0,
                overflowSpacing: 8.0,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        if (editing) {
                          editing = false;
                          currEditController.clear();
                        } else {
                          editing = true;
                        }
                      });
                    },
                    icon: Icon(editing ? Symbols.close : Symbols.add),
                    label: Text(editing ? '取消新增' : '新增'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  FilledButton.icon(
                    onPressed: !canApplyChanges
                        ? null
                        : () => _saveNames(context),
                    icon: const Icon(Symbols.check),
                    label: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nameList(ColorScheme scheme) {
    if (names.isEmpty && !editing) {
      return Center(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 28.0),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: AppRadius.mdCircular,
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Symbols.person, size: 40.0, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12.0),
              Text(
                '还没有保护名单',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: AppType.weightSemibold,
                ),
              ),
              const SizedBox(height: 4.0),
              Text(
                '例如把 AC/DC 加进来，就不会被拆成 AC 和 DC',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      children: [
        ...names.map(
          (name) => ListTile(
            title: Text(name),
            trailing: IconButton(
              tooltip: '移除',
              onPressed: () => setState(() => names.remove(name)),
              icon: const Icon(Symbols.remove_circle),
            ),
          ),
        ),
        if (editing)
          ListTile(
            title: Focus(
              onFocusChange: HotkeysHelper.onFocusChanges,
              child: TextField(
                controller: currEditController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '艺术家名称',
                  suffixIcon: IconButton(
                    tooltip: '添加',
                    onPressed: _canAddName ? _addName : null,
                    icon: const Icon(Symbols.done),
                  ),
                ),
                onSubmitted: (_) {
                  if (_canAddName) _addName();
                },
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _saveNames(BuildContext context) async {
    final oldNames = List<String>.from(appSettings.artistNoSplitNames);
    appSettings.artistNoSplitNames = List.from(names);
    final saved = await appSettings.saveSettings();
    if (!saved) {
      appSettings.artistNoSplitNames = oldNames;
      if (context.mounted) {
        showTextOnSnackBar('保存不拆分名单失败');
      }
      return;
    }
    await AudioLibrary.initFromIndex();
    if (context.mounted) {
      Navigator.pop(context);
    }
  }
}
