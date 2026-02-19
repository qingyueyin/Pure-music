import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/rust/api/utils.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart' as rust_tag_reader;
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

String _formatBytes(int bytes) {
  if (bytes < 1024) return "$bytes B";
  const units = ["KB", "MB", "GB", "TB"];
  double size = bytes.toDouble();
  int unitIndex = -1;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex += 1;
  }
  return "${size.toStringAsFixed(size >= 10 ? 1 : 2)} ${units[unitIndex]}";
}

final Map<String, Future<Map<String, Object?>>> _audioExtraCache = {};

Future<Map<String, Object?>> _getAudioExtra(Audio audio) {
  final key = "${audio.path}|${audio.modified}";
  final existing = _audioExtraCache[key];
  if (existing != null) return existing;
  final future = rust_tag_reader.readAudioExtraMetadata(path: audio.path).then((jsonStr) {
    final decoded = json.decode(jsonStr);
    if (decoded is Map) {
      return Map<String, Object?>.from(decoded);
    }
    return <String, Object?>{};
  }).catchError((_) => <String, Object?>{});
  _audioExtraCache[key] = future;
  return future;
}

class AudioDetailPage extends StatelessWidget {
  const AudioDetailPage({super.key, required this.audio});

  final Audio audio;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final album = AudioLibrary.instance.albumCollection[audio.album]!;
    const space = SizedBox(height: 16.0);

    final styleTitle = TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    );
    final styleContent = TextStyle(fontSize: 14, color: scheme.onSurface);
    final placeholder = Icon(
      Symbols.broken_image,
      color: scheme.onSurface,
      size: 200,
    );

    return Material(
      color: scheme.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 96.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FutureBuilder(
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
                      borderRadius: BorderRadius.circular(8.0),
                      child: Image(
                        image: snapshot.data!,
                        width: 156,
                        height: 156,
                        errorBuilder: (_, __, ___) => placeholder,
                      ),
                    );
                  },
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            "歌名：",
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurface.withValues(alpha: 0.70),
                            ),
                          ),
                          ActionChip(
                            label: Text(
                              audio.title,
                              style: styleTitle.copyWith(fontSize: 15),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: audio.title),
                              );
                              showTextOnSnackBar("已复制歌名");
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            "歌手：",
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurface.withValues(alpha: 0.70),
                            ),
                          ),
                          ...audio.splitedArtists.map((name) {
                            final artist =
                                AudioLibrary.instance.artistCollection[name];
                            if (artist == null) return const SizedBox.shrink();
                            return ActionChip(
                              label: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                softWrap: false,
                              ),
                              onPressed: () => context.push(
                                app_paths.ARTIST_DETAIL_PAGE,
                                extra: artist,
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
                        children: [
                          Text(
                            "专辑：",
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurface.withValues(alpha: 0.70),
                            ),
                          ),
                          ActionChip(
                            label: Text(
                              audio.album,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                            onPressed: () => context.push(
                              app_paths.ALBUM_DETAIL_PAGE,
                              extra: album,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          IconButton(
                            tooltip: "在文件资源管理器中显示",
                            onPressed: () async {
                              final result = await showInExplorer(path: audio.path);
                              if (!result && context.mounted) {
                                showTextOnSnackBar("打开失败");
                              }
                            },
                            icon: const Icon(Symbols.folder_open),
                          ),
                          IconButton(
                            tooltip: "复制路径",
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: audio.path));
                              showTextOnSnackBar("已复制");
                            },
                            icon: const Icon(Symbols.content_copy),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            space,
            LayoutBuilder(
              builder: (context, constraints) {
                final maxWidth = constraints.maxWidth > 960 ? 960.0 : constraints.maxWidth;
                final colCount = maxWidth > 600 ? 3 : 2;
                final colWidth = (maxWidth - (colCount - 1) * 16) / colCount;
                return Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: FutureBuilder<Map<String, Object?>>(
                      future: _getAudioExtra(audio),
                      builder: (context, snapshot) {
                        final data = snapshot.data ?? const <String, Object?>{};

                        final children = <Widget>[
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: "音轨",
                              child: Text(audio.track.toString(), style: styleContent),
                            ),
                          ),
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: "时长",
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
                              label: "码率",
                              child:
                                  Text("${audio.bitrate ?? "-"} kbps", style: styleContent),
                            ),
                          ),
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: "采样率",
                              child: Text("${audio.sampleRate ?? "-"} hz", style: styleContent),
                            ),
                          ),
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: "格式",
                              child: Text(
                                p.extension(audio.path)
                                    .replaceFirst(".", "")
                                    .toUpperCase(),
                                style: styleContent,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: "文件大小",
                              child: Builder(
                                builder: (context) {
                                  final fileSize = data["file_size"];
                                  if (fileSize is num && fileSize.toInt() > 0) {
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
                                        size == null ? "-" : _formatBytes(size),
                                        style: styleContent,
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                          ),
                        ];

                        final bd = data["bit_depth"];
                        final ch = data["channels"];
                        if (bd != null) {
                          children.add(
                            SizedBox(
                              width: colWidth,
                              child: _InfoTile(
                                label: "位深",
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
                                label: "声道",
                                child: Text(ch.toString(), style: styleContent),
                              ),
                            ),
                          );
                        }

                        final List items = (data["items"] as List?) ?? const [];
                        for (final item in items) {
                          if (item is! Map) continue;
                          final k = item["key"];
                          final v = item["value"];
                          if (k is! String || v is! String) continue;
                          final lk = k.trim().toLowerCase();
                          if (lk == "artist" || lk == "encoder") continue;
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
                              label: "路径",
                              child: Text(audio.path, style: styleContent),
                            ),
                          ),
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: "修改时间",
                              child: Text(
                                DateTime.fromMillisecondsSinceEpoch(audio.modified * 1000)
                                    .toString(),
                                style: styleContent,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: colWidth,
                            child: _InfoTile(
                              label: "创建时间",
                              child: Text(
                                DateTime.fromMillisecondsSinceEpoch(audio.created * 1000)
                                    .toString(),
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
            fontSize: 13,
            color: scheme.onSurface.withValues(alpha: 0.70),
          ),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

