import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/scroll_aware_future_builder.dart';
import 'package:pure_music/component/search_dialog_layout.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/search_action_state.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';

String _normalizeCoverSearchText(String value) {
  return normalizedSearchQuery(value).toLowerCase();
}

Future<void> showCoverPicker(BuildContext context, Playlist playlist) async {
  final oldCoverSource = playlist.coverSource;
  final changed = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _CoverPickerDialog(playlist: playlist),
  );
  if (changed != true) return;

  final saved = await savePlaylists();
  if (!saved) {
    playlist.coverSource = oldCoverSource;
    showTextOnSnackBar('保存歌单失败', variant: ToastVariant.error);
    return;
  }
  showTextOnSnackBar('已更换封面', variant: ToastVariant.success);
}

class _CoverPickerDialog extends StatefulWidget {
  const _CoverPickerDialog({required this.playlist});

  final Playlist playlist;

  @override
  State<_CoverPickerDialog> createState() => _CoverPickerDialogState();
}

class _CoverPickerDialogState extends State<_CoverPickerDialog> {
  bool _isPickingCustomImage = false;

  @override
  Widget build(BuildContext context) {
    return SearchDialogFrame(
      title: Row(
        children: [
          const Expanded(child: Text('更换封面')),
          IconButton(
            tooltip: '选择本地图片',
            onPressed: _isPickingCustomImage ? null : _pickCustomImage,
            icon: _isPickingCustomImage
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Symbols.add_photo_alternate),
          ),
          IconButton(
            tooltip: '重置为默认',
            onPressed:
                widget.playlist.coverSource == null || _isPickingCustomImage
                ? null
                : _resetCover,
            icon: const Icon(Symbols.restart_alt),
          ),
        ],
      ),
      child: _CoverSearchBody(playlist: widget.playlist),
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
      final source = result == null || result.files.isEmpty
          ? null
          : result.files.single.path;
      if (source == null || !mounted) return;
      widget.playlist.coverSource = 'file:$source';
      Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _isPickingCustomImage = false);
    }
  }

  void _resetCover() {
    widget.playlist.coverSource = null;
    Navigator.pop(context, true);
  }
}

class _CoverSearchCandidate<T> {
  const _CoverSearchCandidate({required this.item, required this.searchText});

  final T item;
  final String searchText;
}

class _CoverSearchResult {
  const _CoverSearchResult({
    required this.query,
    required this.audios,
    required this.albums,
    required this.artists,
  });

  const _CoverSearchResult.empty()
    : query = '',
      audios = const [],
      albums = const [],
      artists = const [];

  final String query;
  final List<Audio> audios;
  final List<Album> albums;
  final List<Artist> artists;

  bool get isEmpty => audios.isEmpty && albums.isEmpty && artists.isEmpty;
}

class _CoverSearchBody extends StatefulWidget {
  const _CoverSearchBody({required this.playlist});

  final Playlist playlist;

  @override
  State<_CoverSearchBody> createState() => _CoverSearchBodyState();
}

class _CoverSearchBodyState extends State<_CoverSearchBody> {
  static const _tabs = [
    ('音乐', Symbols.music_note),
    ('艺术家', Symbols.person),
    ('专辑', Symbols.album),
  ];

  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _result = ValueNotifier(const _CoverSearchResult.empty());
  final _isSearching = ValueNotifier(false);
  late final List<_CoverSearchCandidate<Audio>> _audioCandidates;
  late final List<_CoverSearchCandidate<Album>> _albumCandidates;
  late final List<_CoverSearchCandidate<Artist>> _artistCandidates;
  Timer? _debounce;
  int _currentTab = 0;
  int _searchVersion = 0;

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(_onSearchFocusChanged);
    final library = AudioLibrary.instance;
    _audioCandidates = library.audioCollection
        .map(
          (audio) => _CoverSearchCandidate(
            item: audio,
            searchText: _normalizeCoverSearchText(audio.title),
          ),
        )
        .toList(growable: false);
    _albumCandidates = library.albumCollection.values
        .map(
          (album) => _CoverSearchCandidate(
            item: album,
            searchText: _normalizeCoverSearchText(album.name),
          ),
        )
        .toList(growable: false);
    _artistCandidates = library.artistCollection.values
        .map(
          (artist) => _CoverSearchCandidate(
            item: artist,
            searchText: _normalizeCoverSearchText(artist.name),
          ),
        )
        .toList(growable: false);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    if (_searchFocusNode.hasFocus) HotkeysHelper.onFocusChanges(false);
    _searchFocusNode.dispose();
    _searchController.dispose();
    _result.dispose();
    _isSearching.dispose();
    super.dispose();
  }

  void _onSearchFocusChanged() {
    HotkeysHelper.onFocusChanges(_searchFocusNode.hasFocus);
  }

  void _onSearchChanged(String raw) {
    _debounce?.cancel();
    final query = _normalizeCoverSearchText(raw);
    if (query.isEmpty) {
      _result.value = const _CoverSearchResult.empty();
      _isSearching.value = false;
      return;
    }

    _isSearching.value = true;
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      _result.value = _CoverSearchResult(
        query: query,
        audios: _matchingItems(_audioCandidates, query),
        albums: _matchingItems(_albumCandidates, query),
        artists: _matchingItems(_artistCandidates, query),
      );
      _searchVersion++;
      _isSearching.value = false;
    });
  }

  List<T> _matchingItems<T>(
    List<_CoverSearchCandidate<T>> candidates,
    String query,
  ) {
    final matches = <T>[];
    for (final candidate in candidates) {
      if (candidate.searchText.contains(query)) matches.add(candidate.item);
    }
    return matches;
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchController.clear();
    _result.value = const _CoverSearchResult.empty();
    _isSearching.value = false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          autofocus: true,
          decoration: InputDecoration(
            prefixIcon: const Icon(Symbols.search),
            hintText: '搜索音乐、艺术家或专辑',
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _searchController,
              builder: (context, value, _) {
                if (!canShowSearchClearAction(value.text)) {
                  return const SizedBox.shrink();
                }
                return IconButton(
                  tooltip: '清除',
                  onPressed: _clearSearch,
                  icon: const Icon(Symbols.close),
                );
              },
            ),
          ),
          onChanged: _onSearchChanged,
        ),
        ValueListenableBuilder<bool>(
          valueListenable: _isSearching,
          builder: (context, searching, _) => AnimatedSwitcher(
            duration: MotionDuration.xFast,
            child: searching
                ? const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(minHeight: 2),
                  )
                : const SizedBox(height: 12),
          ),
        ),
        ValueListenableBuilder<_CoverSearchResult>(
          valueListenable: _result,
          builder: (context, result, _) {
            final hasCurrentQuery =
                result.query.isNotEmpty &&
                result.query ==
                    _normalizeCoverSearchText(_searchController.text);
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: List.generate(_tabs.length, (index) {
                  final selected = _currentTab == index;
                  final count = switch (index) {
                    0 => result.audios.length,
                    1 => result.artists.length,
                    _ => result.albums.length,
                  };
                  return SearchCategoryButton(
                    label: _tabs[index].$1,
                    icon: _tabs[index].$2,
                    selected: selected,
                    count: selected && hasCurrentQuery ? count : null,
                    onPressed: selected
                        ? null
                        : () => setState(() => _currentTab = index),
                  );
                }),
              ),
            );
          },
        ),
        Expanded(
          child: ValueListenableBuilder<_CoverSearchResult>(
            valueListenable: _result,
            builder: (context, result, _) {
              if (result.query.isEmpty) {
                return const QuietEmptyState(
                  icon: Symbols.image_search,
                  title: '搜索音乐、艺术家或专辑',
                  message: '从媒体库中选择一张歌单封面。',
                  maxWidth: 380,
                );
              }
              if (result.isEmpty) {
                return const QuietEmptyState(
                  icon: Symbols.search_off,
                  title: '没有找到匹配结果',
                  message: '换个音乐、艺术家或专辑名称再试。',
                  maxWidth: 380,
                );
              }
              return DirectionalTabView(
                key: ValueKey('cover_search_$_searchVersion'),
                index: _currentTab,
                children: [
                  _buildMusicList(result.audios),
                  _buildArtistList(result.artists),
                  _buildAlbumList(result.albums),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMusicList(List<Audio> audios) {
    if (audios.isEmpty) {
      return const QuietEmptyState(
        icon: Symbols.search_off,
        title: '没有匹配的音乐',
        message: '当前关键词只匹配到艺术家或专辑。',
      );
    }
    return CustomScrollView(
      slivers: [
        SliverList.builder(
          itemCount: audios.length,
          itemBuilder: (context, index) {
            final audio = audios[index];
            final source = 'audio:${audio.path}';
            final metadata = [
              audio.artist.trim(),
              audio.album.trim(),
            ].where((value) => value.isNotEmpty).join(' - ');
            return _CoverResultTile(
              identity: audio,
              title: audio.title,
              subtitle: metadata.isEmpty ? null : metadata,
              cover: _AudioResultCover(audio: audio),
              selected: widget.playlist.coverSource == source,
              onTap: () => _selectCover(source),
            );
          },
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 12)),
      ],
    );
  }

  Widget _buildAlbumList(List<Album> albums) {
    if (albums.isEmpty) {
      return const QuietEmptyState(
        icon: Symbols.search_off,
        title: '没有匹配的专辑',
        message: '当前关键词只匹配到艺术家。',
      );
    }
    return CustomScrollView(
      slivers: [
        SliverList.builder(
          itemCount: albums.length,
          itemBuilder: (context, index) {
            final album = albums[index];
            final source = 'album:${album.name}';
            return _CoverResultTile(
              identity: album,
              title: album.name,
              cover: _AlbumResultCover(album: album),
              selected: widget.playlist.coverSource == source,
              onTap: () => _selectCover(source),
            );
          },
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 12)),
      ],
    );
  }

  Widget _buildArtistList(List<Artist> artists) {
    if (artists.isEmpty) {
      return const QuietEmptyState(
        icon: Symbols.search_off,
        title: '没有匹配的艺术家',
        message: '当前关键词只匹配到专辑。',
      );
    }
    return CustomScrollView(
      slivers: [
        SliverList.builder(
          itemCount: artists.length,
          itemBuilder: (context, index) {
            final artist = artists[index];
            final source = 'artist:${artist.name}';
            return _CoverResultTile(
              identity: artist,
              title: artist.name,
              cover: _ArtistResultCover(artist: artist),
              selected: widget.playlist.coverSource == source,
              onTap: () => _selectCover(source),
            );
          },
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 12)),
      ],
    );
  }

  void _selectCover(String source) {
    if (widget.playlist.coverSource == source) return;
    widget.playlist.coverSource = source;
    Navigator.pop(context, true);
  }
}

class _CoverResultTile extends StatelessWidget {
  const _CoverResultTile({
    required this.identity,
    required this.title,
    required this.cover,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final Object identity;
  final String title;
  final String? subtitle;
  final Widget cover;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final titleColor = onTap == null
        ? scheme.onSurfaceVariant
        : scheme.onSurface;
    return DirectionalListItemEntrance(
      identity: identity,
      child: AnimatedContainer(
        duration: MotionDuration.fast,
        curve: MotionCurve.standard,
        decoration: BoxDecoration(
          color: selected ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: AppRadius.smCircular,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            hoverColor: onTap == null
                ? Colors.transparent
                : scheme.onSurface.withValues(alpha: Alpha.hover),
            borderRadius: AppRadius.smCircular,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  cover,
                  const SizedBox(width: 12),
                  Expanded(
                    child: subtitle == null
                        ? Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: titleColor),
                          )
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: titleColor,
                                  fontSize: AppType.subtitle,
                                  fontWeight: AppType.weightMedium,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                  ),
                  if (selected)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(
                        Symbols.check,
                        size: 18,
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AudioResultCover extends StatelessWidget {
  const _AudioResultCover({required this.audio});

  final Audio audio;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ScrollAwareFutureBuilder<Uint8List?>(
      identity: '${audio.path}|${audio.modified}',
      initialData: audio.smallCoverBytes,
      future: audio.loadSmallCoverBytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) {
          return _CoverPlaceholder(
            icon: Symbols.music_note,
            colorScheme: scheme,
          );
        }
        return ClipRRect(
          borderRadius: AppRadius.smCircular,
          child: Image.memory(
            bytes,
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _CoverPlaceholder(
              icon: Symbols.music_note,
              colorScheme: scheme,
            ),
          ),
        );
      },
    );
  }
}

class _AlbumResultCover extends StatelessWidget {
  const _AlbumResultCover({required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final identity = '${album.primaryPath}|48';
    return ScrollAwareFutureBuilder<ImageProvider?>(
      identity: identity,
      initialData: album.cachedThumbnailCover(size: 48),
      future: () => album.thumbnailCover(size: 48),
      builder: (context, snapshot) {
        final image = snapshot.data;
        if (image == null) {
          return _CoverPlaceholder(icon: Symbols.album, colorScheme: scheme);
        }
        return ClipRRect(
          borderRadius: AppRadius.smCircular,
          child: Image(
            image: image,
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) =>
                _CoverPlaceholder(icon: Symbols.album, colorScheme: scheme),
          ),
        );
      },
    );
  }
}

class _ArtistResultCover extends StatelessWidget {
  const _ArtistResultCover({required this.artist});

  final Artist artist;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final identity = '${artist.primaryPath}|48';
    return ScrollAwareFutureBuilder<ImageProvider?>(
      identity: identity,
      initialData: artist.cachedThumbnailPicture(size: 48),
      future: () => artist.thumbnailPicture(size: 48),
      builder: (context, snapshot) {
        final image = snapshot.data;
        if (image == null) {
          return _CoverPlaceholder(icon: Symbols.person, colorScheme: scheme);
        }
        return ClipOval(
          child: Image(
            image: image,
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) =>
                _CoverPlaceholder(icon: Symbols.person, colorScheme: scheme),
          ),
        );
      },
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({required this.icon, required this.colorScheme});

  final IconData icon;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.smCircular,
      ),
      child: Icon(icon, color: colorScheme.onSurfaceVariant),
    );
  }
}
