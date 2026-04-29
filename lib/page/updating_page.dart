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
    } catch (e) {
      logger.e('getAppDataDir failed: $e');
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
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: scheme.primary),
                  const SizedBox(height: 16),
                  Text("加载中...", style: TextStyle(color: scheme.onSurface)),
                ],
              );
            }

            if (snapshot.hasError || !snapshot.hasData || snapshot.data == null) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("初始化失败: ${snapshot.error ?? "超时"}",
                      style: TextStyle(color: scheme.error)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => exit(1),
                    child: const Text("退出"),
                  ),
                ],
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
  StreamSubscription? _subscription;

  void whenIndexUpdated() async {
    await Future.wait([
      AudioLibrary.initFromIndex(),
      readPlaylists(),
      readLyricSources(),
    ]);
    AlbumColorCache.instance
        .prewarmAlbums(AudioLibrary.instance.albumCollection.values)
        .ignore();
    _subscription?.cancel();
    final ctx = context;
    if (ctx.mounted) {
      ctx.go(app_paths.AUDIOS_PAGE);
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
        logger.i("[update index] ${action.progress}: ${action.message}");
      },
      onDone: whenIndexUpdated,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            StreamBuilder<IndexActionState>(
              stream: updateIndexStream,
              builder: (context, snapshot) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(
                      value: snapshot.data?.progress,
                      backgroundColor: scheme.onSurface.withOpacity(0.1),
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(2.0),
                      minHeight: 8,
                    ),
                    const SizedBox(height: 16.0),
                    Text(
                      snapshot.data?.message ?? "正在初始化...",
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 14,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
