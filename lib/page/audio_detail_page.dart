import 'dart:io' as io;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/matcher.dart' hide logger;
import 'package:pure_music/core/mouse_back_exit.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lrc_serializer.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart' as rust_tag_reader;
import 'package:pure_music/native/rust/api/utils.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/services/online_lyric/api/net_lyric_api.dart'
    as net_api;

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
      .catchError(
        (_) => rust_tag_reader.AudioExtraMetadata(
          extension_: '',
          fileSize: BigInt.zero,
          channels: null,
          bitDepth: null,
          items: [],
          replaygainTrackGain: null,
          replaygainTrackPeak: null,
          replaygainAlbumGain: null,
          replaygainAlbumPeak: null,
        ),
      );
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
  // 编辑模式下的封面预览字节（null = 无变化，空列表 = 移除封面）
  Uint8List? _pendingCoverBytes;

  Audio get audio => widget.audio;

  @override
  void initState() {
    super.initState();
    _controllers = _FieldControllers();
  }

  @override
  void dispose() {
    MouseBackExit.unregister(_exitEditOnBack);
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
    setState(() {
      _isEditing = true;
      _pendingCoverBytes = null;
    });
    MouseBackExit.register(_exitEditOnBack);
  }

  bool _exitEditOnBack() {
    if (!_isEditing) return false;
    _cancelEdit();
    return true;
  }

  void _cancelEdit() {
    MouseBackExit.unregister(_exitEditOnBack);
    setState(() {
      _isEditing = false;
      _pendingCoverBytes = null;
    });
  }

  Future<void> _saveEdit() async {
    setState(() => _isSaving = true);
    var coverWritten = false;
    try {
      if (_pendingCoverBytes != null) {
        await rust_tag_reader.writeAudioCover(
          path: audio.path,
          bytes: _pendingCoverBytes!,
        );
        audio.evictCoverCache();
        coverWritten = true;
      }
      final payload = _controllers.buildPayload();
      await rust_tag_reader.writeAudioTags(
        path: audio.path,
        payload: payload,
        onlyChanged: true,
      );
      _clearAudioExtraCache();
      AudioLibrary.instance.updateAudioTags(
        audio,
        title: _controllers.title.text,
        artist: _controllers.artist.text,
        album: _controllers.album.text,
        track: int.tryParse(_controllers.track.text.trim()) ?? 0,
        disc: int.tryParse(_controllers.disc.text.trim()),
      );
      if (mounted) {
        showTextOnSnackBar('标签已保存');
        _cancelEdit();
      }
    } catch (e, trace) {
      logger.e('保存音频标签失败', error: e, stackTrace: trace);
      if (mounted) {
        showTextOnSnackBar(
          coverWritten ? '封面已写入，标签保存失败，请查看日志' : '保存标签失败，请查看日志',
        );
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

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 0),
          child: _buildTabBar(scheme),
        ),
        const SizedBox(height: 16.0),
        Expanded(
          child: DirectionalTabView(
            index: _currentTabIndex,
            children: [_buildInfoTab(scheme), _buildLyricTab(scheme)],
          ),
        ),
      ],
    );
  }

  Widget _buildTabBar(ColorScheme scheme) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<int>(
        segments: const [
          ButtonSegment<int>(
            value: 0,
            icon: Icon(Symbols.info_i, size: 18),
            label: Text('信息'),
          ),
          ButtonSegment<int>(
            value: 1,
            icon: Icon(Symbols.lyrics, size: 18),
            label: Text('歌词'),
          ),
        ],
        selected: {_currentTabIndex},
        showSelectedIcon: false,
        onSelectionChanged: (selection) {
          setState(() => _currentTabIndex = selection.first);
        },
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant;
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? scheme.secondaryContainer
                : scheme.surfaceContainerHighest;
          }),
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outlineVariant),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
          ),
        ),
      ),
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
      padding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 120.0),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final narrow = constraints.maxWidth < 560.0;
                  final cover = _isEditing
                      ? _buildEditCover(scheme, placeholder)
                      : FutureBuilder(
                          future: audio.mediumCover,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState !=
                                ConnectionState.done) {
                              return const SizedBox(
                                width: 156,
                                height: 156,
                                child:
                                    Center(child: CircularProgressIndicator()),
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
                                errorBuilder: (_, _, _) => placeholder,
                              ),
                            );
                          },
                        );
                  final info = _isEditing
                      ? _buildEditInfo(scheme)
                      : _buildViewInfo(scheme);
                  final constrainedInfo = ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: info,
                  );
                  if (narrow) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        cover,
                        const SizedBox(height: 16.0),
                        constrainedInfo,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      cover,
                      const SizedBox(width: 16),
                      Expanded(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: constrainedInfo,
                        ),
                      ),
                    ],
                  );
                },
              ),
              space,
              LayoutBuilder(
                builder: (context, constraints) {
                  return FutureBuilder<rust_tag_reader.AudioExtraMetadata>(
                    future: _getAudioExtra(audio),
                    builder: (context, snapshot) {
                      final data = snapshot.data;
                      return _isEditing
                          ? _buildEditSections(
                              scheme,
                              constraints.maxWidth,
                              data,
                            )
                          : _buildViewSections(
                              scheme,
                              constraints.maxWidth,
                              data,
                            );
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLyricTab(ColorScheme scheme) {
    _lyricFuture ??= rust_tag_reader.getLyricFromPath(path: audio.path);
    return Stack(
      children: [
        SingleChildScrollView(
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
        ),
        Positioned(
          top: 0,
          right: 0,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: IconButton.filledTonal(
              tooltip: '编辑内嵌歌词',
              onPressed: () => _showLyricsEditDialog(context, scheme),
              style: IconButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
              ),
              icon: const Icon(Symbols.edit, size: 18),
            ),
          ),
        ),
      ],
    );
  }

  void _showLyricsEditDialog(BuildContext context, ColorScheme scheme) {
    showDialog(
      context: context,
      builder: (_) => _LyricsEditDialog(audio: audio),
    );
  }

  Widget _buildViewInfo(ColorScheme scheme) {
    final album = AudioLibrary.instance.albumCollection[audio.album];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                audio.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.hero,
                  fontWeight: AppType.weightBold,
                  color: scheme.onSurface,
                  height: 1.2,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '复制歌名',
              visualDensity: VisualDensity.compact,
              onPressed: _isCopyingTitle ? null : _copyCurrentAudioTitle,
              icon: _isCopyingTitle
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Symbols.content_copy, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 4,
          runSpacing: 2,
          children: audio.splitedArtists.map((name) {
            final artist = AudioLibrary.instance.artistCollection[name];
            return TextButton(
              onPressed: artist == null
                  ? null
                  : () => context.push(
                      app_paths.ARTIST_DETAIL_PAGE,
                      extra: artist,
                    ),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 32),
                shape: RoundedRectangleBorder(
                  borderRadius: AppRadius.smCircular,
                ),
              ),
              child: Text(name),
            );
          }).toList(),
        ),
        TextButton.icon(
          onPressed: album == null
              ? null
              : () => context.push(app_paths.ALBUM_DETAIL_PAGE, extra: album),
          icon: const Icon(Symbols.album, size: 18),
          label: Text(
            audio.album,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          style: TextButton.styleFrom(
            foregroundColor: scheme.onSurfaceVariant,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: const Size(0, 32),
            shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            IconButton.filledTonal(
              tooltip: '编辑标签',
              onPressed: _enterEditMode,
              style: _headerActionStyle(),
              icon: const Icon(Symbols.edit),
            ),
            IconButton.filledTonal(
              tooltip: '在文件管理器中显示',
              onPressed: _isOpeningInExplorer
                  ? null
                  : _showCurrentAudioInExplorer,
              style: _headerActionStyle(),
              icon: _isOpeningInExplorer
                  ? const SizedBox(
                      width: 20.0,
                      height: 20.0,
                      child: CircularProgressIndicator(strokeWidth: 2.0),
                    )
                  : const Icon(Symbols.folder_open),
            ),
            IconButton.filledTonal(
              tooltip: '复制路径',
              onPressed: _isCopyingPath ? null : _copyCurrentAudioPath,
              style: _headerActionStyle(),
              icon: _isCopyingPath
                  ? const SizedBox(
                      width: 20.0,
                      height: 20.0,
                      child: CircularProgressIndicator(strokeWidth: 2.0),
                    )
                  : const Icon(Symbols.content_copy),
            ),
          ],
        ),
      ],
    );
  }

  ButtonStyle _headerActionStyle() {
    return IconButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
    );
  }

  Widget _buildEditCover(ColorScheme scheme, Widget placeholder) {
    final pending = _pendingCoverBytes;
    Widget coverWidget;
    if (pending != null) {
      coverWidget = ClipRRect(
        borderRadius: AppRadius.mdCircular,
        child: Image.memory(
          pending,
          width: 156,
          height: 156,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => placeholder,
        ),
      );
    } else {
      coverWidget = FutureBuilder(
        future: audio.mediumCover,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return SizedBox(
              width: 156,
              height: 156,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: AppRadius.mdCircular,
                ),
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
              errorBuilder: (_, _, _) => placeholder,
            ),
          );
        },
      );
    }
    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        coverWidget,
        Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CoverActionButton(
                tooltip: '搜索封面',
                icon: Symbols.image_search,
                onPressed: () => _showCoverSearchDialog(context),
              ),
              const SizedBox(width: 4),
              _CoverActionButton(
                tooltip: '选择本地图片',
                icon: Symbols.folder_open,
                onPressed: _pickLocalCover,
              ),
              if (_hasSameAlbumCover()) ...[
                const SizedBox(width: 4),
                _CoverActionButton(
                  tooltip: '使用同专辑封面',
                  icon: Symbols.album,
                  onPressed: _useSameAlbumCover,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  bool _hasSameAlbumCover() {
    final album = AudioLibrary.instance.albumCollection[audio.album];
    if (album == null) return false;
    return album.works.any(
      (a) => a.path != audio.path && a.smallCoverBytes != null,
    );
  }

  Future<void> _pickLocalCover() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final bytes = result.files.single.bytes;
    if (bytes == null) return;
    setState(() => _pendingCoverBytes = bytes);
  }

  Future<void> _useSameAlbumCover() async {
    final album = AudioLibrary.instance.albumCollection[audio.album];
    if (album == null) return;
    final source = album.works.firstWhere(
      (a) => a.path != audio.path && a.smallCoverBytes != null,
      orElse: () => audio,
    );
    if (source.path == audio.path) return;
    final bytes = source.smallCoverBytes;
    if (bytes == null || !mounted) return;
    setState(() => _pendingCoverBytes = Uint8List.fromList(bytes));
  }

  Future<void> _showCoverSearchDialog(BuildContext context) async {
    final bytes = await showDialog<Uint8List>(
      context: context,
      builder: (_) => _CoverSearchDialog(audio: audio),
    );
    if (!mounted || bytes == null) return;
    setState(() => _pendingCoverBytes = bytes);
  }

  Widget _buildEditInfo(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DetailTextField(
          label: '歌名',
          controller: _controllers.title,
          decoration: _chipDecoration(scheme),
        ),
        const SizedBox(height: 10),
        _DetailTextField(
          label: '歌手',
          controller: _controllers.artist,
          decoration: _chipDecoration(scheme, '多个用 / 分隔'),
        ),
        const SizedBox(height: 10),
        _DetailTextField(
          label: '专辑',
          controller: _controllers.album,
          decoration: _chipDecoration(scheme),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.start,
          children: [
            OutlinedButton.icon(
              onPressed: _isSaving ? null : _cancelEdit,
              icon: const Icon(Symbols.close, size: 16),
              label: const Text('取消'),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: AppRadius.smCircular,
                ),
              ),
            ),
            FilledButton.icon(
              onPressed: _isSaving ? null : _saveEdit,
              icon: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Symbols.check, size: 16),
              label: Text(_isSaving ? '保存中…' : '保存'),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: AppRadius.smCircular,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildViewSections(
    ColorScheme scheme,
    double maxWidth,
    rust_tag_reader.AudioExtraMetadata? data,
  ) {
    final tagFields = <Widget>[
      _DetailField(label: '音轨', value: audio.track.toString()),
    ];
    for (final item in data?.items ?? const []) {
      final key = item.key.trim();
      final normalizedKey = key.toLowerCase();
      if (normalizedKey == 'artist' ||
          normalizedKey == 'encoder' ||
          normalizedKey == 'encoded_by' ||
          normalizedKey == 'encoder_settings') {
        continue;
      }
      tagFields.add(_DetailField(label: key, value: item.value));
    }

    final technicalFields = <Widget>[
      _DetailField(
        label: '时长',
        value: Duration(
          milliseconds: (audio.duration * 1000).toInt(),
        ).toStringHMMSS(),
      ),
      _DetailField(
        label: '码率',
        value: audio.bitrate == null ? '-' : '${audio.bitrate} kbps',
      ),
      _DetailField(
        label: '采样率',
        value: audio.sampleRate == null ? '-' : '${audio.sampleRate} Hz',
      ),
      if (data?.bitDepth != null)
        _DetailField(label: '位深', value: '${data!.bitDepth} bit'),
      if (data?.channels != null)
        _DetailField(label: '声道', value: data!.channels.toString()),
    ];

    return _buildViewSectionLayout(maxWidth, [
      _DetailSection(
        title: '音乐标签',
        icon: Symbols.music_note,
        children: tagFields,
      ),
      _DetailSection(
        title: '音频参数',
        icon: Symbols.graphic_eq,
        children: technicalFields,
      ),
      _DetailSection(
        title: '文件信息',
        icon: Symbols.folder,
        children: [
          _DetailField(
            label: '格式',
            value: p.extension(audio.path).replaceFirst('.', '').toUpperCase(),
          ),
          _DetailField(label: '文件大小', child: _buildFileSize(data)),
          _DetailField(label: '路径', value: audio.path, allowWrap: true),
          _DetailField(label: '修改时间', value: _formatTimestamp(audio.modified)),
          _DetailField(label: '创建时间', value: _formatTimestamp(audio.created)),
        ],
      ),
    ]);
  }

  Widget _buildViewSectionLayout(double maxWidth, List<Widget> sections) {
    final columnCount = maxWidth >= 900
        ? 3
        : maxWidth >= 600
        ? 2
        : 1;
    final sectionWidth = (maxWidth - (columnCount - 1) * 16) / columnCount;
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        for (final section in sections)
          SizedBox(width: sectionWidth, child: section),
      ],
    );
  }

  Widget _buildFileSize(rust_tag_reader.AudioExtraMetadata? data) {
    final fileSize = data?.fileSize;
    if (fileSize != null && fileSize > BigInt.zero) {
      return Text(_formatBytes(fileSize.toInt()));
    }
    return FutureBuilder<io.FileStat>(
      future: io.File(audio.path).stat(),
      builder: (context, snapshot) {
        final size = snapshot.data?.size;
        return Text(size == null ? '-' : _formatBytes(size));
      },
    );
  }

  String _formatTimestamp(int seconds) {
    return DateTime.fromMillisecondsSinceEpoch(
      seconds * 1000,
    ).toString().substring(0, 19);
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

  Widget _buildEditSections(
    ColorScheme scheme,
    double maxWidth,
    rust_tag_reader.AudioExtraMetadata? data,
  ) {
    Widget editField(
      String label,
      TextEditingController controller, {
      String? hint,
    }) {
      return _DetailTextField(
        label: label,
        controller: controller,
        decoration: _chipDecoration(scheme, hint),
      );
    }

    final tagSection = _DetailSection(
      title: '音乐标签',
      icon: Symbols.music_note,
      columns: maxWidth >= 640 ? 2 : 1,
      children: [
        editField('音轨', _controllers.track, hint: '数字'),
        editField('总音轨数', _controllers.trackTotal, hint: '数字'),
        editField('碟号', _controllers.disc, hint: '数字'),
        editField('总碟数', _controllers.discTotal, hint: '数字'),
        editField('流派', _controllers.genre),
        editField('年份', _controllers.year),
        editField('作曲', _controllers.composer, hint: '多个用 / 分隔'),
        editField('作词', _controllers.lyricist, hint: '多个用 / 分隔'),
        editField('厂牌', _controllers.label),
        editField('注释', _controllers.comment),
        editField('BPM', _controllers.bpm),
        editField('语言', _controllers.language),
        editField('版权', _controllers.copyright),
        editField('许可', _controllers.license),
      ],
    );
    final technicalSection = _DetailSection(
      title: '音频参数',
      icon: Symbols.graphic_eq,
      children: [
        _DetailField(
          label: '时长',
          value: Duration(
            milliseconds: (audio.duration * 1000).toInt(),
          ).toStringHMMSS(),
        ),
        _DetailField(
          label: '码率',
          value: audio.bitrate == null ? '-' : '${audio.bitrate} kbps',
        ),
        _DetailField(
          label: '采样率',
          value: audio.sampleRate == null ? '-' : '${audio.sampleRate} Hz',
        ),
        if (data?.bitDepth != null)
          _DetailField(label: '位深', value: '${data!.bitDepth} bit'),
        if (data?.channels != null)
          _DetailField(label: '声道', value: data!.channels.toString()),
      ],
    );
    final fileSection = _DetailSection(
      title: '文件信息',
      icon: Symbols.folder,
      children: [
        _DetailField(
          label: '格式',
          value: p.extension(audio.path).replaceFirst('.', '').toUpperCase(),
        ),
        _DetailField(label: '文件大小', child: _buildFileSize(data)),
        _DetailField(label: '路径', value: audio.path, allowWrap: true),
        _DetailField(label: '修改时间', value: _formatTimestamp(audio.modified)),
        _DetailField(label: '创建时间', value: _formatTimestamp(audio.created)),
      ],
    );

    if (maxWidth >= 840) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 2, child: tagSection),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              children: [
                technicalSection,
                const SizedBox(height: 16),
                fileSection,
              ],
            ),
          ),
        ],
      );
    }
    if (maxWidth >= 640) {
      return Column(
        children: [
          tagSection,
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: technicalSection),
              const SizedBox(width: 16),
              Expanded(child: fileSection),
            ],
          ),
        ],
      );
    }
    return Column(
      children: [
        tagSection,
        const SizedBox(height: 16),
        technicalSection,
        const SizedBox(height: 16),
        fileSection,
      ],
    );
  }
}

class _CoverActionButton extends StatelessWidget {
  const _CoverActionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: AppRadius.smCircular,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.88),
            borderRadius: AppRadius.smCircular,
          ),
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Icon(icon, size: 16, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.title,
    required this.icon,
    required this.children,
    this.columns = 1,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.48),
        borderRadius: AppRadius.smCircular,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: AppType.sectionTitle,
                    fontWeight: AppType.weightSemibold,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (columns == 1)
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) Divider(height: 17, color: scheme.outlineVariant),
                children[i],
              ]
            else
              for (var i = 0; i < children.length; i += 2) ...[
                if (i > 0) Divider(height: 17, color: scheme.outlineVariant),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: children[i]),
                    const SizedBox(width: 16),
                    Expanded(
                      child: i + 1 < children.length
                          ? children[i + 1]
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ],
          ],
        ),
      ),
    );
  }
}

class _DetailField extends StatelessWidget {
  const _DetailField({
    required this.label,
    this.value,
    this.child,
    this.allowWrap = false,
  }) : assert(value != null || child != null);

  final String label;
  final String? value;
  final Widget? child;
  final bool allowWrap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 3),
          DefaultTextStyle(
            style: TextStyle(
              fontSize: AppType.body,
              color: scheme.onSurface,
              height: 1.35,
            ),
            child:
                child ??
                Text(
                  value!.trim().isEmpty ? '-' : value!,
                  maxLines: allowWrap ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                ),
          ),
        ],
      ),
    );
  }
}

class _DetailTextField extends StatelessWidget {
  const _DetailTextField({
    required this.label,
    required this.controller,
    required this.decoration,
  });

  final String label;
  final TextEditingController controller;
  final InputDecoration decoration;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: AppType.caption,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
          decoration: decoration,
        ),
      ],
    );
  }
}

class _LyricsEditDialog extends StatefulWidget {
  const _LyricsEditDialog({required this.audio});

  final Audio audio;

  @override
  State<_LyricsEditDialog> createState() => _LyricsEditDialogState();
}

class _LyricsEditDialogState extends State<_LyricsEditDialog> {
  late final TextEditingController _ctrl;
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController();
    _loadEmbeddedLyric();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadEmbeddedLyric() async {
    try {
      final lyric = await rust_tag_reader.getLyricFromPath(path: widget.audio.path);
      if (!mounted) return;
      setState(() {
        _ctrl.text = lyric ?? '';
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      await rust_tag_reader.writeLyricToPath(
        path: widget.audio.path,
        lyric: _ctrl.text,
      );
      _refreshNowPlayingLyricIfCurrent(widget.audio.path);
      if (mounted) {
        Navigator.pop(context);
        showTextOnSnackBar('歌词已写入标签', variant: ToastVariant.success);
      }
    } catch (e, trace) {
      logger.e('写入歌词标签失败', error: e, stackTrace: trace);
      if (mounted) {
        showTextOnSnackBar('写入标签失败，请查看日志', variant: ToastVariant.error);
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _fetchFromNet() async {
    final result = await showDialog<_NetFetchResult>(
      context: context,
      builder: (_) => _FetchLyricFromNetDialog(audio: widget.audio),
    );
    if (!mounted || result == null) return;
    if (result.written) {
      Navigator.pop(context);
      showTextOnSnackBar('歌词已写入标签', variant: ToastVariant.success);
    } else if (result.text.isNotEmpty) {
      setState(() => _ctrl.text = result.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('编辑内嵌歌词')),
          IconButton(
            tooltip: '从网络获取',
            icon: const Icon(Symbols.cloud_download, size: 20),
            onPressed: _isLoading ? null : _fetchFromNet,
          ),
        ],
      ),
      content: SizedBox(
        width: 500,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.audio.title} - ${widget.audio.artist}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : TextField(
                      controller: _ctrl,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: TextStyle(
                        fontSize: AppType.body,
                        color: scheme.onSurface,
                      ),
                      decoration: const InputDecoration(
                        hintText: '粘贴或输入歌词，支持 LRC / 增强 LRC / QRC / YRC / KRC',
                        alignLabelWithHint: true,
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ],
    );
  }
}

enum _LyricNetSource { qq, ne, kugou }

class _FetchLyricFromNetDialog extends StatefulWidget {
  const _FetchLyricFromNetDialog({required this.audio});

  final Audio audio;

  @override
  State<_FetchLyricFromNetDialog> createState() => _FetchLyricFromNetDialogState();
}

class _FetchLyricFromNetDialogState extends State<_FetchLyricFromNetDialog> {
  late final TextEditingController _searchCtrl;
  _LyricNetSource _activeSource = _LyricNetSource.qq;
  List<_LyricSearchItem> _results = [];
  bool _isSearching = false;
  bool _isFetching = false;
  _LyricSearchItem? _fetchingItem;

  @override
  void initState() {
    super.initState();
    final query = widget.audio.artist.isNotEmpty
        ? '${widget.audio.title} ${widget.audio.artist}'
        : widget.audio.title;
    _searchCtrl = TextEditingController(text: query);
    _search();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _isSearching = true;
      _results = [];
    });
    try {
      final results = await _searchSource(query, _activeSource);
      if (!mounted) return;
      setState(() {
        _results = results;
        _isSearching = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  Future<List<_LyricSearchItem>> _searchSource(
    String query,
    _LyricNetSource source,
  ) async {
    return switch (source) {
      _LyricNetSource.qq => (await net_api.qqSearchLyric(keyword: query))
          .map((e) => _LyricSearchItem(
                source: source,
                id: e.id,
                title: e.title,
                artist: e.artist,
                album: e.album,
                extras: {'id': e.id, 'mid': e.mid},
              ))
          .toList(),
      _LyricNetSource.ne => (await net_api.neSearchLyric(keyword: query))
          .map((e) => _LyricSearchItem(
                source: source,
                id: e.id,
                title: e.title,
                artist: e.artist,
                album: e.album,
              ))
          .toList(),
      _LyricNetSource.kugou => (await net_api.kgSearchLyric(keyword: query))
          .map((e) => _LyricSearchItem(
                source: source,
                id: e.hash,
                title: e.title,
                artist: e.artist,
                album: e.album,
                extras: {'hash': e.hash},
              ))
          .toList(),
    };
  }

  Future<void> _selectResult(
    _LyricSearchItem item, {
    bool writeDirectly = false,
  }) async {
    if (_isFetching) return;
    setState(() {
      _isFetching = true;
      _fetchingItem = item;
    });
    try {
      final text = await _fetchRawLyric(item);
      if (!mounted) return;
      if (text == null || text.isEmpty) {
        showTextOnSnackBar('歌词获取失败', variant: ToastVariant.error);
        return;
      }
      if (writeDirectly) {
        await rust_tag_reader.writeLyricToPath(
          path: widget.audio.path,
          lyric: text,
        );
        _refreshNowPlayingLyricIfCurrent(widget.audio.path);
        if (!mounted) return;
        Navigator.pop(context, _NetFetchResult(text, written: true));
      } else {
        Navigator.pop(context, _NetFetchResult(text));
      }
    } catch (e, trace) {
      logger.e('获取或写入歌词失败', error: e, stackTrace: trace);
      if (mounted) {
        showTextOnSnackBar('操作失败，请查看日志', variant: ToastVariant.error);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isFetching = false;
          _fetchingItem = null;
        });
      }
    }
  }

  Future<String?> _fetchRawLyric(_LyricSearchItem item) async {
    final lyric = switch (item.source) {
      _LyricNetSource.qq => await getOnlineLyric(
        qqSongId: item.extras['id'] ?? item.id,
        title: widget.audio.title,
        album: widget.audio.album,
        artist: widget.audio.artist,
        durationSec: widget.audio.duration.toInt(),
      ),
      _LyricNetSource.ne => await getOnlineLyric(
        neSongId: int.tryParse(item.id),
      ),
      _LyricNetSource.kugou => await getOnlineLyric(
        kugouSongHash: item.extras['hash'] ?? item.id,
      ),
    };
    if (lyric == null || lyric.lines.isEmpty) return null;
    final settings = AppSettings.instance;
    return serializeLyricToLrc(
      lyric,
      wordFormat: settings.lyricTagWordFormat,
      includeTranslation: settings.lyricTagIncludeTranslation,
      includeRomanization: settings.lyricTagIncludeRomanization,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 384, maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '从网络获取歌词',
                    style: TextStyle(
                      fontSize: AppType.sectionTitle,
                      fontWeight: AppType.weightBold,
                      color: scheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Symbols.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      autofocus: true,
                      style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
                      decoration: const InputDecoration(
                        hintText: '输入歌曲名或歌手...',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '搜索',
                    icon: _isSearching
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Symbols.search, size: 20),
                    onPressed: _isSearching ? null : _search,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _buildSourceTab(_LyricNetSource.qq, 'QQ'),
                  const SizedBox(width: 8),
                  _buildSourceTab(_LyricNetSource.ne, '网易'),
                  const SizedBox(width: 8),
                  _buildSourceTab(_LyricNetSource.kugou, '酷狗'),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 280,
                child: _isSearching
                    ? const Center(child: CircularProgressIndicator())
                    : _results.isEmpty
                        ? Center(
                            child: Text(
                              '无结果',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: AppType.body,
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _results.length,
                            itemBuilder: (context, index) {
                              final item = _results[index];
                              final isFetching = _fetchingItem == item;
                              return ListTile(
                                dense: true,
                                title: Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppType.body,
                                    color: scheme.onSurface,
                                  ),
                                ),
                                subtitle: Text(
                                  '${item.artist}${item.album.isNotEmpty ? ' · ${item.album}' : ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppType.caption,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                trailing: isFetching
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : IconButton(
                                        tooltip: '直接写入标签',
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(
                                          Symbols.task_alt,
                                          size: 18,
                                        ),
                                        onPressed: () =>
                                            _selectResult(
                                              item,
                                              writeDirectly: true,
                                            ),
                                      ),
                                onTap: isFetching
                                    ? null
                                    : () => _selectResult(item),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSourceTab(_LyricNetSource source, String label) {
    final isActive = _activeSource == source;
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () {
        if (_activeSource == source) return;
        setState(() {
          _activeSource = source;
          _results = [];
        });
        _search();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? scheme.primaryContainer : Colors.transparent,
          borderRadius: AppRadius.smCircular,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppType.caption,
            color: isActive
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
            fontWeight: isActive ? AppType.weightBold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// 写入的是当前播放歌曲时，刷新播放页歌词缓存
void _refreshNowPlayingLyricIfCurrent(String audioPath) {
  final nowPlaying = PlayService.instance.playbackService.nowPlaying;
  if (nowPlaying?.path != audioPath) return;
  PlayService.instance.lyricService.reloadLyricFromTag();
}

class _NetFetchResult {
  const _NetFetchResult(this.text, {this.written = false});

  final String text;
  final bool written;
}

class _LyricSearchItem {
  final _LyricNetSource source;
  final String id;
  final String title;
  final String artist;
  final String album;
  final Map<String, String> extras;

  const _LyricSearchItem({
    required this.source,
    required this.id,
    required this.title,
    required this.artist,
    this.album = '',
    this.extras = const {},
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// 封面搜索对话框
// ─────────────────────────────────────────────────────────────────────────────

enum _CoverSource { qq, ne, kugou }

class _CoverSearchResult {
  const _CoverSearchResult({
    required this.title,
    required this.artist,
    required this.album,
    required this.picUrl,
    required this.source,
  });

  final String title;
  final String artist;
  final String album;
  final String picUrl;
  final _CoverSource source;
}

class _CoverSearchDialog extends StatefulWidget {
  const _CoverSearchDialog({required this.audio});

  final Audio audio;

  @override
  State<_CoverSearchDialog> createState() => _CoverSearchDialogState();
}

class _CoverSearchDialogState extends State<_CoverSearchDialog> {
  late final TextEditingController _searchCtrl;
  _CoverSource _activeSource = _CoverSource.qq;
  List<_CoverSearchResult> _results = [];
  bool _isSearching = false;
  bool _isDownloading = false;
  final Map<String, (int, int)> _coverImageSizeCache = {};

  @override
  void initState() {
    super.initState();
    final query = widget.audio.artist.isNotEmpty &&
            widget.audio.artist != 'UNKNOWN'
        ? '${widget.audio.title} ${widget.audio.artist}'
        : widget.audio.title;
    _searchCtrl = TextEditingController(text: query);
    _search();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _isSearching = true;
      _results = [];
    });
    try {
      final results = await _doSearch(query, _activeSource);
      if (!mounted) return;
      setState(() {
        _results = results;
        _isSearching = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  Future<List<_CoverSearchResult>> _doSearch(
    String query,
    _CoverSource source,
  ) async {
    return switch (source) {
      _CoverSource.qq => (await net_api.qqSearchLyric(
              keyword: query,
              pageSize: 12,
            ))
          .where((e) => e.picUrl.isNotEmpty)
          .map(
            (e) => _CoverSearchResult(
              title: e.title,
              artist: e.artist,
              album: e.album,
              picUrl: e.picUrl,
              source: _CoverSource.qq,
            ),
          )
          .toList(),
      _CoverSource.ne => (await net_api.neSearchLyric(
              keyword: query,
              pageSize: 12,
            ))
          .where((e) => e.picUrl.isNotEmpty)
          .map(
            (e) => _CoverSearchResult(
              title: e.title,
              artist: e.artist,
              album: e.album,
              picUrl: e.picUrl,
              source: _CoverSource.ne,
            ),
          )
          .toList(),
      _CoverSource.kugou => (await net_api.kgSearchLyric(
              keyword: query,
              pageSize: 12,
            ))
          .where((e) => e.picUrl.isNotEmpty)
          .map(
            (e) => _CoverSearchResult(
              title: e.title,
              artist: e.artist,
              album: e.album,
              picUrl: e.picUrl,
              source: _CoverSource.kugou,
            ),
          )
          .toList(),
    };
  }

  Future<void> _selectResult(_CoverSearchResult result) async {
    if (_isDownloading) return;
    setState(() => _isDownloading = true);
    try {
      final bytes = await _downloadImage(result.picUrl);
      if (!mounted) return;
      if (bytes == null) {
        showTextOnSnackBar('封面下载失败');
        return;
      }
      Navigator.pop(context, Uint8List.fromList(bytes));
    } catch (e) {
      if (mounted) showTextOnSnackBar('封面下载失败');
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  Future<List<int>?> _downloadImage(String url) async {
    io.HttpClient? client;
    try {
      client = io.HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 400, maxWidth: 600),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '搜索封面',
                    style: TextStyle(
                      fontSize: AppType.sectionTitle,
                      fontWeight: AppType.weightBold,
                      color: scheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Symbols.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      autofocus: true,
                      style: TextStyle(
                        fontSize: AppType.body,
                        color: scheme.onSurface,
                      ),
                      decoration: const InputDecoration(
                        hintText: '输入歌曲名或歌手...',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '搜索',
                    icon: _isSearching
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Symbols.search, size: 20),
                    onPressed: _isSearching ? null : _search,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _buildSourceTab(_CoverSource.qq, 'QQ'),
                  const SizedBox(width: 8),
                  _buildSourceTab(_CoverSource.ne, '网易'),
                  const SizedBox(width: 8),
                  _buildSourceTab(_CoverSource.kugou, '酷狗'),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 340,
                child: _isSearching
                    ? const Center(child: CircularProgressIndicator())
                    : _results.isEmpty
                        ? Center(
                            child: Text(
                              '无结果',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: AppType.body,
                              ),
                            ),
                          )
                        : GridView.builder(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 4,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                            itemCount: _results.length,
                            itemBuilder: (context, index) {
                              final item = _results[index];
                              final size = _coverImageSizeCache[item.picUrl];
                              return Tooltip(
                                message:
                                    '${item.title}\n${item.artist}${item.album.isNotEmpty ? '\n${item.album}' : ''}',
                                child: InkWell(
                                  onTap: _isDownloading
                                      ? null
                                      : () => _selectResult(item),
                                  borderRadius: AppRadius.smCircular,
                                  child: ClipRRect(
                                    borderRadius: AppRadius.smCircular,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Image.network(
                                          item.picUrl,
                                          fit: BoxFit.cover,
                                          frameBuilder:
                                              (ctx, child, frame, wasSynchronouslyLoaded) {
                                            if (frame != null &&
                                                !_coverImageSizeCache
                                                    .containsKey(item.picUrl)) {
                                              _loadImageSize(item.picUrl);
                                            }
                                            return child;
                                          },
                                          errorBuilder: (_, _, _) => DecoratedBox(
                                            decoration: BoxDecoration(
                                              color: scheme.surfaceContainerHighest,
                                              borderRadius: AppRadius.smCircular,
                                            ),
                                            child: Icon(
                                              Symbols.broken_image,
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                        if (size != null)
                                          Positioned(
                                            left: 0,
                                            right: 0,
                                            bottom: 0,
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                gradient: LinearGradient(
                                                  begin: Alignment.topCenter,
                                                  end: Alignment.bottomCenter,
                                                  colors: [
                                                    Colors.transparent,
                                                    Colors.black.withValues(alpha: 0.55),
                                                  ],
                                                ),
                                              ),
                                              child: Padding(
                                                padding: const EdgeInsets.fromLTRB(0, 8, 4, 3),
                                                child: Align(
                                                  alignment: Alignment.bottomRight,
                                                  child: Text(
                                                    '${size.$1}×${size.$2}',
                                                    style: const TextStyle(
                                                      fontSize: 9,
                                                      color: Colors.white,
                                                      fontWeight: FontWeight.w600,
                                                      shadows: [
                                                        Shadow(
                                                          color: Colors.black54,
                                                          blurRadius: 2,
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
              ),
              if (_isDownloading)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(
                    borderRadius: AppRadius.smCircular,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSourceTab(_CoverSource source, String label) {
    final isActive = _activeSource == source;
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () {
        if (_activeSource == source) return;
        setState(() {
          _activeSource = source;
          _results = [];
        });
        _search();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? scheme.primaryContainer : Colors.transparent,
          borderRadius: AppRadius.smCircular,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppType.caption,
            color: isActive
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
            fontWeight: isActive ? AppType.weightBold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Future<void> _loadImageSize(String url) async {
    if (_coverImageSizeCache.containsKey(url)) return;
    io.HttpClient? client;
    try {
      client = io.HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) return;
      final chunks = <List<int>>[];
      await for (final chunk in response) {
        chunks.add(chunk);
      }
      final totalLen = chunks.fold<int>(0, (sum, c) => sum + c.length);
      final bytes = Uint8List(totalLen);
      var offset = 0;
      for (final chunk in chunks) {
        bytes.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() {
        _coverImageSizeCache[url] = (frame.image.width, frame.image.height);
      });
      frame.image.dispose();
    } catch (_) {}
  }
}
