import 'package:pure_music/core/artist_name_splitter.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/setting_action_state.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class ArtistAliasEditor extends StatelessWidget {
  const ArtistAliasEditor({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '艺术家别名',
      subtitle: '把不同写法归为同一个人，不改文件',
      action: FilledButton.icon(
        icon: const Icon(Symbols.edit),
        label: const Text('编辑别名'),
        onPressed: () {
          showDialog(
            context: context,
            builder: (context) => const _ArtistAliasEditDialog(),
          );
        },
      ),
    );
  }
}

class _ArtistAliasEditDialog extends StatefulWidget {
  const _ArtistAliasEditDialog();

  @override
  State<_ArtistAliasEditDialog> createState() => _ArtistAliasEditDialogState();
}

class _ArtistAliasEditDialogState extends State<_ArtistAliasEditDialog> {
  final appSettings = AppSettings.instance;
  late final Map<String, String> aliases = Map<String, String>.from(
    appSettings.artistAliases,
  );
  final sourceController = TextEditingController();
  final displayController = TextEditingController();
  bool editing = false;

  bool get _canAddAlias {
    final source = sourceController.text.trim();
    final display = displayController.text.trim();
    if (source.isEmpty || display.isEmpty || source == display) return false;
    return !aliases.containsKey(source);
  }

  bool get _hasChanges {
    if (aliases.length != appSettings.artistAliases.length) return true;
    for (final entry in aliases.entries) {
      if (appSettings.artistAliases[entry.key] != entry.value) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    sourceController.addListener(_onEditingTextChanged);
    displayController.addListener(_onEditingTextChanged);
  }

  void _onEditingTextChanged() {
    if (editing) setState(() {});
  }

  void _addAlias() {
    if (!_canAddAlias) return;
    setState(() {
      aliases[sourceController.text.trim()] = displayController.text.trim();
      editing = false;
      sourceController.clear();
      displayController.clear();
    });
  }

  @override
  void dispose() {
    sourceController.removeListener(_onEditingTextChanged);
    displayController.removeListener(_onEditingTextChanged);
    sourceController.dispose();
    displayController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48.0).clamp(300.0, 460.0).toDouble();
    final height = (size.height - 96.0).clamp(320.0, 480.0).toDouble();
    final canApplyChanges = canSaveListSettingChanges(
      isEditing: editing,
      isSaving: false,
      hasChanges: _hasChanges,
    );
    final entries = aliases.entries.toList();

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
                      '艺术家别名',
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: AppType.sectionTitle,
                        fontWeight: AppType.weightBold,
                      ),
                    ),
                    Text(
                      '${aliases.length} 条对照',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: AppType.caption,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _aliasList(scheme, entries)),
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
                          sourceController.clear();
                          displayController.clear();
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
                        : () => _saveAliases(context),
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

  Widget _aliasList(
    ColorScheme scheme,
    List<MapEntry<String, String>> entries,
  ) {
    if (entries.isEmpty && !editing) {
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
              Icon(Symbols.group, size: 40.0, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12.0),
              Text(
                '还没有别名',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: AppType.weightSemibold,
                ),
              ),
              const SizedBox(height: 4.0),
              Text(
                '例如把 夜遊 显示并归为 YOASOBI',
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
        ...entries.map(
          (entry) => ListTile(
            title: Text(entry.key),
            subtitle: Text('显示为 ${entry.value}'),
            trailing: IconButton(
              tooltip: '移除',
              onPressed: () => setState(() => aliases.remove(entry.key)),
              icon: const Icon(Symbols.remove_circle),
            ),
          ),
        ),
        if (editing) _buildEditingTile(),
      ],
    );
  }

  Widget _buildEditingTile() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Column(
        children: [
          Focus(
            onFocusChange: HotkeysHelper.onFocusChanges,
            child: TextField(
              controller: sourceController,
              autofocus: true,
              decoration: const InputDecoration(labelText: '原来的名字'),
              onSubmitted: (_) {
                if (_canAddAlias) _addAlias();
              },
            ),
          ),
          const SizedBox(height: 8),
          Focus(
            onFocusChange: HotkeysHelper.onFocusChanges,
            child: TextField(
              controller: displayController,
              decoration: InputDecoration(
                labelText: '显示为',
                suffixIcon: IconButton(
                  tooltip: '添加',
                  onPressed: _canAddAlias ? _addAlias : null,
                  icon: const Icon(Symbols.done),
                ),
              ),
              onSubmitted: (_) {
                if (_canAddAlias) _addAlias();
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAliases(BuildContext context) async {
    final oldAliases = Map<String, String>.from(appSettings.artistAliases);
    appSettings.artistAliases = normalizedArtistAliases(aliases);
    final saved = await appSettings.saveSettings();
    if (!saved) {
      appSettings.artistAliases = oldAliases;
      if (context.mounted) {
        showTextOnSnackBar('保存艺术家别名失败');
      }
      return;
    }
    await AudioLibrary.initFromIndex();
    if (context.mounted) {
      Navigator.pop(context);
    }
  }
}
