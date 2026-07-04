import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';

Future<void> showCoverPicker(BuildContext context, Playlist playlist) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (context) => _CoverPickerDialog(playlist: playlist),
  );
  if (changed == true) {
    await savePlaylists();
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
    return Dialog(
      insetPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 320,
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
              onTap: _pickCustomImage,
            ),
            _MenuTile(
              icon: Symbols.search,
              title: '从专辑或歌手选择',
              trailing: Symbols.navigate_next,
              onTap: () => setState(() => _page = 'search'),
            ),
            _MenuTile(
              icon: Symbols.restart_alt,
              title: '重置为默认',
              onTap: () {
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
    return Dialog(
      insetPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 400,
        height: 500,
        child: _CoverSearchBody(
          playlist: widget.playlist,
          onBack: () => setState(() => _page = 'main'),
        ),
      ),
    );
  }

  Future<void> _pickCustomImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;
    final source = result.files.single.path!;
    widget.playlist.coverSource = 'file:$source';
    Navigator.pop(context, true);
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
  final _results = ValueNotifier<List<Album>>(<Album>[]);
  final _artistResults = ValueNotifier<List<Artist>>(<Artist>[]);
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _results.dispose();
    _artistResults.dispose();
    super.dispose();
  }

  void _onSearchChanged(String raw) {
    _debounce?.cancel();
    final query = raw.trim().toLowerCase();
    if (query.isEmpty) {
      _results.value = [];
      _artistResults.value = [];
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 200), () {
      final albums = AudioLibrary.instance.albumCollection.values
          .where((a) => a.name.toLowerCase().contains(query))
          .toList();
      final artists = AudioLibrary.instance.artistCollection.values
          .where((a) => a.name.toLowerCase().contains(query))
          .toList();
      _results.value = albums;
      _artistResults.value = artists;
    });
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
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: _searchController,
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
                return Center(
                  child: Text(
                    _searchController.text.trim().isEmpty
                        ? '输入关键词搜索'
                        : '未找到匹配结果',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  if (albums.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: Text('专辑',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant)),
                    ),
                    ...albums.map((a) => _AlbumResultTile(
                          album: a,
                          onTap: () {
                            widget.playlist.coverSource = 'album:${a.name}';
                            Navigator.pop(context, true);
                          },
                        )),
                  ],
                  if (artists.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: Text('歌手',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant)),
                    ),
                    ...artists.map((a) => _ArtistResultTile(
                          artist: a,
                          onTap: () {
                            widget.playlist.coverSource = 'artist:${a.name}';
                            Navigator.pop(context, true);
                          },
                        )),
                  ],
                ],
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
  final VoidCallback onTap;
  final IconData? trailing;
  const _MenuTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: trailing != null ? Icon(trailing) : null,
      onTap: onTap,
    );
  }
}

class _AlbumResultTile extends StatelessWidget {
  final Album album;
  final VoidCallback onTap;
  const _AlbumResultTile({required this.album, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 40,
          height: 40,
          child: FutureBuilder<ImageProvider?>(
            future: album.cover,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.done &&
                  snapshot.data != null) {
                return Image(
                  image: snapshot.data!,
                  fit: BoxFit.cover,
                );
              }
              return Container(
                color: scheme.surfaceContainerHighest,
                child:
                    Icon(Symbols.album, color: scheme.onSurfaceVariant),
              );
            },
          ),
        ),
      ),
      title: Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      dense: true,
      onTap: onTap,
    );
  }
}

class _ArtistResultTile extends StatelessWidget {
  final Artist artist;
  final VoidCallback onTap;
  const _ArtistResultTile({required this.artist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 40,
          height: 40,
          child: FutureBuilder<ImageProvider?>(
            future: artist.picture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.done &&
                  snapshot.data != null) {
                return Image(
                  image: snapshot.data!,
                  fit: BoxFit.cover,
                );
              }
              return Container(
                color: scheme.surfaceContainerHighest,
                child:
                    Icon(Symbols.person, color: scheme.onSurfaceVariant),
              );
            },
          ),
        ),
      ),
      title: Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      dense: true,
      onTap: onTap,
    );
  }
}
