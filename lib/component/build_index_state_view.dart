import 'dart:async';
import 'dart:io';

import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/utils.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

typedef IndexBuilder =
    Stream<IndexActionState> Function({
      required List<String> folders,
      required String indexPath,
    });

class BuildIndexStateView extends StatefulWidget {
  const BuildIndexStateView({
    super.key,
    required this.indexPath,
    required this.folders,
    required this.whenIndexBuilt,
    this.buildIndex = buildIndexFromFoldersRecursively,
  });

  final Directory indexPath;
  final List<String> folders;
  final FutureOr<void> Function() whenIndexBuilt;
  final IndexBuilder buildIndex;

  @override
  State<BuildIndexStateView> createState() => _BuildIndexStateViewState();
}

class _BuildIndexStateViewState extends State<BuildIndexStateView> {
  late final Stream<IndexActionState> _buildIndexStream;
  bool _done = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _buildIndexStream = widget.buildIndex(
      folders: widget.folders,
      indexPath: widget.indexPath.path,
    );
  }

  Future<void> _completeBuild() async {
    try {
      await widget.whenIndexBuilt();
    } catch (error, stackTrace) {
      logger.e('曲库索引完成后的加载失败', error: error, stackTrace: stackTrace);
      if (mounted) {
        setState(() => _errorMessage = '曲库加载失败，请查看日志');
      }
    }
  }

  Widget _buildError(ColorScheme scheme, String message) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Symbols.error, color: scheme.error, size: 20.0),
        const SizedBox(width: 8.0),
        Flexible(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.error),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return StreamBuilder(
      stream: _buildIndexStream,
      builder: (context, snapshot) {
        final errorMessage = _errorMessage;
        if (errorMessage != null) {
          return _buildError(scheme, errorMessage);
        }
        if (snapshot.hasError) {
          return _buildError(scheme, '曲库索引构建失败，请查看日志');
        }
        if (snapshot.hasData) {
          logger.i(
            '[build index] ${snapshot.data!.progress}: ${snapshot.data!.message}',
          );
        }
        if (!_done && snapshot.connectionState == ConnectionState.done) {
          _done = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_completeBuild());
          });
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
