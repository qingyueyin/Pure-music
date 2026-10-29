import 'package:ffi/ffi.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/component/build_index_state_view.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/native/folder_picker_windows.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

bool _isNetworkFolderPath(String value) {
  final path = value.trim();
  if (path.isEmpty) return false;

  final lower = path.toLowerCase();
  if (lower.startsWith(r'\\?')) {
    return lower.startsWith(r'\\?\unc');
  }
  if (lower.startsWith(r'\\') || lower.startsWith('//')) return true;

  final drive = RegExp(r'^[a-z]:[\\/]').firstMatch(lower);
  if (drive == null) return false;
  final root = '${drive.group(0)!.substring(0, 1)}:\\'.toNativeUtf16();
  try {
    return GetDriveType(root) == DRIVE_REMOTE;
  } finally {
    malloc.free(root);
  }
}

const _networkFolderMessage = '网络共享文件夹不能加入本地曲库';

Future<void> showFolderManagerDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const FolderManagerDialog(),
  );
}

class FolderManagerDialog extends StatefulWidget {
  const FolderManagerDialog({super.key});

  @override
  State<FolderManagerDialog> createState() => _FolderManagerDialogState();
}

class _FolderManagerDialogState extends State<FolderManagerDialog> {
  List<AudioFolder> folders = [];
  List<_ManagedFolderGroup>? _managedFolderGroupsCache;
  int _managedFolderGroupsLibraryVersion = -1;

  final applicationSupportDirectory = getAppDataDir();

  bool editing = true;
  bool building = false;
  bool _isPickingFolder = false;

  Widget? _buildView;

  @override
  void initState() {
    super.initState();
    folders = AudioLibrary.aggregatedRootFolders();
  }

  List<String> _folderPathKeys(Iterable<AudioFolder> folders) {
    return folderPathKeys(folders.map((f) => f.path));
  }

  void _appendUniqueFolders(Iterable<String> paths) {
    final existing = {
      for (final folder in folders) pendingFolderKey(folder.path): folder,
    };
    final next = appendUniquePendingFolders(
      current: folders.map((folder) => folder.path),
      incoming: paths,
    );
    folders = next
        .map(
          (path) =>
              existing[pendingFolderKey(path)] ?? AudioFolder([], path, 0, 0),
        )
        .toList();
    _managedFolderGroupsCache = null;
  }

  bool get _hasFolderChanges {
    final current = _folderPathKeys(folders);
    final original = folderPathKeys(AppPreference.instance.userFolders);
    if (current.length != original.length) return true;
    for (var i = 0; i < current.length; i++) {
      if (current[i] != original[i]) return true;
    }
    return false;
  }

  bool _folderPathsOverlap(String first, String second) {
    final firstKey = pendingFolderKey(first);
    final secondKey = pendingFolderKey(second);
    if (firstKey.isEmpty || secondKey.isEmpty) return false;
    return firstKey == secondKey ||
        firstKey.startsWith('$secondKey/') ||
        secondKey.startsWith('$firstKey/');
  }

  List<_ManagedFolderGroup> _managedFolderGroups() {
    final libraryVersion = AudioLibrary.libraryVersion.value;
    final cached = _managedFolderGroupsCache;
    if (cached != null &&
        _managedFolderGroupsLibraryVersion == libraryVersion) {
      return cached;
    }
    final drafts = _managedFolderDrafts();
    final scannedFolders = _scannedFoldersForDrafts(drafts);
    final result = List<_ManagedFolderGroup>.generate(drafts.length, (index) {
      final draft = drafts[index];
      return _ManagedFolderGroup(
        path: draft.path,
        sourceFolders: draft.sourceFolders,
        tree: _buildFolderTree(
          draft.path,
          draft.sourceFolders,
          scannedFolders[index],
        ),
      );
    }, growable: false);
    _managedFolderGroupsLibraryVersion = libraryVersion;
    return _managedFolderGroupsCache = result;
  }

  List<({String path, List<AudioFolder> sourceFolders})>
  _managedFolderDrafts() {
    final foldersByParent = <String, List<AudioFolder>>{};
    final parentPaths = <String, String>{};
    for (final folder in folders) {
      final parentPath = p.windows.dirname(folder.path);
      final parentKey = pendingFolderKey(parentPath);
      if (parentKey.isEmpty || parentKey == pendingFolderKey(folder.path)) {
        continue;
      }
      parentPaths.putIfAbsent(parentKey, () => parentPath);
      foldersByParent.putIfAbsent(parentKey, () => []).add(folder);
    }
    final groupedParents = <String>{};
    final drafts = <({String path, List<AudioFolder> sourceFolders})>[];
    for (final folder in folders) {
      final parentPath = p.windows.dirname(folder.path);
      final parentKey = pendingFolderKey(parentPath);
      final siblings = foldersByParent[parentKey];
      if (siblings != null && siblings.length > 1) {
        if (!groupedParents.add(parentKey)) continue;
        drafts.add((path: parentPaths[parentKey]!, sourceFolders: siblings));
        continue;
      }
      drafts.add((path: folder.path, sourceFolders: [folder]));
    }
    return drafts;
  }

  void _addScannedFolderToDrafts(
    AudioFolder folder,
    List<int>? indexes,
    List<List<AudioFolder>> scannedFolders,
  ) {
    if (indexes == null) return;
    for (final index in indexes) {
      scannedFolders[index].add(folder);
    }
  }

  List<List<AudioFolder>> _scannedFoldersForDrafts(
    List<({String path, List<AudioFolder> sourceFolders})> drafts,
  ) {
    final draftIndexesByRoot = <String, List<int>>{};
    for (var index = 0; index < drafts.length; index++) {
      final rootKey = pendingFolderKey(drafts[index].path);
      if (rootKey.isEmpty) continue;
      draftIndexesByRoot.putIfAbsent(rootKey, () => <int>[]).add(index);
    }
    final scannedFolders = List<List<AudioFolder>>.generate(
      drafts.length,
      (_) => <AudioFolder>[],
    );
    for (final folder in AudioLibrary.instance.folders) {
      var ancestor = pendingFolderKey(folder.path);
      while (ancestor.isNotEmpty) {
        _addScannedFolderToDrafts(
          folder,
          draftIndexesByRoot[ancestor],
          scannedFolders,
        );
        final separator = ancestor.lastIndexOf('/');
        if (separator <= 0) break;
        ancestor = ancestor.substring(0, separator);
      }
    }
    return scannedFolders;
  }

  _ManagedFolderTreeNode _buildFolderTree(
    String rootPath,
    Iterable<AudioFolder> sourceFolders,
    Iterable<AudioFolder> scannedFolders,
  ) {
    final rootKey = pendingFolderKey(rootPath);
    final root = _MutableManagedFolderTreeNode(rootPath);
    if (rootKey.isEmpty) return root.freeze();
    for (final folder in scannedFolders) {
      _nodeForPath(root, rootPath, rootKey, folder.path)?.directAudioCount +=
          folder.audios.length;
    }
    for (final folder in sourceFolders) {
      final node = _nodeForPath(root, rootPath, rootKey, folder.path);
      if (node == null) continue;
      node.sourceFolder = folder;
      node.pendingScan = !containsEquivalentFolderPath(
        paths: AppPreference.instance.userFolders,
        target: folder.path,
      );
    }
    return root.freeze();
  }

  _MutableManagedFolderTreeNode? _nodeForPath(
    _MutableManagedFolderTreeNode root,
    String rootPath,
    String rootKey,
    String folderPath,
  ) {
    final folderKey = pendingFolderKey(folderPath);
    if (folderKey == rootKey) return root;
    if (!folderKey.startsWith('$rootKey/')) return null;
    final relativePath = p.windows.relative(folderPath, from: rootPath);
    final segments = p.windows
        .split(relativePath)
        .where((segment) => segment.isNotEmpty && segment != '.')
        .toList();
    if (segments.isEmpty || segments.first == '..') return null;
    var current = root;
    var currentPath = rootPath;
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      currentPath = p.windows.join(currentPath, segment);
      current = current.children.putIfAbsent(
        segment.toLowerCase(),
        () => _MutableManagedFolderTreeNode(
          i == segments.length - 1 ? folderPath : currentPath,
        ),
      );
    }
    return current;
  }

  Future<bool> _confirmRemoveFolder(String folderPath) async {
    final scheme = Theme.of(context).colorScheme;
    return showDangerConfirmDialog(
      context: context,
      title: '从曲库移除文件夹？',
      message: '不会删除本地音乐文件，只会从 Pure Music 的曲库扫描范围中移除。',
      confirmLabel: '移除',
      details: Text(
        folderPath,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: AppType.caption,
        ),
      ),
    );
  }

  Future<void> _removeManagedFolders(
    String displayPath,
    Iterable<AudioFolder> sourceFolders,
  ) async {
    final confirmed = await _confirmRemoveFolder(displayPath);
    if (!confirmed || !mounted) return;
    final removedFolders = sourceFolders.toSet();
    setState(() {
      folders.removeWhere(removedFolders.contains);
      _managedFolderGroupsCache = null;
    });
  }

  void _startBuild({
    required List<String> userFolders,
    required List<String> excludedFolderPaths,
    required Map<String, String> folderAliases,
  }) {
    building = true;
    _buildView = FutureBuilder(
      future: applicationSupportDirectory,
      builder: (context, snapshot) {
        if (snapshot.data == null) {
          return const Center(child: Text('Fail to get app data dir.'));
        }
        return Center(
          child: BuildIndexStateView(
            key: const ValueKey('index_builder'),
            indexPath: snapshot.data!,
            folders: folders.map((f) => f.path).toList(),
            whenIndexBuilt: () => _commitBuiltIndex(
              context,
              userFolders: userFolders,
              excludedFolderPaths: excludedFolderPaths,
              folderAliases: folderAliases,
            ),
          ),
        );
      },
    );
    setState(() {
      editing = false;
    });
  }

  Future<void> _commitBuiltIndex(
    BuildContext context, {
    required List<String> userFolders,
    required List<String> excludedFolderPaths,
    required Map<String, String> folderAliases,
  }) async {
    final preference = AppPreference.instance;
    final oldUserFolders = List<String>.from(preference.userFolders);
    final oldExcludedFolderPaths = List<String>.from(
      preference.excludedFolderPaths,
    );
    final oldFolderAliases = Map<String, String>.from(preference.folderAliases);
    preference.userFolders = userFolders;
    preference.excludedFolderPaths = excludedFolderPaths;
    preference.folderAliases = folderAliases;
    try {
      await AudioLibrary.initFromIndex();
    } catch (_) {
      preference.userFolders = oldUserFolders;
      preference.excludedFolderPaths = oldExcludedFolderPaths;
      preference.folderAliases = oldFolderAliases;
      rethrow;
    }
    final saved = await preference.save();
    if (!saved) {
      preference.userFolders = oldUserFolders;
      preference.excludedFolderPaths = oldExcludedFolderPaths;
      preference.folderAliases = oldFolderAliases;
      throw StateError('保存文件夹设置失败');
    }
    pruneLyricSourcesWhereMissing(
      (path) => AudioLibrary.instance.audioByPath(path) != null,
    );
    if (context.mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _pickFolders() async {
    setState(() => _isPickingFolder = true);
    await Future<void>.delayed(Duration.zero);
    try {
      final paths = pickMultipleDirectories(title: '选择文件夹');
      if (paths.isEmpty || !mounted) return;
      if (paths.any(_isNetworkFolderPath)) {
        showTextOnSnackBar(_networkFolderMessage, variant: ToastVariant.error);
      }
      final localPaths = paths
          .where((path) => !_isNetworkFolderPath(path))
          .toList();
      if (localPaths.isEmpty) return;
      setState(() {
        _appendUniqueFolders(localPaths);
      });
    } finally {
      if (mounted) {
        setState(() => _isPickingFolder = false);
      }
    }
  }

  void _applyFolderChanges() {
    final kept = folders.map((f) => f.path).toList();
    if (kept.any(_isNetworkFolderPath)) {
      showTextOnSnackBar(_networkFolderMessage, variant: ToastVariant.error);
      return;
    }
    final original = List<String>.from(AppPreference.instance.userFolders);
    final nextUserFolders = List<String>.from(
      AppPreference.instance.userFolders,
    );
    final nextExcludedFolderPaths = List<String>.from(
      AppPreference.instance.excludedFolderPaths,
    );
    final nextFolderAliases = Map<String, String>.from(
      AppPreference.instance.folderAliases,
    );
    final added = kept
        .where((f) => !containsEquivalentFolderPath(paths: original, target: f))
        .toList();
    final removed = original
        .where((f) => !containsEquivalentFolderPath(paths: kept, target: f))
        .toList();
    final userFolderKeys = nextUserFolders.map(pendingFolderKey).toSet();
    nextUserFolders.addAll(
      added.where((f) => userFolderKeys.add(pendingFolderKey(f))),
    );
    nextUserFolders.removeWhere(
      (f) => !containsEquivalentFolderPath(paths: kept, target: f),
    );
    nextExcludedFolderPaths.removeWhere(
      (excluded) => kept.any((root) => _folderPathsOverlap(excluded, root)),
    );
    final excludedFolderKeys = nextExcludedFolderPaths
        .map(pendingFolderKey)
        .toSet();
    nextExcludedFolderPaths.addAll(
      removed
          .where(
            (removedPath) =>
                !kept.any((root) => _folderPathsOverlap(removedPath, root)),
          )
          .where((f) => excludedFolderKeys.add(pendingFolderKey(f))),
    );
    final removedKeys = removed.map(pendingFolderKey).toSet();
    nextFolderAliases.removeWhere((key, _) => removedKeys.contains(key));
    _startBuild(
      userFolders: nextUserFolders,
      excludedFolderPaths: nextExcludedFolderPaths,
      folderAliases: nextFolderAliases,
    );
  }

  Widget _header(ColorScheme scheme, int folderCount) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '管理文件夹',
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: AppType.sectionTitle,
              fontWeight: AppType.weightBold,
            ),
          ),
          Text(
            '$folderCount 个文件夹',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: AppType.caption,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(List<_ManagedFolderGroup> managedFolders) {
    return AnimatedSwitcher(
      duration: MotionDuration.xFast,
      switchInCurve: MotionCurve.standard,
      switchOutCurve: MotionCurve.standard,
      child: editing
          ? _editingBody(managedFolders)
          : (_buildView ?? const SizedBox(key: ValueKey('empty'))),
    );
  }

  Widget _editingBody(List<_ManagedFolderGroup> managedFolders) {
    if (folders.isEmpty) return const _EmptyManagedFolderState();
    return ListView.builder(
      key: const ValueKey('folder_list'),
      itemCount: managedFolders.length,
      itemBuilder: (context, i) => _managedFolderTile(managedFolders[i]),
    );
  }

  Widget _managedFolderTile(_ManagedFolderGroup folder) {
    final canEdit = !(building || _isPickingFolder);
    return _ManagedFolderTile(
      key: ValueKey(
        folder.sourceFolders
            .map((source) => pendingFolderKey(source.path))
            .join('|'),
      ),
      tree: folder.tree,
      onRemove: canEdit
          ? () => _removeManagedFolders(folder.path, folder.sourceFolders)
          : null,
      onRemoveFolder: canEdit
          ? (source) => _removeManagedFolders(source.path, [source])
          : null,
    );
  }

  Widget _actionBar(bool canApplyChanges) {
    return OverflowBar(
      alignment: MainAxisAlignment.end,
      spacing: 8.0,
      overflowSpacing: 8.0,
      children: [
        TextButton.icon(
          onPressed: building || _isPickingFolder ? null : _pickFolders,
          icon: _isPickingFolder
              ? const SizedBox(
                  width: 18.0,
                  height: 18.0,
                  child: CircularProgressIndicator(strokeWidth: 2.0),
                )
              : const Icon(Symbols.create_new_folder),
          label: Text(_isPickingFolder ? '选择中' : '添加'),
        ),
        TextButton(
          onPressed: building || _isPickingFolder
              ? null
              : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: !canApplyChanges ? null : _applyFolderChanges,
          child: const Text('确定'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48.0).clamp(320.0, 520.0).toDouble();
    final height = (size.height - 96.0).clamp(320.0, 520.0).toDouble();
    final canApplyChanges = !building && !_isPickingFolder && _hasFolderChanges;
    final managedFolders = _managedFolderGroups();
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 24.0,
        vertical: 24.0,
      ),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      child: SizedBox(
        height: height,
        width: width,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(scheme, managedFolders.length),
              Expanded(child: _body(managedFolders)),
              const SizedBox(height: 16.0),
              _actionBar(canApplyChanges),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManagedFolderGroup {
  const _ManagedFolderGroup({
    required this.path,
    required this.sourceFolders,
    required this.tree,
  });

  final String path;
  final List<AudioFolder> sourceFolders;
  final _ManagedFolderTreeNode tree;
}

class _ManagedFolderTreeNode {
  const _ManagedFolderTreeNode({
    required this.path,
    required this.directAudioCount,
    required this.children,
    required this.sourceFolder,
    required this.pendingScan,
  });

  final String path;
  final int directAudioCount;
  final List<_ManagedFolderTreeNode> children;
  final AudioFolder? sourceFolder;
  final bool pendingScan;

  String get name =>
      AppPreference.instance.folderAliases[pendingFolderKey(path)] ??
      p.windows.basename(path);

  int get audioCount =>
      directAudioCount +
      children.fold(0, (total, child) => total + child.audioCount);

  int get displayAudioCount => pendingScan ? 0 : audioCount;

  int get pendingFolderCount =>
      (pendingScan ? 1 : 0) +
      children.fold(0, (total, child) => total + child.pendingFolderCount);
}

class _MutableManagedFolderTreeNode {
  _MutableManagedFolderTreeNode(this.path);

  final String path;
  int directAudioCount = 0;
  AudioFolder? sourceFolder;
  bool pendingScan = false;
  final Map<String, _MutableManagedFolderTreeNode> children = {};

  _ManagedFolderTreeNode freeze() {
    final frozenChildren =
        children.values.map((child) => child.freeze()).toList()..sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
    return _ManagedFolderTreeNode(
      path: path,
      directAudioCount: directAudioCount,
      children: frozenChildren,
      sourceFolder: sourceFolder,
      pendingScan: pendingScan,
    );
  }
}

class _ManagedFolderTile extends StatelessWidget {
  const _ManagedFolderTile({
    super.key,
    required this.tree,
    required this.onRemove,
    required this.onRemoveFolder,
  });

  final _ManagedFolderTreeNode tree;
  final VoidCallback? onRemove;
  final ValueChanged<AudioFolder>? onRemoveFolder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final removeButton = TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: scheme.error,
        visualDensity: VisualDensity.compact,
      ),
      onPressed: onRemove,
      icon: const Icon(Symbols.remove_circle, size: 18),
      label: const Text('移除'),
    );
    final title = Row(
      children: [
        Icon(Symbols.folder, size: 20, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(tree.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );

    if (tree.children.isEmpty) {
      return Material(
        type: MaterialType.transparency,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
        clipBehavior: Clip.hardEdge,
        child: ListTile(
          title: title,
          subtitle: Text('${tree.displayAudioCount} 首乐曲'),
          trailing: removeButton,
        ),
      );
    }

    return Material(
      type: MaterialType.transparency,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
      clipBehavior: Clip.hardEdge,
      child: ExpansionTile(
        initiallyExpanded: tree.pendingFolderCount > 0,
        controlAffinity: ListTileControlAffinity.leading,
        childrenPadding: const EdgeInsets.only(left: 20),
        title: title,
        subtitle: Text(
          '${tree.children.length} 个子文件夹 · ${tree.displayAudioCount} 首乐曲',
        ),
        trailing: removeButton,
        children: [
          for (final child in tree.children)
            _FolderTreeTile(node: child, onRemoveFolder: onRemoveFolder),
        ],
      ),
    );
  }
}

class _FolderTreeTile extends StatelessWidget {
  const _FolderTreeTile({required this.node, required this.onRemoveFolder});

  final _ManagedFolderTreeNode node;
  final ValueChanged<AudioFolder>? onRemoveFolder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sourceFolder = node.sourceFolder;
    final removeButton = sourceFolder == null
        ? null
        : IconButton(
            tooltip: '移除',
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(foregroundColor: scheme.error),
            onPressed: onRemoveFolder == null
                ? null
                : () => onRemoveFolder!(sourceFolder),
            icon: const Icon(Symbols.remove_circle, size: 18),
          );
    final title = Row(
      children: [
        Icon(Symbols.folder, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );

    if (node.children.isEmpty) {
      return Material(
        type: MaterialType.transparency,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
        clipBehavior: Clip.hardEdge,
        child: ListTile(
          dense: true,
          title: title,
          subtitle: Text('${node.displayAudioCount} 首乐曲'),
          trailing: removeButton,
        ),
      );
    }

    return Material(
      type: MaterialType.transparency,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
      clipBehavior: Clip.hardEdge,
      child: ExpansionTile(
        dense: true,
        initiallyExpanded: node.pendingFolderCount > 0,
        controlAffinity: ListTileControlAffinity.leading,
        childrenPadding: const EdgeInsets.only(left: 20),
        title: title,
        subtitle: Text(
          '${node.children.length} 个子文件夹 · ${node.displayAudioCount} 首乐曲',
        ),
        trailing: removeButton,
        children: [
          for (final child in node.children)
            _FolderTreeTile(node: child, onRemoveFolder: onRemoveFolder),
        ],
      ),
    );
  }
}

class _EmptyManagedFolderState extends StatelessWidget {
  const _EmptyManagedFolderState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 28.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.folder_open,
              size: 32.0,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12.0),
            Text(
              '暂时没有曲库文件夹',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: AppType.weightSemibold,
              ),
            ),
            const SizedBox(height: 4.0),
            Text(
              '添加文件夹后再重新构建曲库',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
