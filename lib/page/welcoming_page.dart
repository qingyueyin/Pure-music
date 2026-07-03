import 'dart:async';
import 'package:pure_music/native/folder_picker_windows.dart';
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
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48.0),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '你的音乐放在哪些文件夹呢？',
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                ),
              ),
              Text(
                '软件会扫描这些文件夹（包括所有子文件夹）下的音乐并建立索引。',
                style: TextStyle(color: scheme.onSurface),
              ),
              const SizedBox(height: 16),
              const FolderSelectorView(),
            ],
          ),
        ),
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
  final List<String> folders = [];
  final applicationSupportDirectory = getAppDataDir();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: 400,
      height: 400,
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
                      AppPreference.instance.userFolders = AudioLibrary
                          .instance.folders
                          .map((f) => f.path)
                          .toList();
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
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            FilledButton(
              onPressed: () async {
                final paths = pickMultipleDirectories(
                  title: '选择文件夹',
                );
                if (paths.isEmpty) return;

                setState(() {
                  folders.addAll(paths.where((p) => !folders.contains(p)));
                });
              },
              child: const Text('添加文件夹'),
            ),
            if (folders.isEmpty)
              FilledButton.tonal(
                onPressed: () async {
                  AppPreference.instance.userFolders = List.from(folders);
                  await AppPreference.instance.save();
                  if (mounted) {
                    context.go(app_paths.AUDIOS_PAGE);
                  }
                },
                child: const Text('跳过'),
              )
            else
              FilledButton(
                onPressed: () async {
                  AppPreference.instance.userFolders = List.from(folders);
                  await AppPreference.instance.save();
                  setState(() {
                    selecting = false;
                  });
                },
                child: const Text('扫描'),
              ),
          ],
        ),
        const SizedBox(height: 16.0),
        Expanded(
          child: ListView.builder(
            itemCount: folders.length,
            itemBuilder: (context, i) => ListTile(
              title: Text(folders[i]),
              trailing: IconButton(
                tooltip: '移除',
                onPressed: () {
                  setState(() {
                    folders.removeAt(i);
                  });
                },
                color: scheme.error,
                icon: const Icon(Symbols.delete),
              ),
            ),
          ),
        ),
      ],
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
