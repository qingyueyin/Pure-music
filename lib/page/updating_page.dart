import 'dart:async';
import 'dart:io';

import 'package:pure_music/app_preference.dart';
import 'package:pure_music/app_settings.dart';
import 'package:pure_music/album_color_cache.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/src/rust/api/tag_reader.dart';
import 'package:pure_music/utils.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/app_paths.dart' as app_paths;

class UpdatingPage extends StatelessWidget {
  const UpdatingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Center(
        child: FutureBuilder(
          future: getAppDataDir(),
          builder: (context, snapshot) {
            if (snapshot.data == null) {
              return const Center(
                child: Text("Fail to get app data dir."),
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
        LOGGER.i("[update index] ${action.progress}: ${action.message}");
      },
      onDone: whenIndexUpdated,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: 400.0,
      child: StreamBuilder(
        stream: updateIndexStream,
        builder: (context, snapshot) {
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              LinearProgressIndicator(
                value: snapshot.data?.progress,
                borderRadius: BorderRadius.circular(2.0),
              ),
              const SizedBox(height: 8.0),
              Text(
                "${snapshot.data?.message}",
                style: TextStyle(color: scheme.onSurface),
              ),
            ],
          );
        },
      ),
    );
  }
}
