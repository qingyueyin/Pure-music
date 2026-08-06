import 'dart:async';
import 'dart:io';

import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/core/utils.dart';
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
      logger.e('获取应用数据目录失败', error: e, stackTrace: trace);
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

            if (snapshot.hasError ||
                !snapshot.hasData ||
                snapshot.data == null) {
              return Padding(
                padding: const EdgeInsets.all(32.0),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: scheme.error,
                        size: 40.0,
                      ),
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
                        '应用数据目录不可用，请查看日志',
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 16.0),
                      FilledButton.icon(
                        onPressed: () => exit(1),
                        icon: const Icon(Icons.close),
                        label: const Text('退出'),
                      ),
                    ],
                  ),
                ),
              );
            }

            return UpdatingStateView(indexPath: snapshot.data!);
          },
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
  late final Stream<IndexActionState> updateIndexStream;
  StreamSubscription<IndexActionState>? _subscription;
  String? _errorMessage;

  void whenIndexUpdated() async {
    if (_errorMessage != null) return;
    try {
      await Future.wait([
        AudioLibrary.initFromIndex(),
        readPlaylists(),
        readLyricSources(),
      ]);
      AlbumColorCache.instance
          .prewarmAlbums(AudioLibrary.instance.albumCollection.values)
          .ignore();
      await _subscription?.cancel();
      final ctx = context;
      if (ctx.mounted) {
        ctx.go(app_paths.AUDIOS_PAGE);
      }
    } catch (e, trace) {
      logger.e('索引完成后读取音乐库失败', error: e, stackTrace: trace);
      if (mounted) {
        setState(() => _errorMessage = '音乐库读取失败，请查看日志');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    updateIndexStream = updateIndex(
      indexPath: widget.indexPath.path,
    ).asBroadcastStream();

    _subscription = updateIndexStream.listen(
      (action) {
        logger.i('[update index] ${action.progress}: ${action.message}');
      },
      onError: (Object error, StackTrace stackTrace) {
        logger.e('更新音乐库索引失败', error: error, stackTrace: stackTrace);
        if (mounted) {
          setState(() => _errorMessage = '音乐库索引失败，请查看日志');
        }
      },
      onDone: whenIndexUpdated,
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
    final errorMessage = _errorMessage;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420.0),
          child: errorMessage != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: scheme.error,
                      size: 40.0,
                    ),
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
                      errorMessage,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16.0),
                    FilledButton.icon(
                      onPressed: () => exit(1),
                      icon: const Icon(Icons.close),
                      label: const Text('退出'),
                    ),
                  ],
                )
              : StreamBuilder<IndexActionState>(
                  stream: updateIndexStream,
                  builder: (context, snapshot) {
                    final progress = snapshot.data?.progress;
                    final message = snapshot.data?.message ?? '正在初始化...';

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LinearProgressIndicator(
                          value: progress,
                          backgroundColor:
                              scheme.onSurface.withValues(alpha: 0.1),
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(2.0),
                          minHeight: 8,
                        ),
                        const SizedBox(height: 16.0),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(
                                message,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: scheme.onSurface,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            if (progress != null) ...[
                              const SizedBox(width: 8.0),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8.0,
                                  vertical: 4.0,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12.0),
                                ),
                                child: Text(
                                  '${(progress.clamp(0.0, 1.0) * 100).round()}%',
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                    fontSize: 12.0,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    );
                  },
                ),
        ),
      ),
    );
  }
}
