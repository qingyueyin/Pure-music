import 'package:pure_music/component/index_progress_view.dart';
import 'dart:async';

import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/page_sort.dart';
import 'package:pure_music/core/menu_styles.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/library_page_order_cache.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/page/folder_manager_dialog.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/services/native/library_index_service.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:path/path.dart' as p;

List<SortMethodDesc<AudioFolder>> _foldersSortMethods() {
  return [
    SortMethodDesc<AudioFolder>(
      icon: Symbols.title,
      name: '名称',
      alphabetValueOf: (folder) => folder.displayName,
      method: (list, order) {
        sortNaturallyBy(
          list,
          (folder) => folder.displayName,
          descending: order == SortOrder.decending,
        );
      },
      backgroundMethod: (list, order, control) => sortPageNaturallyInBackground(
        list,
        (folder) => folder.displayName,
        descending: order == SortOrder.decending,
        control: control,
      ),
    ),
    SortMethodDesc<AudioFolder>(
      icon: Symbols.edit,
      name: '修改日期',
      method: (list, order) {
        sortByIntegerThenNatural(
          list,
          valueOf: (folder) => folder.modified,
          tieBreakOf: (folder) => folder.displayName,
          descending: order == SortOrder.decending,
        );
      },
      backgroundMethod: (list, order, control) => sortPageByIntegerInBackground(
        list,
        (folder) => folder.modified,
        descending: order == SortOrder.decending,
        tieBreakOf: (folder) => folder.displayName,
        control: control,
      ),
    ),
    SortMethodDesc<AudioFolder>(
      icon: Symbols.music_note,
      name: '歌曲数量',
      method: (list, order) {
        sortByIntegerThenNatural(
          list,
          valueOf: (folder) => folder.audios.length,
          tieBreakOf: (folder) => folder.displayName,
          descending: order == SortOrder.decending,
        );
      },
      backgroundMethod: (list, order, control) => sortPageByIntegerInBackground(
        list,
        (folder) => folder.audios.length,
        descending: order == SortOrder.decending,
        tieBreakOf: (folder) => folder.displayName,
        control: control,
      ),
    ),
  ];
}

class FoldersPage extends StatefulWidget {
  const FoldersPage({super.key});

  @override
  State<FoldersPage> createState() => _FoldersPageState();
}

class _FoldersPageState extends State<FoldersPage> {
  bool _updating = false;
  int _contentVersion = -1;
  List<AudioFolder> _contentList = [];

  List<AudioFolder> _resolveContentList() {
    final version = AudioLibrary.libraryVersion.value;
    if (_contentVersion == version) return _contentList;
    _contentVersion = version;
    _contentList = [
      ...AudioLibrary.aggregatedRootFolders(),
      ...AudioLibrary.instance.remoteVirtualFolders,
    ];
    return _contentList;
  }

  void _invalidateContentList() {
    _contentVersion = -1;
  }

  Future<void> _refreshIndex() async {
    setState(() => _updating = true);
    try {
      final dir = await getAppDataDir();
      final indexPath = p.join(dir.path, 'index.json');
      final sourceBefore = await LibraryPageOrderCache.sourceSignature(
        indexPath,
      );
      if (!mounted) return;
      // 扫描进度走统一对话框：阶段文案 + 不可读计数 + 失败重试。
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const _RefreshIndexDialog(),
      );
      final sourceAfter = await LibraryPageOrderCache.sourceSignature(
        indexPath,
      );
      if (sourceBefore != sourceAfter ||
          AudioLibrary.instance.folders.isEmpty) {
        await AudioLibrary.initFromIndex();
        pruneLyricSourcesWhereMissing(
          (path) => AudioLibrary.instance.audioByPath(path) != null,
        );
      } else {
        log.library.debug(
          'legacy',
          '[perf] library refresh reload=skipped indexUnchanged=true',
        );
      }
      if (mounted) {
        showTextOnSnackBar('已刷新');
      }
    } catch (e) {
      log.library.error('legacy', 'refresh index failed: $e');
    }
    if (mounted) setState(() => _updating = false);
  }

  @override
  Widget build(BuildContext context) {
    final contentList = _resolveContentList();
    return UniPage<AudioFolder>(
      pref: AppPreference.instance.foldersPagePref,
      title: '文件夹',
      subtitle: '${contentList.length} 个文件夹',
      contentList: contentList,
      contentRevision: AudioLibrary.libraryVersion.value,
      primaryAction: _foldersPrimaryAction(),
      contentBuilder: (context, item, i, multiSelectController, view) =>
          AudioFolderTile(
            audioFolder: item,
            view: view,
            onAliasChanged: () => setState(_invalidateContentList),
          ),
      enableShufflePlay: false,
      enableSortMethod: true,
      enableSortOrder: true,
      enableContentViewSwitch: true,
      sortMethods: _foldersSortMethods(),
    );
  }

  Widget _foldersPrimaryAction() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_updating)
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          OutlinedButton.icon(
            onPressed: _refreshIndex,
            icon: const Icon(Symbols.refresh, size: 18),
            label: const Text('刷新'),
            style: AppButton.pageAction,
          ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: () async {
            await showFolderManagerDialog(context);
            setState(_invalidateContentList);
          },
          icon: const Icon(Symbols.folder),
          label: const Text('文件夹管理'),
          style: AppButton.pageAction,
        ),
      ],
    );
  }
}

class AudioFolderTile extends StatelessWidget {
  final AudioFolder audioFolder;
  final ContentView view;
  final VoidCallback? onAliasChanged;
  const AudioFolderTile({
    super.key,
    required this.audioFolder,
    this.view = ContentView.list,
    this.onAliasChanged,
  });

  Future<void> _editAlias(BuildContext context) async {
    final key = pendingFolderKey(audioFolder.path);
    final current = AppPreference.instance.folderAliases[key];
    final existing = AppPreference.instance.folderAliases.entries
        .where((e) => e.key != key)
        .map((e) => e.value)
        .toSet();
    final result = await showDialog<String>(
      context: context,
      builder: (context) =>
          _FolderAliasDialog(currentAlias: current, existingAliases: existing),
    );
    if (result == null) return;
    final oldAliases = Map<String, String>.from(
      AppPreference.instance.folderAliases,
    );
    if (result.trim().isEmpty) {
      AppPreference.instance.folderAliases.remove(key);
    } else {
      AppPreference.instance.folderAliases[key] = result.trim();
    }
    final saved = await AppPreference.instance.save();
    if (!saved) {
      AppPreference.restoreFolderAliasesOnSaveFailure(
        AppPreference.instance.folderAliases,
        oldAliases,
        saved,
      );
      if (context.mounted) {
        showTextOnSnackBar('保存别名失败', variant: ToastVariant.error);
      }
      return;
    }
    onAliasChanged?.call();
  }

  Future<void> _clearAlias(BuildContext context) async {
    final key = pendingFolderKey(audioFolder.path);
    final oldAliases = Map<String, String>.from(
      AppPreference.instance.folderAliases,
    );
    AppPreference.instance.folderAliases.remove(key);
    final saved = await AppPreference.instance.save();
    if (!saved) {
      AppPreference.restoreFolderAliasesOnSaveFailure(
        AppPreference.instance.folderAliases,
        oldAliases,
        saved,
      );
      if (context.mounted) {
        showTextOnSnackBar('保存别名失败', variant: ToastVariant.error);
      }
      return;
    }
    onAliasChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuTheme(
      data: MenuThemeData(style: appMenuStyle),
      child: MenuAnchor(
        consumeOutsideTap: true,
        style: appMenuStyle,
        menuChildren: _menuChildren(context),
        builder: (context, controller, _) =>
            _folderTile(context, controller, scheme),
      ),
    );
  }

  Widget _folderTile(
    BuildContext context,
    MenuController controller,
    ColorScheme scheme,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: DirectionalListItemEntrance(
        identity: audioFolder,
        child: InteractiveSurfaceMotion(
          enabled:
              view == ContentView.table &&
              AppSettings.instance.enableInteractiveSurfaceMotion,
          child: Material(
            type: MaterialType.transparency,
            shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
            clipBehavior: Clip.hardEdge,
            child: InkWell(
              borderRadius: AppRadius.smCircular,
              onTap: () => context.push(
                app_paths.FOLDER_DETAIL_PAGE,
                extra: audioFolder,
              ),
              onSecondaryTapDown: (details) {
                controller.open(position: details.localPosition);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 10.0,
                ),
                child: _row(scheme),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _menuChildren(BuildContext context) {
    return [
      MenuItemButton(
        style: appMenuItemStyle,
        onPressed: () => _editAlias(context),
        leadingIcon: const Icon(Symbols.label),
        child: Text(audioFolder.alias?.isNotEmpty == true ? '修改别名' : '设置别名'),
      ),
      if (audioFolder.alias?.isNotEmpty == true)
        MenuItemButton(
          style: appMenuItemStyle,
          onPressed: () => _clearAlias(context),
          leadingIcon: const Icon(Symbols.label_off),
          child: const Text('移除别名'),
        ),
    ];
  }

  Widget _row(ColorScheme scheme) {
    return Row(
      children: [
        Icon(Symbols.folder, color: scheme.onSurfaceVariant),
        const SizedBox(width: 16.0),
        Expanded(child: _texts(scheme)),
        const SizedBox(width: 12),
        Text(
          '${audioFolder.audios.length} 首',
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: AppType.body,
          ),
        ),
      ],
    );
  }

  Widget _texts(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          audioFolder.displayName,
          softWrap: false,
          maxLines: 1,
          style: TextStyle(color: scheme.onSurface),
        ),
        const SizedBox(height: 2),
        Text(
          audioFolder.subtitle ?? p.dirname(audioFolder.path),
          softWrap: false,
          maxLines: 1,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: AppType.body,
          ),
        ),
      ],
    );
  }
}

class _FolderAliasDialog extends StatefulWidget {
  final String? currentAlias;
  final Set<String> existingAliases;
  const _FolderAliasDialog({this.currentAlias, required this.existingAliases});

  @override
  State<_FolderAliasDialog> createState() => _FolderAliasDialogState();
}

class _FolderAliasDialogState extends State<_FolderAliasDialog> {
  late final _editingController = TextEditingController(
    text: widget.currentAlias ?? '',
  );
  String? _errorText;

  String get _trimmedAlias => _editingController.text.trim();

  bool get _canSubmit {
    final alias = _trimmedAlias;
    // 空输入视为清除别名：当前已有别名时才允许
    if (alias.isEmpty) return widget.currentAlias?.isNotEmpty ?? false;
    return alias != (widget.currentAlias ?? '') &&
        !hasEquivalentPlaylistName(
          existingNames: widget.existingAliases,
          targetName: alias,
        );
  }

  void _onAliasChanged(String value) {
    final alias = value.trim();
    setState(() {
      _errorText =
          alias.isNotEmpty &&
              hasEquivalentPlaylistName(
                existingNames: widget.existingAliases,
                targetName: alias,
              )
          ? '该别名已存在'
          : null;
    });
  }

  void _submit() {
    final alias = _trimmedAlias;
    if (alias.isEmpty) {
      Navigator.pop(context, '');
      return;
    }
    if (hasEquivalentPlaylistName(
      existingNames: widget.existingAliases,
      targetName: alias,
    )) {
      setState(() => _errorText = '该别名已存在');
      return;
    }
    if (alias == widget.currentAlias) return;
    Navigator.pop(context, alias);
  }

  @override
  void dispose() {
    _editingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = (MediaQuery.sizeOf(context).width - 48.0)
        .clamp(280.0, 360.0)
        .toDouble();
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 24.0,
        vertical: 24.0,
      ),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _title(scheme),
              _field(),
              const SizedBox(height: 16.0),
              _actions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _title(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Text(
        '设置文件夹别名',
        style: TextStyle(
          color: scheme.onSurface,
          fontSize: AppType.sectionTitle,
          fontWeight: AppType.weightBold,
        ),
      ),
    );
  }

  Widget _field() {
    return TextField(
      autofocus: true,
      controller: _editingController,
      onChanged: _onAliasChanged,
      onSubmitted: (value) => _submit(),
      decoration: InputDecoration(
        labelText: '别名（留空则清除）',
        border: const OutlineInputBorder(),
        errorText: _errorText,
      ),
    );
  }

  Widget _actions(BuildContext context) {
    return OverflowBar(
      alignment: MainAxisAlignment.end,
      spacing: 8.0,
      overflowSpacing: 8.0,
      children: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: const Text('确认'),
        ),
      ],
    );
  }
}

/// 手动刷新曲库时的进度对话框：阶段文案 + 不可读计数 + 失败重试。
class _RefreshIndexDialog extends StatefulWidget {
  const _RefreshIndexDialog();

  @override
  State<_RefreshIndexDialog> createState() => _RefreshIndexDialogState();
}

class _RefreshIndexDialogState extends State<_RefreshIndexDialog> {
  StreamSubscription<LibraryIndexState>? _subscription;
  LibraryIndexState? _latest;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    await _subscription?.cancel();
    if (!mounted) return;
    setState(() => _errorMessage = null);
    final dir = await getAppDataDir();
    _subscription = LibraryIndexService.instance
        .updateIndex(indexPath: dir.path, forceMetadataCheck: true)
        .listen(
          (action) {
            if (mounted) setState(() => _latest = action);
          },
          onError: (Object error) {
            if (mounted) {
              setState(() => _errorMessage = '曲库刷新失败，请查看日志');
            }
          },
          onDone: () {
            if (mounted) Navigator.of(context).pop();
          },
          cancelOnError: true,
        );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
      content: SizedBox(
        width: 360,
        child: IndexProgressView(
          state: _latest,
          errorMessage: _errorMessage,
          onRetry: _errorMessage == null ? null : () => unawaited(_start()),
        ),
      ),
    );
  }
}
