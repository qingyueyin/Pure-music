import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/rust/api/utils.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart' as rust_tag_reader;
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double size = bytes.toDouble();
  int unitIndex = -1;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex += 1;
  }
  return '${size.toStringAsFixed(size >= 10 ? 1 : 2)} ${units[unitIndex]}';
}

final Map<String, Future<rust_tag_reader.AudioExtraMetadata>> _audioExtraCache = {};

Future<rust_tag_reader.AudioExtraMetadata> _getAudioExtra(Audio audio) {
  final key = '${audio.path}|${audio.modified}';
  final existing = _audioExtraCache[key];
  if (existing != null) return existing;
  final future = rust_tag_reader
      .readAudioExtraMetadata(path: audio.path)
      .catchError((_) => rust_tag_reader.AudioExtraMetadata(
          extension_: '',
          fileSize: BigInt.zero,
          channels: null,
          bitDepth: null,
          items: [],
          replaygainTrackGain: null,
          replaygainTrackPeak: null,
          replaygainAlbumGain: null,
          replaygainAlbumPeak: null));
  _audioExtraCache[key] = future;
  return future;
}

class AudioDetailPage extends StatefulWidget {
  const AudioDetailPage({super.key, required this.audio});

  final Audio audio;

  @override
  State<AudioDetailPage> createState() => _AudioDetailPageState();
}

class _AudioDetailPageState extends State<AudioDetailPage> {
  bool _isOpeningInExplorer = false;
  bool _isCopyingPath = false;
  bool _isCopyingTitle = false;

  Audio get audio => widget.audio;

  Future<void> _showCurrentAudioInExplorer() async {
    if (_isOpeningInExplorer) return;
    setState(() => _isOpeningInExplorer = true);
    try {
      final result = await showInExplorer(path: audio.path);
      if (!result && mounted) {
        showTextOnSnackBar('打开失败');
      }
    } finally {
      if (mounted) {
        setState(() => _isOpeningInExplorer = false);
      }
    }
  }

  Future<void> _copyCurrentAudioPath() async {
    if (_isCopyingPath) return;
    setState(() => _isCopyingPath = true);
    try {
      await Clipboard.setData(ClipboardData(text: audio.path));
      if (mounted) {
        showTextOnSnackBar('已复制路径');
      }
    } finally {
      if (mounted) {
        setState(() => _isCopyingPath = false);
      }
    }
  }

  Future<void> _copyCurrentAudioTitle() async {
    if (_isCopyingTitle) return;
    setState(() => _isCopyingTitle = true);
    try {
      await Clipboard.setData(ClipboardData(text: audio.title));
      if (mounted) {
        showTextOnSnackBar('已复制歌名');
      }
    } finally {
      if (mounted) {
        setState(() => _isCopyingTitle = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final album = AudioLibrary.instance.albumCollection[audio.album];
    const space = SizedBox(height: 16.0);

    final styleTitle = TextStyle(
      fontSize: AppType.sectionTitle,
      fontWeight: AppType.weightSemibold,
      color: scheme.onSurface,
    );
    final styleContent = TextStyle(fontSize: AppType.body, color: scheme.onSurface);
    final placeholder = SizedBox(
      width: 156.0,
      height: 156.0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: AppRadius.mdCircular,
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Icon(
          Symbols.queue_music,
          color: scheme.onSurfaceVariant,
          size: 64.0,
        ),
      ),
    );

    return ColoredBox(
      color: scheme.surfaceContainer,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 96.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 520.0;
                final chipMaxWidth =
                    (constraints.maxWidth - (narrow ? 40.0 : 220.0))
                        .clamp(180.0, 420.0);
                final cover = FutureBuilder(
                  future: audio.mediumCover,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const SizedBox(
                        width: 156,
                        height: 156,
                        child: Center(
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }
                    if (snapshot.data == null) return placeholder;
                    return ClipRRect(
                      borderRadius: AppRadius.mdCircular,
                      child: Image(
                        image: snapshot.data!,
                        width: 156,
                        height: 156,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => placeholder,
                      ),
                    );
                  },
                );
                final info = Column(
                  crossAxisAlignment: narrow
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment:
                          narrow ? WrapAlignment.center : WrapAlignment.start,
                      children: [
                        Text(
                          '歌名：',
                          style: TextStyle(
                            fontSize: AppType.body,
                            color: scheme.onSurface.withValues(alpha: 0.70),
                          ),
                        ),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: chipMaxWidth),
                          child: ActionChip(
                            label: Text(
                              audio.title,
                              style: styleTitle.copyWith(fontSize: AppType.subtitle),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                            avatar: _isCopyingTitle
                                ? const SizedBox(
                                    width: 18.0,
                                    height: 18.0,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.0,
                                    ),
                                  )
                                : null,
                            onPressed:
                                _isCopyingTitle ? null : _copyCurrentAudioTitle,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment:
                          narrow ? WrapAlignment.center : WrapAlignment.start,
                      children: [
                        Text(
                          '歌手：',
                          style: TextStyle(
                            fontSize: AppType.body,
                            color: scheme.onSurface.withValues(alpha: 0.70),
                          ),
                        ),
                        ...audio.splitedArtists.map((name) {
                          final artist =
                              AudioLibrary.instance.artistCollection[name];
                          return ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: chipMaxWidth),
                            child: ActionChip(
                              label: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                softWrap: false,
                              ),
                              onPressed: artist == null
                                  ? null
                                  : () => context.push(
                                        app_paths.ARTIST_DETAIL_PAGE,
                                        extra: artist,
                                      ),
                            ),
                          );
                        }),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment:
                          narrow ? WrapAlignment.center : WrapAlignment.start,
                      children: [
                        Text(
                          '专辑：',
                          style: TextStyle(
                            fontSize: AppType.body,
                            color: scheme.onSurface.withValues(alpha: 0.70),
                          ),
                        ),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: chipMaxWidth),
                          child: ActionChip(
                            label: Text(
                              audio.album,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                            onPressed: album == null
                                ? null
                                : () => context.push(
                                      app_paths.ALBUM_DETAIL_PAGE,
                                      extra: album,
                                    ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment:
                          narrow ? WrapAlignment.center : WrapAlignment.start,
                      children: [
                        IconButton(
                          tooltip: '在文件管理器中显示',
                          onPressed: _isOpeningInExplorer
                              ? null
                              : _showCurrentAudioInExplorer,
                          icon: _isOpeningInExplorer
                              ? const SizedBox(
                                  width: 20.0,
                                  height: 20.0,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.0,
                                  ),
                                )
                              : const Icon(Symbols.folder_open),
                        ),
                        IconButton(
                          tooltip: '复制路径',
                          onPressed:
                              _isCopyingPath ? null : _copyCurrentAudioPath,
                          icon: _isCopyingPath
                              ? const SizedBox(
                                  width: 20.0,
                                  height: 20.0,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.0,
                                  ),
                                )
                              : const Icon(Symbols.content_copy),
                        ),
                      ],
                    ),
                  ],
                );

                if (narrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Center(child: cover),
                      const SizedBox(height: 16.0),
                      info,
                    ],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    cover,
                    const SizedBox(width: 16),
                    Expanded(child: info),
                  ],
                );
              },
            ),
            space,
            LayoutBuilder(
              builder: (context, constraints) {
                final maxWidth =
                    constraints.maxWidth > 960 ? 960.0 : constraints.maxWidth;
                final colCount = maxWidth > 600 ? 3 : 2;
                final colWidth = (maxWidth - (colCount - 1) * 16) / colCount;
                return Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: FutureBuilder<rust_tag_reader.AudioExtraMetadata>(
                      future: _getAudioExtra(audio),
                      builder: (context, snapshot) {
                        final data = snapshot.data;

                        final children = <Widget>[
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: '音轨',
                              child: Text(audio.track.toString(),
                                  style: styleContent),
                            ),
                          ),
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: '时长',
                              child: Text(
                                Duration(
                                  milliseconds: (audio.duration * 1000).toInt(),
                                ).toStringHMMSS(),
                                style: styleContent,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: '码率',
                              child: Text("${audio.bitrate ?? "-"} kbps",
                                  style: styleContent),
                            ),
                          ),
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: '采样率',
                              child: Text("${audio.sampleRate ?? "-"} hz",
                                  style: styleContent),
                            ),
                          ),
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: '格式',
                              child: Text(
                                p
                                    .extension(audio.path)
                                    .replaceFirst('.', '')
                                    .toUpperCase(),
                                style: styleContent,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: '文件大小',
                              child: Builder(
                                builder: (context) {
                                  final fileSize = data?.fileSize;
                                  if (fileSize != null && fileSize > BigInt.zero) {
                                    return Text(
                                      _formatBytes(fileSize.toInt()),
                                      style: styleContent,
                                    );
                                  }
                                  return FutureBuilder<FileStat>(
                                    future: File(audio.path).stat(),
                                    builder: (context, snapshot) {
                                      final size = snapshot.data?.size;
                                      return Text(
                                        size == null ? '-' : _formatBytes(size),
                                        style: styleContent,
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                          ),
                        ];

                        final bd = data?.bitDepth;
                        final ch = data?.channels;
                        if (bd != null) {
                          children.add(
                            SizedBox(
                              width: colWidth,
                              child: _InfoTile(
                                label: '位深',
                                child: Text(bd.toString(), style: styleContent),
                              ),
                            ),
                          );
                        }
                        if (ch != null) {
                          children.add(
                            SizedBox(
                              width: colWidth,
                              child: _InfoTile(
                                label: '声道',
                                child: Text(ch.toString(), style: styleContent),
                              ),
                            ),
                          );
                        }

                        final items = data?.items ?? [];
                        for (final item in items) {
                          final k = item.key;
                          final v = item.value;
                          final lk = k.trim().toLowerCase();
                          if (lk == 'artist' || lk == 'encoder') continue;
                          children.add(
                            SizedBox(
                              width: colWidth,
                              child: _InfoTile(
                                label: k,
                                child: Text(v, style: styleContent),
                              ),
                            ),
                          );
                        }

                        children.addAll([
                          SizedBox(
                            width: maxWidth,
                            child: const SizedBox.shrink(),
                          ),
                          SizedBox(
                            width: maxWidth,
                            child: _InfoTile(
                              label: '路径',
                              child: Text(audio.path, style: styleContent),
                            ),
                          ),
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: '修改时间',
                              child: Text(
                                DateTime.fromMillisecondsSinceEpoch(
                                        audio.modified * 1000)
                                    .toString()
                                    .substring(0, 19),
                                style: styleContent,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: '创建时间',
                              child: Text(
                                DateTime.fromMillisecondsSinceEpoch(
                                        audio.created * 1000)
                                    .toString()
                                    .substring(0, 19),
                                style: styleContent,
                              ),
                            ),
                          ),
                        ]);

                        return Wrap(
                          spacing: 16,
                          runSpacing: 12,
                          children: children,
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: AppType.body,
            color: scheme.onSurface.withValues(alpha: 0.70),
          ),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}
