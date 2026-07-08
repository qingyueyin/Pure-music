import 'dart:async';
import 'package:pure_music/native/folder_picker_windows.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/component/build_index_state_view.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:window_manager/window_manager.dart';

class WelcomingPage extends StatelessWidget {
  const WelcomingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: const PreferredSize(
        preferredSize: Size.fromHeight(48.0),
        child: _TitleBar(),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final horizontalPadding = constraints.maxWidth < 520 ? 20.0 : 48.0;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              24.0,
              horizontalPadding,
              24.0,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 48.0).clamp(
                  0.0,
                  double.infinity,
                ),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '你的音乐放在哪些文件夹呢？',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.bold,
                          fontSize: 22,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '软件会扫描这些文件夹（包括所有子文件夹）下的音乐并建立索引。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurface),
                      ),
                      const SizedBox(height: 16),
                      const FolderSelectorView(),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class FolderSelectorView extends StatefulWidget {
  const FolderSelectorView({super.key});

  @override
  State<FolderSelectorView> createState() => _FolderSelectorViewState();
}

class _FolderSelectorViewState extends State<FolderSelectorView> {
  bool selecting = true;
  bool _isCommittingChoice = false;
  bool _isPickingFolder = false;
  final List<String> folders = [];
  final applicationSupportDirectory = getAppDataDir();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final viewSize = MediaQuery.sizeOf(context);
    final width = (viewSize.width - 80.0).clamp(280.0, 400.0).toDouble();
    final height = (viewSize.height - 260.0).clamp(260.0, 400.0).toDouble();

    return SizedBox(
      width: width,
      height: height,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: selecting
            ? folderSelector(scheme)
            : FutureBuilder(
                future: applicationSupportDirectory,
                builder: (context, snapshot) {
                  if (snapshot.data == null) {
                    return const Center(
                      child: Text('Fail to get app data dir.'),
                    );
                  }

                  return BuildIndexStateView(
                    indexPath: snapshot.data!,
                    folders: folders,
                    whenIndexBuilt: () async {
                      await Future.wait([
                        AppSettings.instance.saveSettings(),
                        AudioLibrary.initFromIndex(),
                      ]);
                      AppPreference.instance.userFolders = List.from(folders);
                      await AppPreference.instance.save();
                      if (context.mounted) {
                        context.go(app_paths.AUDIOS_PAGE);
                      }
                    },
                  );
                },
              ),
      ),
    );
  }

  Widget folderSelector(ColorScheme scheme) {
    return Column(
      children: [
        Wrap(
          spacing: 8.0,
          runSpacing: 8.0,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _isCommittingChoice || _isPickingFolder
                  ? null
                  : () async {
                      setState(() => _isPickingFolder = true);
                      await Future<void>.delayed(Duration.zero);

                      try {
                        final paths = pickMultipleDirectories(
                          title: '选择文件夹',
                        );
                        if (paths.isEmpty || !mounted) return;

                        final nextFolders = appendUniquePendingFolders(
                          current: folders,
                          incoming: paths,
                        );
                        setState(() {
                          folders
                            ..clear()
                            ..addAll(nextFolders);
                        });
                      } finally {
                        if (mounted) {
                          setState(() => _isPickingFolder = false);
                        }
                      }
                    },
              icon: _isPickingFolder
                  ? const SizedBox(
                      width: 18.0,
                      height: 18.0,
                      child: CircularProgressIndicator(strokeWidth: 2.0),
                    )
                  : const Icon(Symbols.create_new_folder),
              label: Text(_isPickingFolder ? '选择中' : '添加文件夹'),
            ),
            if (folders.isNotEmpty) _FolderCountPill(count: folders.length),
            if (folders.isEmpty)
              FilledButton.tonalIcon(
                onPressed: _isCommittingChoice || _isPickingFolder
                    ? null
                    : () async {
                        setState(() => _isCommittingChoice = true);
                        try {
                          AppPreference.instance.userFolders =
                              List.from(folders);
                          await AppPreference.instance.save();
                          if (mounted) {
                            context.go(app_paths.AUDIOS_PAGE);
                          }
                        } finally {
                          if (mounted) {
                            setState(() => _isCommittingChoice = false);
                          }
                        }
                      },
                icon: _isCommittingChoice
                    ? const SizedBox(
                        width: 18.0,
                        height: 18.0,
                        child: CircularProgressIndicator(strokeWidth: 2.0),
                      )
                    : const Icon(Symbols.skip_next),
                label: Text(_isCommittingChoice ? '准备中' : '跳过'),
              )
            else
              FilledButton.icon(
                onPressed: _isCommittingChoice || _isPickingFolder
                    ? null
                    : () async {
                        setState(() => _isCommittingChoice = true);
                        try {
                          AppPreference.instance.userFolders =
                              List.from(folders);
                          await AppPreference.instance.save();
                          if (mounted) {
                            setState(() {
                              selecting = false;
                            });
                          }
                        } finally {
                          if (mounted && selecting) {
                            setState(() => _isCommittingChoice = false);
                          }
                        }
                      },
                icon: _isCommittingChoice
                    ? const SizedBox(
                        width: 18.0,
                        height: 18.0,
                        child: CircularProgressIndicator(strokeWidth: 2.0),
                      )
                    : const Icon(Symbols.travel_explore),
                label: Text(_isCommittingChoice ? '准备中' : '扫描'),
              ),
          ],
        ),
        const SizedBox(height: 16.0),
        Expanded(
          child: folders.isEmpty
              ? const _EmptyFolderState()
              : ListView.builder(
                  itemCount: folders.length,
                  itemBuilder: (context, i) => ListTile(
                    title: Text(
                      folders[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.error,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: canRemovePendingFolder(
                        isCommitting: _isCommittingChoice,
                        isPickingFolder: _isPickingFolder,
                      )
                          ? () {
                              setState(() {
                                folders.removeAt(i);
                              });
                            }
                          : null,
                      icon: const Icon(Symbols.remove_circle, size: 18),
                      label: const Text('移除'),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _FolderCountPill extends StatelessWidget {
  const _FolderCountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$count 个文件夹',
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyFolderState extends StatelessWidget {
  const _EmptyFolderState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.folder_open,
              size: 32,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '还没有选择音乐文件夹',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '添加文件夹后再扫描曲库',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragToMoveArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Image.asset('app_icon.ico', width: 24, height: 24),
                  ),
                  Text(
                    'Pure Music',
                    style: TextStyle(color: scheme.onSurface, fontSize: 16),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8.0),
            const _WindowControlls(),
          ],
        ),
      ),
    );
  }
}

class _WindowControlls extends StatefulWidget {
  const _WindowControlls();

  @override
  State<_WindowControlls> createState() => __WindowControllsState();
}

class __WindowControllsState extends State<_WindowControlls>
    with WindowListener {
  bool _isMaximized = false;
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _updateMaximizedState();
  }

  Future<void> _updateMaximizedState() async {
    final isMaximized = await windowManager.isMaximized();
    if (mounted) {
      setState(() {
        _isMaximized = isMaximized;
      });
    }
  }

  Future<void> _exitApp() async {
    if (_isClosing) return;
    _isClosing = true;

    try {
      await windowManager.hide().timeout(const Duration(milliseconds: 500));
    } catch (_) {}

    try {
      await HotkeysHelper.unregisterAll().timeout(
        const Duration(milliseconds: 300),
      );
    } catch (_) {}

    try {
      await AppSettings.instance.saveSettings().timeout(
            const Duration(seconds: 1),
          );
    } catch (_) {}

    try {
      await AppPreference.instance.save().timeout(const Duration(seconds: 1));
    } catch (_) {}

    try {
      await windowManager.destroy().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    _exitApp();
  }

  @override
  void onWindowMaximize() {
    setState(() {
      _isMaximized = true;
    });
  }

  @override
  void onWindowUnmaximize() {
    setState(() {
      _isMaximized = false;
    });
  }

  @override
  void onWindowRestore() {
    _updateMaximizedState();
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8.0,
      children: [
        IconButton(
          tooltip: '最小化',
          onPressed: windowManager.minimize,
          icon: const Icon(Symbols.remove),
        ),
        IconButton(
          tooltip: _isMaximized ? '还原' : '最大化',
          onPressed:
              _isMaximized ? windowManager.unmaximize : windowManager.maximize,
          icon: Icon(
            _isMaximized ? Symbols.fullscreen_exit : Symbols.fullscreen,
          ),
        ),
        IconButton(
          tooltip: '退出',
          onPressed: _exitApp,
          icon: const Icon(Symbols.close),
        ),
      ],
    );
  }
}
