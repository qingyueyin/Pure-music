import 'dart:async';
import 'dart:io';

import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/core/utils.dart';
import 'package:flutter/material.dart';

class BuildIndexStateView extends StatefulWidget {
  const BuildIndexStateView(
      {super.key,
      required this.indexPath,
      required this.folders,
      required this.whenIndexBuilt});

  final Directory indexPath;
  final List<String> folders;
  final void Function() whenIndexBuilt;

  @override
  State<BuildIndexStateView> createState() => _BuildIndexStateViewState();
}

class _BuildIndexStateViewState extends State<BuildIndexStateView> {
  late final Stream<IndexActionState> _buildIndexStream;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _buildIndexStream = buildIndexFromFoldersRecursively(
      folders: widget.folders,
      indexPath: widget.indexPath.path,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return StreamBuilder(
      stream: _buildIndexStream,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          logger.i(
            '[build index] ${snapshot.data!.progress}: ${snapshot.data!.message}',
          );
        }
        if (!_done && snapshot.connectionState == ConnectionState.done) {
          _done = true;
          WidgetsBinding.instance
              .addPostFrameCallback((_) => widget.whenIndexBuilt());
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            LinearProgressIndicator(
              value: snapshot.data?.progress,
              borderRadius: BorderRadius.circular(2.0),
            ),
            const SizedBox(height: 8.0),
            Text(
              '${snapshot.data?.message}',
              style: TextStyle(color: scheme.onSurface),
            ),
          ],
        );
      },
    );
  }
}
