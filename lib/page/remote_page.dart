import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/menu_styles.dart';
import 'package:pure_music/core/page_sort.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/audio_sort.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/page/remote_source_dialog.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:pure_music/remote/remote_library.dart';
import 'package:pure_music/remote/remote_source.dart';

IconData _sourceIcon(RemoteSourceKind kind) {
  return switch (kind) {
    RemoteSourceKind.navidrome => Symbols.dns,
    RemoteSourceKind.webdav => Symbols.cloud,
    RemoteSourceKind.smb => Symbols.folder_shared,
    RemoteSourceKind.jellyfin => Symbols.smart_display,
  };
}

SortMethodDesc<Audio> _naturalAudioSort({
  required IconData icon,
  required String name,
  required String Function(Audio) keyOf,
  String Function(Audio)? alphabetValueOf,
}) {
  return SortMethodDesc(
    icon: icon,
    name: name,
    alphabetValueOf: alphabetValueOf ?? keyOf,
    method: (list, order) {
      sortNaturallyBy(list, keyOf, descending: order == SortOrder.decending);
    },
    backgroundMethod: (list, order, control) => sortPageNaturallyInBackground(
      list,
      keyOf,
      descending: order == SortOrder.decending,
      control: control,
    ),
  );
}

SortMethodDesc<Audio> _durationAudioSort() {
  return SortMethodDesc(
    icon: Symbols.timer,
    name: '时长',
    method: (list, order) {
      sortByIntegerThenNatural(
        list,
        valueOf: (audio) => audio.duration,
        tieBreakOf: audioTitleSortValue,
        descending: order == SortOrder.decending,
      );
    },
    backgroundMethod: (list, order, control) => sortPageByIntegerInBackground(
      list,
      (audio) => audio.duration,
      descending: order == SortOrder.decending,
      tieBreakOf: audioTitleSortValue,
      control: control,
    ),
  );
}

List<SortMethodDesc<Audio>> _remoteSortMethods() {
  return [
    _naturalAudioSort(
      icon: Symbols.title,
      name: '名称',
      keyOf: audioTitleSortValue,
      alphabetValueOf: (audio) => audio.title,
    ),
    _naturalAudioSort(
      icon: Symbols.artist,
      name: '艺术家',
      keyOf: audioArtistSortValue,
      alphabetValueOf: (audio) => audio.artist,
    ),
    _naturalAudioSort(
      icon: Symbols.album,
      name: '专辑',
      keyOf: audioAlbumSortValue,
      alphabetValueOf: (audio) => audio.album,
    ),
    _durationAudioSort(),
  ];
}

class RemotePage extends StatefulWidget {
  const RemotePage({super.key});

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  final MultiSelectController<Audio> _multiSelectController =
      MultiSelectController<Audio>();
  String? _selectedSourceId;
  final Set<String> _syncing = <String>{};
  final Map<String, ({double value, String message})> _progress = {};
  int _contentVersion = -1;
  String? _contentSourceId;
  List<Audio> _contentList = [];

  RemoteLibrary get _library => RemoteLibrary.instance;

  @override
  void dispose() {
    _multiSelectController.dispose();
    super.dispose();
  }

  List<Audio> _resolveContentList(int version) {
    final selected =
        _selectedSourceId != null &&
            _library.sourceById(_selectedSourceId!) != null
        ? _selectedSourceId
        : null;
    if (selected != _selectedSourceId) {
      _selectedSourceId = selected;
    }
    if (version == _contentVersion && selected == _contentSourceId) {
      return _contentList;
    }
    _contentVersion = version;
    _contentSourceId = selected;
    _contentList = selected == null
        ? List<Audio>.from(_library.audios)
        : List<Audio>.from(_library.audiosForSource(selected));
    _multiSelectController
      ..selected.clear()
      ..enableMultiSelectView = false;
    return _contentList;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _library.version,
      builder: (context, version, _) {
        final sources = _library.sources;
        final contentList = _resolveContentList(version);
        final selected = _selectedSourceId == null
            ? null
            : _library.sourceById(_selectedSourceId!);
        final canSort = hasEnoughItemsToSort(contentList.length);
        return UniPage<Audio>(
          pref: AppPreference.instance.remotePagePref,
          title: '远程曲库',
          subtitle: _subtitle(sources, selected, contentList),
          contentList: contentList,
          actionPlacement: PageActionPlacement.belowSubtitle,
          primaryAction: sources.isEmpty
              ? null
              : _primaryActions(sources, selected, contentList),
          contentBuilder: (context, audio, i, _, _) => AudioTile(
            audioIndex: i,
            playlist: contentList,
            multiSelectController: _multiSelectController,
          ),
          enableShufflePlay: contentList.isNotEmpty,
          enableSortMethod: canSort,
          enableSortOrder: canSort,
          enableContentViewSwitch: contentList.isNotEmpty,
          sortMethods: _remoteSortMethods(),
          multiSelectController: _multiSelectController,
          multiSelectViewActions: [
            AddAllToPlaylist(multiSelectController: _multiSelectController),
            MultiSelectSelectOrClearAll(
              multiSelectController: _multiSelectController,
              contentList: contentList,
            ),
            MultiSelectExit(multiSelectController: _multiSelectController),
          ],
          emptyState: _emptyState(sources, selected),
        );
      },
    );
  }

  String _subtitle(
    List<RemoteSource> sources,
    RemoteSource? selected,
    List<Audio> contentList,
  ) {
    if (_syncing.isNotEmpty) {
      final progress = _progress[_syncing.last];
      final percent = progress == null
          ? ''
          : ' ${(progress.value * 100).round()}%';
      final message = progress == null || progress.message.isEmpty
          ? ''
          : ' · ${progress.message}';
      return '正在同步$percent$message';
    }
    if (selected != null) {
      return '${selected.kind.label} · ${contentList.length} 首';
    }
    if (sources.isEmpty) return '还没有远程源';
    return '${sources.length} 个源 · ${contentList.length} 首';
  }

  Widget? _emptyState(List<RemoteSource> sources, RemoteSource? selected) {
    if (sources.isEmpty) {
      return QuietEmptyState(
        icon: Symbols.cloud,
        title: '还没有远程音乐',
        message:
            '连接 Navidrome、WebDAV 或 Windows 共享文件夹后，'
            '即可在同一个曲库里播放远程歌曲。',
        action: FilledButton.icon(
          onPressed: _addSource,
          icon: const Icon(Symbols.add),
          label: const Text('添加远程源'),
        ),
      );
    }
    return QuietEmptyState(
      icon: Symbols.cloud_sync,
      title: selected == null ? '远程曲库里还没有歌曲' : '这个源还没有歌曲',
      message: '打开右上角的源菜单点「同步」，把远程目录里的曲目拉下来。',
    );
  }

  Widget _primaryActions(
    List<RemoteSource> sources,
    RemoteSource? selected,
    List<Audio> contentList,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (sources.isNotEmpty) ...[
          _sourceCombo(sources, selected),
          const SizedBox(width: 8),
        ],
        PlayAll<Audio>(contentList: contentList),
      ],
    );
  }

  Widget _sourceCombo(List<RemoteSource> sources, RemoteSource? selected) {
    final scheme = Theme.of(context).colorScheme;
    final syncing = _syncing.isNotEmpty;
    return MenuAnchor(
      style: appMenuStyle,
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Symbols.library_music),
          trailingIcon: selected == null ? const Icon(Symbols.check) : null,
          onPressed: () => _select(null),
          child: const Text('全部远程曲库'),
        ),
        for (final source in sources)
          MenuItemButton(
            leadingIcon: Icon(_sourceIcon(source.kind)),
            trailingIcon: source.id == selected?.id
                ? const Icon(Symbols.check)
                : Text(
                    '${_library.audiosForSource(source.id).length} 首',
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
            onPressed: () => _select(source.id),
            child: Text(source.name),
          ),
        const Divider(height: 1),
        MenuItemButton(
          leadingIcon: const Icon(Symbols.sync),
          onPressed: syncing ? null : () => _syncSelected(selected),
          child: Text(selected == null ? '同步全部源' : '同步「${selected.name}」'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Symbols.edit),
          onPressed: selected == null || syncing
              ? null
              : () => _editSource(selected),
          child: const Text('编辑当前源'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Symbols.delete),
          onPressed: selected == null ? null : () => _deleteSource(selected),
          child: const Text('删除当前源'),
        ),
        const Divider(height: 1),
        MenuItemButton(
          leadingIcon: const Icon(Symbols.add),
          onPressed: _addSource,
          child: const Text('添加远程源'),
        ),
      ],
      builder: (context, controller, _) => FilledButton.tonal(
        onPressed: () {
          if (controller.isOpen) {
            controller.close();
          } else {
            controller.open();
          }
        },
        style: AppButton.pageAction.copyWith(
          backgroundColor: WidgetStatePropertyAll(scheme.secondaryContainer),
          foregroundColor: WidgetStatePropertyAll(scheme.onSecondaryContainer),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (syncing)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                selected == null
                    ? Symbols.library_music
                    : _sourceIcon(selected.kind),
                size: 20,
              ),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                selected?.name ?? '全部远程曲库',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            AnimatedRotation(
              duration: MotionDuration.fast,
              curve: MotionCurve.standard,
              turns: controller.isOpen ? 0.5 : 0.0,
              child: const Icon(Symbols.arrow_drop_down, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  void _select(String? sourceId) {
    setState(() => _selectedSourceId = sourceId);
  }

  Future<void> _syncSelected(RemoteSource? selected) async {
    if (selected != null) {
      await _sync(selected);
      return;
    }
    for (final source in _library.sources) {
      await _sync(source);
    }
  }

  Future<void> _addSource() async {
    final form = await showRemoteSourceDialog(context);
    if (form == null || !mounted) return;
    try {
      final source = await _library.saveSource(
        kind: form.kind,
        name: form.name,
        baseUrl: form.baseUrl,
        username: form.username,
        password: form.password ?? '',
        root: form.root,
      );
      if (!mounted) return;
      setState(() => _selectedSourceId = source.id);
      unawaited(_sync(source));
    } catch (error, trace) {
      log.app.error('legacy', '保存远程源失败', error: error, stackTrace: trace);
      if (mounted) {
        showTextOnSnackBar('保存远程源失败', variant: ToastVariant.error);
      }
    }
  }

  Future<void> _editSource(RemoteSource source) async {
    if (_syncing.contains(source.id)) return;
    final form = await showRemoteSourceDialog(context, source: source);
    if (form == null || !mounted) return;
    try {
      final updated = await _library.saveSource(
        existing: source,
        kind: form.kind,
        name: form.name,
        baseUrl: form.baseUrl,
        username: form.username,
        password: form.password,
        root: form.root,
      );
      if (!mounted) return;
      unawaited(_sync(updated));
    } catch (error, trace) {
      log.app.error('legacy', '保存远程源失败', error: error, stackTrace: trace);
      if (mounted) {
        showTextOnSnackBar('保存远程源失败', variant: ToastVariant.error);
      }
    }
  }

  Future<void> _deleteSource(RemoteSource source) async {
    final syncing = _syncing.contains(source.id);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除远程源'),
        content: Text(
          syncing
              ? '「${source.name}」正在同步，删除会中止同步。确定删除吗？'
              : '确定删除「${source.name}」吗？已下载到本地缓存的封面和歌词不会被清除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _library.deleteSource(source.id);
      if (!mounted) return;
      if (_selectedSourceId == source.id) {
        setState(() => _selectedSourceId = null);
      }
      showTextOnSnackBar('已删除远程源');
    } catch (error, trace) {
      log.app.error('legacy', '删除远程源失败', error: error, stackTrace: trace);
      if (mounted) {
        showTextOnSnackBar('删除远程源失败：$error', variant: ToastVariant.error);
      }
    }
  }

  Future<void> _sync(RemoteSource source) async {
    if (_syncing.contains(source.id)) return;
    setState(() {
      _syncing.add(source.id);
      _progress[source.id] = (value: 0, message: '正在连接…');
    });
    try {
      final count = await _library.syncSource(
        source,
        onProgress: (progress, message) {
          if (!mounted) return;
          setState(
            () => _progress[source.id] = (value: progress, message: message),
          );
        },
      );
      if (!mounted) return;
      showTextOnSnackBar(
        '「${source.name}」已同步 $count 首',
        variant: ToastVariant.success,
      );
    } on RemoteSyncCancelled {
      if (mounted) {
        showTextOnSnackBar('已中止「${source.name}」的同步');
      }
    } catch (error, trace) {
      log.app.error('legacy', '同步远程源失败', error: error, stackTrace: trace);
      if (mounted) {
        showTextOnSnackBar(
          '同步「${source.name}」失败：$error',
          variant: ToastVariant.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _syncing.remove(source.id);
          _progress.remove(source.id);
        });
      }
    }
  }
}
