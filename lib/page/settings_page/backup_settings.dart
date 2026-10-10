import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_lifecycle.dart';
import 'package:pure_music/services/backup_service.dart';

class BackupSettingsPanel extends StatefulWidget {
  const BackupSettingsPanel({super.key});

  @override
  State<BackupSettingsPanel> createState() => _BackupSettingsPanelState();
}

class _BackupSettingsPanelState extends State<BackupSettingsPanel> {
  final Set<BackupCategory> _selected = {
    BackupCategory.settings,
    BackupCategory.playlists,
    BackupCategory.playCounts,
    BackupCategory.playHistory,
  };
  bool _busy = false;

  String _defaultFileName() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'PureMusic_Backup_'
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}.zip';
  }

  Future<void> _export() async {
    if (_busy || _selected.isEmpty) return;
    setState(() => _busy = true);
    try {
      final target = await FilePicker.platform.saveFile(
        dialogTitle: '导出备份',
        fileName: _defaultFileName(),
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (target == null) return;
      await exportBackup(targetPath: target, categories: _selected);
      if (!mounted) return;
      showTextOnSnackBar('已导出备份', variant: ToastVariant.success);
    } catch (error, trace) {
      log.settings.error('legacy', '导出备份失败', error: error, stackTrace: trace);
      if (!mounted) return;
      showTextOnSnackBar('导出失败：$error', variant: ToastVariant.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final source = result.files.single.path;
      if (source == null || source.trim().isEmpty || !mounted) return;

      final mode = await _chooseImportMode();
      if (mode == null || !mounted) return;

      final imported = await importBackup(sourcePath: source, mode: mode);
      if (!mounted) return;
      if (imported.isEmpty) {
        showTextOnSnackBar('备份中没有可导入的数据', variant: ToastVariant.error);
        return;
      }
      final labels = imported.map((c) => c.label).join('、');
      await _promptRestart('已导入：$labels');
    } catch (error, trace) {
      log.settings.error('legacy', '导入备份失败', error: error, stackTrace: trace);
      if (!mounted) return;
      showTextOnSnackBar('导入失败：$error', variant: ToastVariant.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<BackupImportMode?> _chooseImportMode() async {
    return showDialog<BackupImportMode>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入方式'),
        content: const Text('覆盖会整份替换本机数据；合并只补缺失项，保留本机已有内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, BackupImportMode.merge),
            child: const Text('合并'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, BackupImportMode.overwrite),
            child: const Text('覆盖'),
          ),
        ],
      ),
    );
  }

  Future<void> _promptRestart(String message) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('导入完成'),
        content: Text('$message。应用将立即退出，重新启动后导入的数据才会生效。'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('立即退出'),
          ),
        ],
      ),
    );
    await WindowLifecycleService.instance.exitApp(skipSave: true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ..._categoryTiles(),
        const SizedBox(height: 8.0),
        _actionButtons(),
        const SizedBox(height: 12.0),
        ..._hints(scheme),
      ],
    );
  }

  void _toggleCategory(BackupCategory category, bool? checked) {
    setState(() {
      if (checked == true) {
        _selected.add(category);
      } else {
        _selected.remove(category);
      }
    });
  }

  List<Widget> _categoryTiles() {
    return [
      for (final category in BackupCategory.values) ...[
        SettingsTile(
          description: category.label,
          subtitle: category.description,
          action: Checkbox(
            value: _selected.contains(category),
            onChanged: _busy
                ? null
                : (checked) => _toggleCategory(category, checked),
          ),
        ),
        const SizedBox(height: 16.0),
      ],
    ];
  }

  Widget _actionButtons() {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: _busy || _selected.isEmpty ? null : _export,
            icon: const Icon(Symbols.save, size: 18),
            label: const Text('导出备份'),
          ),
        ),
        const SizedBox(width: 12.0),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _import,
            icon: const Icon(Symbols.backup, size: 18),
            label: const Text('导入备份'),
          ),
        ),
      ],
    );
  }

  List<Widget> _hints(ColorScheme scheme) {
    return [
      if (_selected.contains(BackupCategory.lastfm)) ...[
        Text(
          '账号备份包含登录凭证，请只保存到可信位置。',
          style: TextStyle(color: scheme.error, fontSize: AppType.caption),
        ),
        const SizedBox(height: 8.0),
      ],
      Text(
        '备份打包为 zip，包含所选类别的数据文件；自定义字体会一并打包，缓存与日志不包含在内。',
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: AppType.caption,
        ),
      ),
    ];
  }
}
