import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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
      showTextOnSnackBar('保存歌单失败');
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
    final scheme = Theme.of(context).colorScheme;
    final viewSize = MediaQuery.sizeOf(context);
    final dialogWidth = (viewSize.width - 64).clamp(280.0, 320.0).toDouble();
    final coverSource = widget.playlist.coverSource;
    final usingCustomImage = coverSource?.startsWith('file:') == true;
    final usingLibraryCover = coverSource?.startsWith('album:') == true ||
        coverSource?.startsWith('artist:') == true;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: dialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('选择封面来源',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurface)),
            ),
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
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchDialog(BuildContext context) {
    final viewSize = MediaQuery.sizeOf(context);
    final dialogWidth = (viewSize.width - 64).clamp(300.0, 400.0).toDouble();
    final dialogHeight = (viewSize.height - 96).clamp(360.0, 500.0).toDouble();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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

  Widget _buildSearchState(ColorScheme scheme) {
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
                borderRadius: BorderRadius.circular(16.0),
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
                fontSize: 15.0,
                fontWeight: FontWeight.w700,
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
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: _onSearchChanged,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: _results,
            builder: (context, albums, _) {
              final artists = _artistResults.value;
              if (albums.isEmpty && artists.isEmpty) {
                return _buildSearchState(scheme);
              }
              final albumHeaderCount = albums.isEmpty ? 0 : 1;
              final artistHeaderCount = artists.isEmpty ? 0 : 1;
              final itemCount = albumHeaderCount +
                  albums.length +
                  artistHeaderCount +
                  artists.length;

              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 16),
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  if (albums.isNotEmpty) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                        child: Text('专辑',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurfaceVariant)),
                      );
                    }
                    final albumIndex = index - 1;
                    if (albumIndex < albums.length) {
                      final album = albums[albumIndex];
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
                    }
                    index -= albums.length + 1;
                  }

                  if (artists.isNotEmpty) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                        child: Text('歌手',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurfaceVariant)),
                      );
                    }
                    final artist = artists[index - 1];
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
                  }

                  return const SizedBox.shrink();
                },
              );
            },
          ),
        ),
      ],
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
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      enabled: onTap != null,
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.5),
      selectedColor: scheme.onSecondaryContainer,
      trailing: busy
          ? const SizedBox(
              width: 20.0,
              height: 20.0,
              child: CircularProgressIndicator(strokeWidth: 2.0),
            )
          : _MenuTileTrailing(selected: selected, trailing: trailing),
      onTap: busy ? null : onTap,
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
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 40,
          height: 40,
          child: _AlbumResultCover(album: album),
        ),
      ),
      title: Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.5),
      selectedColor: scheme.onSecondaryContainer,
      trailing: selected ? const Icon(Symbols.check) : null,
      dense: true,
      onTap: onTap,
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
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 40,
          height: 40,
          child: _ArtistResultCover(artist: artist),
        ),
      ),
      title: Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.5),
      selectedColor: scheme.onSecondaryContainer,
      trailing: selected ? const Icon(Symbols.check) : null,
      dense: true,
      onTap: onTap,
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
