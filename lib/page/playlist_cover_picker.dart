import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';

final _coverSearchWhitespacePattern = RegExp(r'\s+');

String _normalizeCoverSearchText(String value) {
  return value.toLowerCase().replaceAll(_coverSearchWhitespacePattern, '');
}

Future<void> showCoverPicker(BuildContext context, Playlist playlist) async {
  final oldCoverSource = playlist.coverSource;
  final changed = await showDialog<bool>(
    context: context,
    builder: (context) => _CoverPickerDialog(playlist: playlist),
  );
  if (changed == true) {
    final saved = await savePlaylists();
    if (!saved) {
      playlist.coverSource = oldCoverSource;
      showTextOnSnackBar('保存歌单失败', variant: ToastVariant.error);
    } else {
      showTextOnSnackBar('已更换封面', variant: ToastVariant.success);
    }
  }
}

class _CoverPickerDialog extends StatefulWidget {
  final Playlist playlist;
  const _CoverPickerDialog({required this.playlist});

  @override
  State<_CoverPickerDialog> createState() => _CoverPickerDialogState();
}

class _CoverPickerDialogState extends State<_CoverPickerDialog> {
  String _page = 'main';
  bool _isPickingCustomImage = false;

  @override
  Widget build(BuildContext context) {
    switch (_page) {
      case 'search':
        return _buildSearchDialog(context);
      default:
        return _buildMenu(context);
    }
  }

  Widget _buildMenu(BuildContext context) {
    final viewSize = MediaQuery.sizeOf(context);
    final dialogWidth = (viewSize.width - 64).clamp(280.0, 600.0).toDouble();
    final coverSource = widget.playlist.coverSource;
    final usingCustomImage = coverSource?.startsWith('file:') == true;
    final usingLibraryCover = coverSource?.startsWith('album:') == true ||
        coverSource?.startsWith('artist:') == true;

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('选择封面来源'),
      content: SizedBox(
        width: dialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MenuTile(
              icon: Symbols.image,
              title: '自定义图片',
              busy: _isPickingCustomImage,
              selected: usingCustomImage,
              onTap: _isPickingCustomImage ? null : _pickCustomImage,
            ),
            _MenuTile(
              icon: Symbols.search,
              title: '从专辑或歌手选择',
              trailing: Symbols.navigate_next,
              selected: usingLibraryCover,
              onTap: _isPickingCustomImage
                  ? null
                  : () => setState(() => _page = 'search'),
            ),
            _MenuTile(
              icon: Symbols.restart_alt,
              title: '重置为默认',
              onTap:
                  _isPickingCustomImage || widget.playlist.coverSource == null
                      ? null
                      : () {
                          widget.playlist.coverSource = null;
                          Navigator.pop(context, true);
                        },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchDialog(BuildContext context) {
    final viewSize = MediaQuery.sizeOf(context);
    final dialogWidth = (viewSize.width - 64).clamp(300.0, 600.0).toDouble();
    final dialogHeight = (viewSize.height - 96).clamp(360.0, 600.0).toDouble();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: _CoverSearchBody(
          playlist: widget.playlist,
          onBack: () => setState(() => _page = 'main'),
        ),
      ),
    );
  }

  Future<void> _pickCustomImage() async {
    if (_isPickingCustomImage) return;
    setState(() => _isPickingCustomImage = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;
      final source = result.files.single.path!;
      widget.playlist.coverSource = 'file:$source';
      Navigator.pop(context, true);
    } finally {
      if (mounted) {
        setState(() => _isPickingCustomImage = false);
      }
    }
  }
}

class _CoverSearchBody extends StatefulWidget {
  final Playlist playlist;
  final VoidCallback onBack;
  const _CoverSearchBody({
    required this.playlist,
    required this.onBack,
  });

  @override
  State<_CoverSearchBody> createState() => _CoverSearchBodyState();
}

class _CoverSearchBodyState extends State<_CoverSearchBody> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _results = ValueNotifier<List<Album>>(<Album>[]);
  final _artistResults = ValueNotifier<List<Artist>>(<Artist>[]);
  Timer? _debounce;
  static const int _maxSearchResults = 100;
  int _currentTab = 0;

  static const _tabs = [
    ('专辑', Symbols.album),
    ('歌手', Symbols.person),
  ];

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(_onSearchFocusChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    if (_searchFocusNode.hasFocus) {
      HotkeysHelper.onFocusChanges(false);
    }
    _searchFocusNode.dispose();
    _searchController.dispose();
    _results.dispose();
    _artistResults.dispose();
    super.dispose();
  }

  void _onSearchFocusChanged() {
    HotkeysHelper.onFocusChanges(_searchFocusNode.hasFocus);
  }

  void _onSearchChanged(String raw) {
    _debounce?.cancel();
    final query = _normalizeCoverSearchText(raw);
    if (query.isEmpty) {
      _results.value = [];
      _artistResults.value = [];
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 200), () {
      final albums = AudioLibrary.instance.albumCollection.values
          .where((a) => _normalizeCoverSearchText(a.name).contains(query))
          .take(_maxSearchResults)
          .toList();
      final artists = AudioLibrary.instance.artistCollection.values
          .where((a) => _normalizeCoverSearchText(a.name).contains(query))
          .take(_maxSearchResults)
          .toList();
      _results.value = albums;
      _artistResults.value = artists;
    });
  }

  Widget _buildEmptyState(ColorScheme scheme) {
    final hasQuery = _searchController.text.trim().isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48.0,
              height: 48.0,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: AppRadius.mdCircular,
              ),
              child: Icon(
                hasQuery ? Symbols.search_off : Symbols.image_search,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12.0),
            Text(
              hasQuery ? '未找到匹配结果' : '搜索封面来源',
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: AppType.subtitle,
                fontWeight: AppType.weightBold,
              ),
            ),
            const SizedBox(height: 4.0),
            Text(
              hasQuery ? '换个专辑或歌手名再试' : '输入专辑或歌手名后选择一张封面',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Symbols.arrow_back),
                onPressed: widget.onBack,
              ),
              const Expanded(
                child: Text('搜索专辑或歌手',
                    style:
                        TextStyle(fontSize: AppType.subtitle, fontWeight: AppType.weightBold)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Symbols.search),
              hintText: '输入专辑或歌手名称',
              isDense: true,
            ),
            onChanged: _onSearchChanged,
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ValueListenableBuilder(
            valueListenable: _results,
            builder: (context, albums, _) {
              final artists = _artistResults.value;
              final hasAny = albums.isNotEmpty || artists.isNotEmpty;
              return Wrap(
                spacing: 8.0,
                runSpacing: 8.0,
                children: List.generate(_tabs.length, (i) {
                  final selected = _currentTab == i;
                  final count = i == 0 ? albums.length : artists.length;
                  final showCount = selected && hasAny;
                  return FilterChip(
                    selected: selected,
                    showCheckmark: false,
                    avatar: Icon(
                      _tabs[i].$2,
                      size: 18,
                      color: selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_tabs[i].$1),
                        if (showCount) ...[
                          const SizedBox(width: 6),
                          Text(
                            '$count',
                            style: TextStyle(
                              color: selected
                                  ? scheme.onSecondaryContainer
                                  : scheme.onSurfaceVariant,
                              fontSize: AppType.caption,
                              fontWeight: AppType.weightMedium,
                            ),
                          ),
                        ],
                      ],
                    ),
                    labelStyle: TextStyle(
                      color: selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurface,
                      fontWeight: selected ? AppType.weightSemibold : null,
                    ),
                    selectedColor: scheme.secondaryContainer,
                    side: BorderSide(
                      color: selected ? scheme.primary : scheme.outline,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    onSelected: (_) => setState(() => _currentTab = i),
                  );
                }),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: _results,
            builder: (context, albums, _) {
              final artists = _artistResults.value;
              if (albums.isEmpty && artists.isEmpty) {
                return _buildEmptyState(scheme);
              }
              return IndexedStack(
                index: _currentTab,
                children: [
                  _buildAlbumList(albums),
                  _buildArtistList(artists),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumList(List<Album> albums) {
    if (albums.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Symbols.search_off, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 8),
              const Text('没有匹配的专辑'),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final album = albums[index];
        final source = 'album:${album.name}';
        final selected = widget.playlist.coverSource == source;
        return _AlbumResultTile(
          album: album,
          selected: selected,
          onTap: selected
              ? null
              : () {
                  widget.playlist.coverSource = source;
                  Navigator.pop(context, true);
                },
        );
      },
    );
  }

  Widget _buildArtistList(List<Artist> artists) {
    if (artists.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Symbols.search_off, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 8),
              const Text('没有匹配的歌手'),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: artists.length,
      itemBuilder: (context, index) {
        final artist = artists[index];
        final source = 'artist:${artist.name}';
        final selected = widget.playlist.coverSource == source;
        return _ArtistResultTile(
          artist: artist,
          selected: selected,
          onTap: selected
              ? null
              : () {
                  widget.playlist.coverSource = source;
                  Navigator.pop(context, true);
                },
        );
      },
    );
  }
}

class _MenuTile extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback? onTap;
  final IconData? trailing;
  final bool busy;
  final bool selected;
  const _MenuTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.trailing,
    this.busy = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effectiveFg = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: InkWell(
        borderRadius: AppRadius.smCircular,
        onTap: busy ? null : onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          decoration: BoxDecoration(
            color: selected
                ? scheme.secondaryContainer.withValues(alpha: 0.5)
                : Colors.transparent,
            borderRadius: AppRadius.smCircular,
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 20,
                  color: selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant),
              const SizedBox(width: 16.0),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        color: effectiveFg,
                        fontSize: AppType.subtitle,
                        fontWeight: AppType.weightMedium)),
              ),
              if (busy)
                const SizedBox(
                  width: 20.0,
                  height: 20.0,
                  child: CircularProgressIndicator(strokeWidth: 2.0),
                )
              else
                _MenuTileTrailing(selected: selected, trailing: trailing),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuTileTrailing extends StatelessWidget {
  const _MenuTileTrailing({required this.selected, required this.trailing});

  final bool selected;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    if (!selected && trailing == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (selected) const Icon(Symbols.check),
        if (selected && trailing != null) const SizedBox(width: 8.0),
        if (trailing != null) Icon(trailing),
      ],
    );
  }
}

class _AlbumResultTile extends StatelessWidget {
  final Album album;
  final bool selected;
  final VoidCallback? onTap;
  const _AlbumResultTile({
    required this.album,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: InkWell(
        borderRadius: AppRadius.smCircular,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          decoration: BoxDecoration(
            color: selected
                ? scheme.secondaryContainer.withValues(alpha: 0.5)
                : Colors.transparent,
            borderRadius: AppRadius.smCircular,
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: AppRadius.xsCircular,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: _AlbumResultCover(album: album),
                ),
              ),
              const SizedBox(width: 12.0),
              Expanded(
                child: Text(album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: selected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurface,
                        fontSize: AppType.subtitle)),
              ),
              if (selected)
                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: Icon(Symbols.check,
                      size: 18, color: scheme.onSecondaryContainer),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtistResultTile extends StatelessWidget {
  final Artist artist;
  final bool selected;
  final VoidCallback? onTap;
  const _ArtistResultTile({
    required this.artist,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: InkWell(
        borderRadius: AppRadius.smCircular,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          decoration: BoxDecoration(
            color: selected
                ? scheme.secondaryContainer.withValues(alpha: 0.5)
                : Colors.transparent,
            borderRadius: AppRadius.smCircular,
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: AppRadius.xsCircular,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: _ArtistResultCover(artist: artist),
                ),
              ),
              const SizedBox(width: 12.0),
              Expanded(
                child: Text(artist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: selected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurface,
                        fontSize: AppType.subtitle)),
              ),
              if (selected)
                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: Icon(Symbols.check,
                      size: 18, color: scheme.onSecondaryContainer),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlbumResultCover extends StatefulWidget {
  const _AlbumResultCover({required this.album});

  final Album album;

  @override
  State<_AlbumResultCover> createState() => _AlbumResultCoverState();
}

class _AlbumResultCoverState extends State<_AlbumResultCover> {
  late Future<ImageProvider?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.album.thumbnailCover(size: 48);
  }

  @override
  void didUpdateWidget(covariant _AlbumResultCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.album != widget.album) {
      _future = widget.album.thumbnailCover(size: 48);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<ImageProvider?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.data != null) {
          return Image(image: snapshot.data!, fit: BoxFit.cover);
        }
        return Container(
          color: scheme.surfaceContainerHighest,
          child: Icon(Symbols.album, color: scheme.onSurfaceVariant),
        );
      },
    );
  }
}

class _ArtistResultCover extends StatefulWidget {
  const _ArtistResultCover({required this.artist});

  final Artist artist;

  @override
  State<_ArtistResultCover> createState() => _ArtistResultCoverState();
}

class _ArtistResultCoverState extends State<_ArtistResultCover> {
  late Future<ImageProvider?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.artist.thumbnailPicture(size: 48);
  }

  @override
  void didUpdateWidget(covariant _ArtistResultCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artist != widget.artist) {
      _future = widget.artist.thumbnailPicture(size: 48);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<ImageProvider?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.data != null) {
          return Image(image: snapshot.data!, fit: BoxFit.cover);
        }
        return Container(
          color: scheme.surfaceContainerHighest,
          child: Icon(Symbols.person, color: scheme.onSurfaceVariant),
        );
      },
    );
  }
}
