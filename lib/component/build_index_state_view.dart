import 'dart:async';
import 'dart:io';

import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/core/design_tokens.dart';
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
        final progress = snapshot.data?.progress;
        final message = snapshot.data?.message ?? '正在准备曲库索引…';

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            LinearProgressIndicator(
              value: progress,
              borderRadius: AppRadius.xsCircular,
            ),
            const SizedBox(height: 8.0),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    message,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onSurface),
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
                      borderRadius: AppRadius.mdCircular,
                    ),
                    child: Text(
                      '${(progress.clamp(0.0, 1.0) * 100).round()}%',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: AppType.caption,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}
