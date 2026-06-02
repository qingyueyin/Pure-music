import 'dart:async';

import 'package:pure_music/component/album_tile.dart';
import 'package:pure_music/component/artist_tile.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/library/union_search_result.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/core/utils.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class SearchDialog extends StatefulWidget {
  const SearchDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => const SearchDialog(),
    );
  }

  @override
  State<SearchDialog> createState() => _SearchDialogState();
}

class _SearchCategory {
  final String label;
  final IconData icon;
  const _SearchCategory(this.label, this.icon);
}

class _SearchDialogState extends State<SearchDialog> {
  late final TextEditingController _searchController = TextEditingController();
  late final ValueNotifier<UnionSearchResult> _result = ValueNotifier(
    UnionSearchResult(''),
  );
  late final ValueNotifier<bool> _isSearching = ValueNotifier(false);
  Timer? _debounce;
  int _currentIndex = 0;
  int _searchVersion = 0;

  static const _tabs = [
    _SearchCategory('音乐', Symbols.music_note),
    _SearchCategory('艺术家', Symbols.person),
    _SearchCategory('专辑', Symbols.album),
  ];

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _result.dispose();
    _isSearching.dispose();
    super.dispose();
  }

  void _onQueryChanged(String raw) {
    final query = raw.trim();
    _debounce?.cancel();
    if (query.isEmpty) {
      _result.value = UnionSearchResult('');
      _isSearching.value = false;
      return;
    }

    _isSearching.value = true;
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      _searchVersion++;
      _search(query);
      _isSearching.value = false;
    });
  }

  void _search(String query) {
    final scope = SearchScope.values[_currentIndex];
    _result.value = UnionSearchResult.search(query, scope: scope);
  }

  Widget _musicActionBar(Audio audio) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '下一首播放',
          onPressed: () {
            PlayService.instance.playbackService.addToNext(audio);
          },
          icon: const Icon(Symbols.plus_one),
        ),
        MenuAnchor(
          consumeOutsideTap: true,
          menuChildren: List.generate(PLAYLISTS.length, (playlistIndex) {
            final playlist = PLAYLISTS[playlistIndex];
            return MenuItemButton(
              onPressed: () {
                final added = playlist.containsPath(audio.path);
                if (added) {
                  showTextOnSnackBar('歌曲${audio.title}已存在');
                  return;
                }
                playlist.addPath(audio.path);
                savePlaylists();
                showTextOnSnackBar(
                  '成功将${audio.title}添加到歌单${playlist.name}',
                );
              },
              leadingIcon: const Icon(Symbols.queue_music),
              child: Text(playlist.name),
            );
          }),
          builder: (context, controller, _) {
            return IconButton(
              tooltip: '添加到歌单',
              onPressed: () {
                if (PLAYLISTS.isEmpty) {
                  showTextOnSnackBar('还未创建任何歌单');
                  return;
                }
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                }
              },
              icon: const Icon(Symbols.queue_music),
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;
    final width = (size.width * 0.70).clamp(520.0, 900.0);
    final height = (size.height * 0.65).clamp(420.0, 720.0);

    return AlertDialog(
      title: const Text('搜索'),
      content: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Focus(
              onFocusChange: HotkeysHelper.onFocusChanges,
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Symbols.search),
                  hintText: '搜索歌曲、艺术家、专辑',
                  border: const OutlineInputBorder(),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _searchController,
                    builder: (context, value, _) {
                      final hasText = value.text.trim().isNotEmpty;
                      if (!hasText) return const SizedBox.shrink();
                      return IconButton(
                        tooltip: '清除',
                        onPressed: () {
                          _debounce?.cancel();
                          _searchController.clear();
                          _result.value = UnionSearchResult('');
                          _isSearching.value = false;
                        },
                        icon: const Icon(Symbols.close),
                      );
                    },
                  ),
                ),
                onChanged: _onQueryChanged,
                onSubmitted: (_) {},
              ),
            ),
            ValueListenableBuilder(
              valueListenable: _isSearching,
              builder: (context, searching, _) => AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: searching
                    ? const Padding(
                        padding: EdgeInsets.only(top: 8.0),
                        child: LinearProgressIndicator(minHeight: 2.0),
                      )
                    : const SizedBox(height: 12.0),
              ),
            ),
            ValueListenableBuilder(
              valueListenable: _result,
              builder: (context, result, _) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: Wrap(
                    spacing: 8.0,
                    runSpacing: 8.0,
                    children: List.generate(_tabs.length, (i) {
                      final selected = _currentIndex == i;
                      return OutlinedButton.icon(
                        onPressed: () {
                          setState(() => _currentIndex = i);
                          final query = _searchController.text.trim();
                          if (query.isNotEmpty) {
                            _searchVersion++;
                            _search(query);
                          }
                        },
                        icon: Icon(
                          _tabs[i].icon,
                          size: 18,
                          color: selected ? scheme.onPrimary : scheme.onSurface,
                        ),
                        label: Text(
                          _tabs[i].label,
                          style: TextStyle(
                            color:
                                selected ? scheme.onPrimary : scheme.onSurface,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          backgroundColor:
                              selected ? scheme.primary : Colors.transparent,
                          side: BorderSide(
                            color: selected ? scheme.primary : scheme.outline,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                        ),
                      );
                    }),
                  ),
                );
              },
            ),
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: _result,
                builder: (context, value, _) {
                  final query = value.query.trim();
                  if (query.isEmpty) {
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Symbols.search,
                              size: 48,
                              color: scheme.outline,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '输入关键词开始搜索',
                              style: TextStyle(
                                color: scheme.onSurface,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '支持搜索歌曲、艺术家、专辑。',
                              style:
                                  TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  return IndexedStack(
                    key: ValueKey('search_$_searchVersion'),
                    index: _currentIndex,
                    children: [
                      _buildMusicList(value),
                      _buildArtistList(value),
                      _buildAlbumList(value),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMusicList(UnionSearchResult value) {
    if (value.audios.isEmpty) {
      return const Center(child: Text('没有找到相关音乐'));
    }
    return CustomScrollView(
      slivers: [
        SliverList.builder(
          itemCount: value.audios.length,
          itemBuilder: (context, i) => AudioTile(
            audioIndex: i,
            playlist: value.audios,
            action: _musicActionBar(value.audios[i]),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 12.0)),
      ],
    );
  }

  Widget _buildArtistList(UnionSearchResult value) {
    if (value.artists.isEmpty) {
      return const Center(child: Text('没有找到相关艺术家'));
    }
    return CustomScrollView(
      slivers: [
        SliverList.builder(
          itemCount: value.artists.length,
          itemBuilder: (context, i) => ArtistTile(artist: value.artists[i]),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 12.0)),
      ],
    );
  }

  Widget _buildAlbumList(UnionSearchResult value) {
    if (value.album.isEmpty) {
      return const Center(child: Text('没有找到相关专辑'));
    }
    return CustomScrollView(
      slivers: [
        SliverList.builder(
          itemCount: value.album.length,
          itemBuilder: (context, i) => AlbumTile(album: value.album[i]),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 12.0)),
      ],
    );
  }
}
