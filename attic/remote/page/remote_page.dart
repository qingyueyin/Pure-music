import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/page/remote_source_dialog.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/remote/remote_library.dart';
import 'package:pure_music/remote/remote_source.dart';

class RemotePage extends StatefulWidget {
  const RemotePage({super.key});

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  String? _selectedSourceId;
  final Set<String> _syncing = <String>{};
  final Map<String, String> _progress = <String, String>{};

  RemoteLibrary get _library => RemoteLibrary.instance;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _library.version,
      builder: (context, _) {
        final sources = _library.sources;
        final audios = _selectedSourceId == null
            ? _library.audios
            : _library.audiosForSource(_selectedSourceId!);
        return PageScaffold(
          title: '远程音乐',
          subtitle: '${sources.length} 个源 · ${_library.audios.length} 首',
          actions: [
            IconButton.filledTonal(
              icon: const Icon(Symbols.play_arrow),
              tooltip: '播放全部',
              onPressed: audios.isEmpty
                  ? null
                  : () => PlayService.instance.playbackService.play(0, audios),
            ),
            IconButton.filledTonal(
              icon: const Icon(Symbols.shuffle),
              tooltip: '随机播放',
              onPressed: audios.isEmpty
                  ? null
                  : () => PlayService.instance.playbackService.shuffleAndPlay(
                      audios,
                    ),
            ),
            IconButton.filledTonal(
              icon: const Icon(Symbols.add),
              tooltip: '添加远程源',
              onPressed: _addSource,
            ),
          ],
          body: sources.isEmpty
              ? QuietEmptyState(
                  icon: Symbols.cloud,
                  title: '还没有远程音乐',
                  message:
                      '连接 Navidrome、WebDAV 或 Windows 共享文件夹后，'
                      '就能在同一个曲库里播放远程歌曲。',
                  action: FilledButton.icon(
                    onPressed: _addSource,
                    icon: const Icon(Symbols.add),
                    label: const Text('添加远程源'),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: 94, child: _sourceStrip(sources)),
                    const SizedBox(height: Spacing.md),
                    Expanded(child: _trackList(audios)),
                  ],
                ),
        );
      },
    );
  }

  Widget _sourceStrip(List<RemoteSource> sources) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: sources.length + 1,
      separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _sourceCard(
            title: '全部',
            subtitle: '${_library.audios.length} 首',
            icon: Symbols.library_music,
            selected: _selectedSourceId == null,
            onTap: () => setState(() => _selectedSourceId = null),
          );
        }
        final source = sources[index - 1];
        return _sourceCard(
          title: source.name,
          subtitle:
              _progress[source.id] ??
              '${_library.audiosForSource(source.id).length} 首',
          icon: _iconFor(source.kind),
          selected: _selectedSourceId == source.id,
          syncing: _syncing.contains(source.id),
          onTap: () => setState(() => _selectedSourceId = source.id),
          trailing: _sourceMenu(source),
        );
      },
    );
  }

  Widget _sourceCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
    bool syncing = false,
    Widget? trailing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 236,
      child: Card(
        elevation: 0,
        color: selected
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.mdCircular,
          side: BorderSide(
            color: selected ? scheme.secondary : Colors.transparent,
          ),
        ),
        child: InkWell(
          borderRadius: AppRadius.mdCircular,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: selected
                              ? scheme.onSecondaryContainer
                              : scheme.onSurface,
                          fontWeight: AppType.weightSemibold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (syncing) ...[
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Expanded(
                            child: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sourceMenu(RemoteSource source) {
    final syncing = _syncing.contains(source.id);
    return PopupMenuButton<String>(
      icon: const Icon(Symbols.more_vert, size: 20),
      onSelected: (value) {
        switch (value) {
          case 'sync':
            unawaited(_sync(source));
            break;
          case 'edit':
            unawaited(_editSource(source));
            break;
          case 'delete':
            unawaited(_deleteSource(source));
            break;
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'sync',
          enabled: !_syncing.contains(source.id),
          child: const Text('同步'),
        ),
        PopupMenuItem(
          value: 'edit',
          enabled: !syncing,
          child: const Text('编辑'),
        ),
        PopupMenuItem(
          value: 'delete',
          enabled: !syncing,
          child: const Text('删除'),
        ),
      ],
    );
  }

  Widget _trackList(List<Audio> audios) {
    if (audios.isEmpty) {
      return const QuietEmptyState(
        icon: Symbols.music_note,
        title: '这里还没有歌曲',
        message: '选中远程源后点「同步」，或检查远程服务器上的音乐目录。',
      );
    }
    return ListView.builder(
      itemCount: audios.length,
      itemBuilder: (context, index) =>
          AudioTile(audioIndex: index, playlist: audios),
    );
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
      log.app.error('legacy', '添加远程源失败', error: error, stackTrace: trace);
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
      log.app.error('legacy', '更新远程源失败', error: error, stackTrace: trace);
      if (mounted) {
        showTextOnSnackBar('保存远程源失败', variant: ToastVariant.error);
      }
    }
  }

  Future<void> _deleteSource(RemoteSource source) async {
    if (_syncing.contains(source.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除远程源'),
        content: Text('确定删除「${source.name}」以及它的全部远程歌曲记录吗？'),
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
      _progress[source.id] = '正在连接…';
    });
    try {
      final count = await _library.syncSource(
        source,
        onProgress: (progress, message) {
          if (!mounted) return;
          setState(() => _progress[source.id] = message);
        },
      );
      if (!mounted) return;
      showTextOnSnackBar(
        '「${source.name}」已同步 $count 首',
        variant: ToastVariant.success,
      );
    } catch (error, trace) {
      log.app.error(
        'legacy',
        '同步远程源失败: ${source.name}',
        error: error,
        stackTrace: trace,
      );
      if (mounted) {
        showTextOnSnackBar('同步失败：$error', variant: ToastVariant.error);
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

  IconData _iconFor(RemoteSourceKind kind) {
    return switch (kind) {
      RemoteSourceKind.navidrome => Symbols.dns,
      RemoteSourceKind.webdav => Symbols.cloud,
      RemoteSourceKind.smb => Symbols.folder_shared,
    };
  }
}
