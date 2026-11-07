import 'dart:async';
import 'dart:io';

import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/component/index_progress_view.dart';
import 'package:pure_music/core/window_lifecycle.dart';
import 'package:pure_music/services/native/library_index_service.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

class UpdatingPage extends StatefulWidget {
  const UpdatingPage({super.key});

  @override
  State<UpdatingPage> createState() => _UpdatingPageState();
}

class _UpdatingPageState extends State<UpdatingPage> {
  late final Future<Directory?> _appDataDirFuture;

  @override
  void initState() {
    super.initState();
    _appDataDirFuture = _getAppDataDirSafe();
  }

  Future<Directory?> _getAppDataDirSafe() async {
    try {
      return await getAppDataDir();
    } catch (e, trace) {
      log.library.error('legacy', '获取应用数据目录失败', error: e, stackTrace: trace);
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Center(
        child: FutureBuilder<Directory?>(
          future: _appDataDirFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return _PreparingView(scheme: scheme);
            }
            if (snapshot.hasError ||
                !snapshot.hasData ||
                snapshot.data == null) {
              return _InitErrorView(scheme: scheme, message: '应用数据目录不可用，请查看日志');
            }
            return UpdatingStateView(indexPath: snapshot.data!);
          },
        ),
      ),
    );
  }
}

class _PreparingView extends StatelessWidget {
  const _PreparingView({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: scheme.primary),
            const SizedBox(height: 16.0),
            Text(
              '正在准备应用数据...',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

class _InitErrorView extends StatelessWidget {
  const _InitErrorView({required this.scheme, required this.message});

  final ColorScheme scheme;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: scheme.error, size: 40.0),
            const SizedBox(height: 12.0),
            Text(
              '初始化失败',
              style: TextStyle(
                color: scheme.error,
                fontSize: 18.0,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8.0),
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16.0),
            FilledButton.icon(
              onPressed: WindowLifecycleService.instance.exitApp,
              icon: const Icon(Icons.close),
              label: const Text('退出'),
            ),
          ],
        ),
      ),
    );
  }
}

class UpdatingStateView extends StatefulWidget {
  const UpdatingStateView({super.key, required this.indexPath});

  final Directory indexPath;

  @override
  State<UpdatingStateView> createState() => _UpdatingStateViewState();
}

class _UpdatingStateViewState extends State<UpdatingStateView> {
  StreamSubscription<LibraryIndexState>? _subscription;
  LibraryIndexState? _latestAction;
  String? _errorMessage;

  Future<void> whenIndexUpdated() async {
    if (_errorMessage != null) return;
    try {
      await Future.wait([
        AudioLibrary.initFromIndex(),
        readPlaylists(),
        readLyricSources(),
      ]);
      if (WindowLifecycleService.instance.isExiting) return;
      pruneLyricSourcesWhereMissing(
        (path) => AudioLibrary.instance.audioByPath(path) != null,
      );
      WindowLifecycleService.instance.markLibraryReady();
      await _subscription?.cancel();
      final ctx = context;
      if (ctx.mounted && !WindowLifecycleService.instance.isExiting) {
        ctx.go(app_paths.AUDIOS_PAGE);
      }
    } catch (e, trace) {
      log.library.error('legacy', '索引完成后读取音乐库失败', error: e, stackTrace: trace);
      if (mounted) {
        setState(() => _errorMessage = '音乐库读取失败，请查看日志');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _startUpdate();
  }

  void _startUpdate() {
    _subscription?.cancel();
    setState(() => _errorMessage = null);
    _subscription = LibraryIndexService.instance
        .updateIndex(
          folders: AudioLibrary.aggregatedRootFolders()
              .map((folder) => folder.path)
              .toList(growable: false),
          indexPath: widget.indexPath.path,
          forceMetadataCheck: false,
        )
        .listen(
          (action) {
            if (action.message.isNotEmpty) {
              log.library.info(
                'legacy',
                '[update index] ${action.progress}: ${action.message}',
              );
            }
            if (mounted) {
              setState(() => _latestAction = action);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            log.library.error(
              'legacy',
              '更新音乐库索引失败',
              error: error,
              stackTrace: stackTrace,
            );
            if (mounted) {
              setState(() => _errorMessage = '音乐库索引失败，请查看日志');
            }
          },
          onDone: () => unawaited(whenIndexUpdated()),
          cancelOnError: true,
        );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420.0),
          child: _progressBody(scheme),
        ),
      ),
    );
  }

  Widget _progressBody(ColorScheme scheme) {
    // 阶段文案、失败重试与不可读计数统一走共享扫描视图。
    return IndexProgressView(
      state: _latestAction,
      errorMessage: _errorMessage,
      onRetry: _errorMessage == null ? null : _startUpdate,
    );
  }
}
