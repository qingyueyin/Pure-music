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

final Map<String, Future<rust_tag_reader.AudioExtraMetadata>> _audioExtraCache =
    {};

void _clearAudioExtraCache() {
  _audioExtraCache.clear();
}

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

String? _findItem(List<rust_tag_reader.AudioExtraItem> items, String key) {
  for (final item in items) {
    if (item.key == key) return item.value;
  }
  return null;
}

class _FieldControllers {
  final title = TextEditingController();
  final artist = TextEditingController();
  final album = TextEditingController();
  final genre = TextEditingController();
  final year = TextEditingController();
  final track = TextEditingController();
  final trackTotal = TextEditingController();
  final disc = TextEditingController();
  final discTotal = TextEditingController();
  final composer = TextEditingController();
  final lyricist = TextEditingController();
  final label = TextEditingController();
  final comment = TextEditingController();
  final bpm = TextEditingController();
  final language = TextEditingController();
  final copyright = TextEditingController();
  final license = TextEditingController();

  void initFrom(Audio audio, List<rust_tag_reader.AudioExtraItem> items) {
    title.text = audio.title;
    artist.text = audio.splitedArtists.join('/');
    album.text = audio.album;
    genre.text = _findItem(items, 'genre') ?? '';
    year.text = _findItem(items, 'year') ?? '';
    track.text = audio.track > 0 ? audio.track.toString() : '';
    trackTotal.text = _findItem(items, 'track_total') ?? '';
    disc.text = _findItem(items, 'disc') ?? '';
    discTotal.text = _findItem(items, 'disc_total') ?? '';
    composer.text = _findItem(items, 'composer') ?? '';
    lyricist.text = _findItem(items, 'lyricist') ?? '';
    label.text = _findItem(items, 'label') ?? '';
    comment.text = _findItem(items, 'comment') ?? '';
    bpm.text = _findItem(items, 'bpm') ?? '';
    language.text = _findItem(items, 'language') ?? '';
    copyright.text = _findItem(items, 'copyright') ?? '';
    license.text = _findItem(items, 'license') ?? '';
  }

  void dispose() {
    title.dispose();
    artist.dispose();
    album.dispose();
    genre.dispose();
    year.dispose();
    track.dispose();
    trackTotal.dispose();
    disc.dispose();
    discTotal.dispose();
    composer.dispose();
    lyricist.dispose();
    label.dispose();
    comment.dispose();
    bpm.dispose();
    language.dispose();
    copyright.dispose();
    license.dispose();
  }

  rust_tag_reader.WriteTagPayload buildPayload() {
    return rust_tag_reader.WriteTagPayload(
      title: title.text,
      artist: artist.text,
      album: album.text,
      genre: genre.text,
      year: year.text,
      track: track.text,
      trackTotal: trackTotal.text,
      disc: disc.text,
      discTotal: discTotal.text,
      composer: composer.text,
      lyricist: lyricist.text,
      label: label.text,
      comment: comment.text,
      bpm: bpm.text,
      language: language.text,
      copyright: copyright.text,
      license: license.text,
    );
  }
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
  bool _isEditing = false;
  bool _isSaving = false;
  late _FieldControllers _controllers;
  int _currentTabIndex = 0;
  Future<String?>? _lyricFuture;

  Audio get audio => widget.audio;

  @override
  void initState() {
    super.initState();
    _controllers = _FieldControllers();
  }

  @override
  void dispose() {
    _controllers.dispose();
    super.dispose();
  }

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

  Future<void> _enterEditMode() async {
    final meta = await _getAudioExtra(audio);
    _controllers.initFrom(audio, meta.items);
    setState(() => _isEditing = true);
  }

  void _cancelEdit() {
    setState(() => _isEditing = false);
  }

  Future<void> _saveEdit() async {
    setState(() => _isSaving = true);
    try {
      final payload = _controllers.buildPayload();
      await rust_tag_reader.writeAudioTags(
          path: audio.path, payload: payload, onlyChanged: true);
      _clearAudioExtraCache();
      if (mounted) {
        showTextOnSnackBar('标签已保存，下次扫描库后生效');
        setState(() => _isEditing = false);
      }
    } catch (e) {
      if (mounted) {
        showTextOnSnackBar('保存失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ColoredBox(
      color: scheme.surfaceContainer,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 0),
            child: _buildTabBar(scheme),
          ),
          const SizedBox(height: 16.0),
          Expanded(
            child: IndexedStack(
              index: _currentTabIndex,
              children: [
                _buildInfoTab(scheme),
                _buildLyricTab(scheme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(ColorScheme scheme) {
    final tabs = <(String, IconData)>[
      ('信息', Symbols.info_i),
      ('歌词', Symbols.lyrics),
    ];
    return Wrap(
      spacing: 8.0,
      runSpacing: 8.0,
      children: List.generate(tabs.length, (i) {
        final selected = _currentTabIndex == i;
        return OutlinedButton.icon(
          onPressed: () => setState(() => _currentTabIndex = i),
          icon: Icon(tabs[i].$2, size: 18),
          label: Text(tabs[i].$1),
          style: ButtonStyle(
            foregroundColor: WidgetStatePropertyAll(
              selected
                  ? scheme.onSecondaryContainer
                  : scheme.onSurfaceVariant,
            ),
            backgroundColor: WidgetStatePropertyAll(
              selected
                  ? scheme.secondaryContainer
                  : scheme.surfaceContainerHighest,
            ),
            side: WidgetStatePropertyAll(
              BorderSide(
                color: selected ? scheme.primary : scheme.outline,
              ),
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                  borderRadius: AppRadius.smCircular),
            ),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildInfoTab(ColorScheme scheme) {
    const space = SizedBox(height: 16.0);

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

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 96.0),
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
              final info = _isEditing
                  ? _buildEditInfo(scheme, chipMaxWidth, narrow)
                  : _buildViewInfo(scheme, chipMaxWidth, narrow);
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
                      return _isEditing
                          ? _buildEditGrid(scheme, colWidth, data)
                          : _buildViewGrid(
                              scheme, colWidth, maxWidth, data);
                    },
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLyricTab(ColorScheme scheme) {
    _lyricFuture ??= rust_tag_reader.getLyricFromPath(path: audio.path);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 96.0),
      child: FutureBuilder<String?>(
        future: _lyricFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              ),
            );
          }
          final lyric = snapshot.data;
          if (lyric == null || lyric.trim().isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '未找到内嵌歌词',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: AppType.body,
                  ),
                ),
              ),
            );
          }
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: AppRadius.mdCircular,
            ),
            child: SelectableText(
              lyric,
              style: TextStyle(
                fontSize: AppType.body,
                color: scheme.onSurface,
                height: 1.6,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildViewInfo(
      ColorScheme scheme, double chipMaxWidth, bool narrow) {
    final album = AudioLibrary.instance.albumCollection[audio.album];
    return Column(
      crossAxisAlignment:
          narrow ? CrossAxisAlignment.center : CrossAxisAlignment.start,
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
                  style: TextStyle(
                    fontSize: AppType.sectionTitle,
                    fontWeight: AppType.weightSemibold,
                    color: scheme.onSurface,
                  ).copyWith(fontSize: AppType.subtitle),
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
              tooltip: '编辑标签',
              onPressed: _enterEditMode,
              icon: const Icon(Symbols.edit),
            ),
            IconButton(
              tooltip: '在文件管理器中显示',
              onPressed:
                  _isOpeningInExplorer ? null : _showCurrentAudioInExplorer,
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
              onPressed: _isCopyingPath ? null : _copyCurrentAudioPath,
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
  }

  Widget _buildEditInfo(ColorScheme scheme, double chipMaxWidth, bool narrow) {
    Widget chipField({
      required TextEditingController controller,
      String? hint,
      double? width,
    }) {
      return SizedBox(
        width: width,
        child: TextField(
          controller: controller,
          style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            filled: true,
            fillColor: scheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: AppRadius.smCircular,
              borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.5)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: AppRadius.smCircular,
              borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.3)),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment:
          narrow ? CrossAxisAlignment.center : CrossAxisAlignment.start,
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
              child: chipField(
                controller: _controllers.title,
                hint: '歌名',
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
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: chipMaxWidth),
              child: chipField(
                controller: _controllers.artist,
                hint: '多个用 / 分隔',
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
              '专辑：',
              style: TextStyle(
                fontSize: AppType.body,
                color: scheme.onSurface.withValues(alpha: 0.70),
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: chipMaxWidth),
              child: chipField(
                controller: _controllers.album,
                hint: '专辑名',
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
            OutlinedButton.icon(
              onPressed: _isSaving ? null : _cancelEdit,
              icon: const Icon(Symbols.close, size: 16),
              label: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: _isSaving ? null : _saveEdit,
              icon: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Symbols.check, size: 16),
              label: Text(_isSaving ? '保存中…' : '保存'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildViewGrid(ColorScheme scheme, double colWidth, double maxWidth,
      rust_tag_reader.AudioExtraMetadata? data) {
    final children = <Widget>[
      SizedBox(
        width: colWidth,
        child: _InfoTile(
          label: '音轨',
          child:
              Text(audio.track.toString(), style: TextStyle(fontSize: AppType.body, color: scheme.onSurface)),
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
            style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
          ),
        ),
      ),
      SizedBox(
        width: colWidth,
        child: _InfoTile(
          label: '码率',
          child: Text("${audio.bitrate ?? "-"} kbps",
              style: TextStyle(fontSize: AppType.body, color: scheme.onSurface)),
        ),
      ),
      SizedBox(
        width: colWidth,
        child: _InfoTile(
          label: '采样率',
          child: Text("${audio.sampleRate ?? "-"} hz",
              style: TextStyle(fontSize: AppType.body, color: scheme.onSurface)),
        ),
      ),
      SizedBox(
        width: colWidth,
        child: _InfoTile(
          label: '格式',
          child: Text(
            p.extension(audio.path).replaceFirst('.', '').toUpperCase(),
            style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
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
                  style:
                      TextStyle(fontSize: AppType.body, color: scheme.onSurface),
                );
              }
              return FutureBuilder<FileStat>(
                future: File(audio.path).stat(),
                builder: (context, snapshot) {
                  final size = snapshot.data?.size;
                  return Text(
                    size == null ? '-' : _formatBytes(size),
                    style:
                        TextStyle(fontSize: AppType.body, color: scheme.onSurface),
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
            child:
                Text(bd.toString(), style: TextStyle(fontSize: AppType.body, color: scheme.onSurface)),
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
            child:
                Text(ch.toString(), style: TextStyle(fontSize: AppType.body, color: scheme.onSurface)),
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
            child: Text(v,
                style: TextStyle(fontSize: AppType.body, color: scheme.onSurface)),
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
          child: Text(audio.path,
              style: TextStyle(fontSize: AppType.body, color: scheme.onSurface)),
        ),
      ),
      SizedBox(
        width: colWidth,
        child: _InfoTile(
          label: '修改时间',
          child: Text(
            DateTime.fromMillisecondsSinceEpoch(audio.modified * 1000)
                .toString()
                .substring(0, 19),
            style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
          ),
        ),
      ),
      SizedBox(
        width: colWidth,
        child: _InfoTile(
          label: '创建时间',
          child: Text(
            DateTime.fromMillisecondsSinceEpoch(audio.created * 1000)
                .toString()
                .substring(0, 19),
            style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
          ),
        ),
      ),
    ]);

    return Wrap(
      spacing: 16,
      runSpacing: 12,
      children: children,
    );
  }

  InputDecoration _chipDecoration(ColorScheme scheme, [String? hint]) {
    return InputDecoration(
      isDense: true,
      hintText: hint,
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: AppRadius.smCircular,
        borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.5)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppRadius.smCircular,
        borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.3)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    );
  }

  Widget _buildEditGrid(ColorScheme scheme, double colWidth,
      rust_tag_reader.AudioExtraMetadata? data) {
    final editFields = <String, TextEditingController>{
      'genre': _controllers.genre,
      'year': _controllers.year,
      'composer': _controllers.composer,
      'lyricist': _controllers.lyricist,
      'label': _controllers.label,
      'comment': _controllers.comment,
      'bpm': _controllers.bpm,
      'language': _controllers.language,
      'copyright': _controllers.copyright,
      'license': _controllers.license,
    };

    final children = <Widget>[
      _InfoTile(
        label: '音轨',
        child: SizedBox(
          width: colWidth - 16,
          child: TextField(
            controller: _controllers.track,
            style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
            decoration: _chipDecoration(scheme, '数字'),
          ),
        ),
      ),
      _InfoTile(
        label: '时长',
        child: Text(
          Duration(
            milliseconds: (audio.duration * 1000).toInt(),
          ).toStringHMMSS(),
          style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
        ),
      ),
      _InfoTile(
        label: '码率',
        child: Text("${audio.bitrate ?? "-"} kbps",
            style: TextStyle(fontSize: AppType.body, color: scheme.onSurface)),
      ),
      _InfoTile(
        label: '采样率',
        child: Text("${audio.sampleRate ?? "-"} hz",
            style: TextStyle(fontSize: AppType.body, color: scheme.onSurface)),
      ),
      _InfoTile(
        label: '格式',
        child: Text(
          p.extension(audio.path).replaceFirst('.', '').toUpperCase(),
          style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
        ),
      ),
      _InfoTile(
        label: '文件大小',
        child: Builder(
          builder: (context) {
            final fileSize = data?.fileSize;
            if (fileSize != null && fileSize > BigInt.zero) {
              return Text(
                _formatBytes(fileSize.toInt()),
                style:
                    TextStyle(fontSize: AppType.body, color: scheme.onSurface),
              );
            }
            return FutureBuilder<FileStat>(
              future: File(audio.path).stat(),
              builder: (context, snapshot) {
                final size = snapshot.data?.size;
                return Text(
                  size == null ? '-' : _formatBytes(size),
                  style:
                      TextStyle(fontSize: AppType.body, color: scheme.onSurface),
                );
              },
            );
          },
        ),
      ),
    ];

    final bd = data?.bitDepth;
    final ch = data?.channels;
    if (bd != null) {
      children.add(
        _InfoTile(
          label: '位深',
          child: Text(bd.toString(),
              style: TextStyle(fontSize: AppType.body, color: scheme.onSurface)),
        ),
      );
    }
    if (ch != null) {
      children.add(
        _InfoTile(
          label: '声道',
          child: Text(ch.toString(),
              style: TextStyle(fontSize: AppType.body, color: scheme.onSurface)),
        ),
      );
    }

    children.add(_InfoTile(
      label: '总音轨数',
      child: SizedBox(
        width: colWidth - 16,
        child: TextField(
          controller: _controllers.trackTotal,
          style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
          decoration: _chipDecoration(scheme, '数字'),
        ),
      ),
    ));
    children.add(_InfoTile(
      label: '碟号',
      child: SizedBox(
        width: colWidth - 16,
        child: TextField(
          controller: _controllers.disc,
          style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
          decoration: _chipDecoration(scheme, '数字'),
        ),
      ),
    ));
    children.add(_InfoTile(
      label: '总碟数',
      child: SizedBox(
        width: colWidth - 16,
        child: TextField(
          controller: _controllers.discTotal,
          style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
          decoration: _chipDecoration(scheme, '数字'),
        ),
      ),
    ));

    for (final entry in editFields.entries) {
      children.add(
        _InfoTile(
          label: entry.key,
          child: SizedBox(
            width: colWidth - 16,
            child: TextField(
              controller: entry.value,
              style:
                  TextStyle(fontSize: AppType.body, color: scheme.onSurface),
              decoration: _chipDecoration(scheme),
            ),
          ),
        ),
      );
    }

    children.addAll([
      _InfoTile(
        label: '路径',
        child: Text(audio.path,
            style: TextStyle(fontSize: AppType.body, color: scheme.onSurface)),
      ),
      _InfoTile(
        label: '修改时间',
        child: Text(
          DateTime.fromMillisecondsSinceEpoch(audio.modified * 1000)
              .toString()
              .substring(0, 19),
          style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
        ),
      ),
      _InfoTile(
        label: '创建时间',
        child: Text(
          DateTime.fromMillisecondsSinceEpoch(audio.created * 1000)
              .toString()
              .substring(0, 19),
          style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
        ),
      ),
    ]);

    return Wrap(
      spacing: 16,
      runSpacing: 12,
      children: children,
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




