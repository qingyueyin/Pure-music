import 'package:pure_music/component/album_tile.dart';
import 'package:pure_music/component/artist_tile.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/search_action_state.dart';
import 'package:pure_music/library/union_search_result.dart';
import 'package:pure_music/page/search_page/search_page.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

class SearchResultPage extends StatefulWidget {
  const SearchResultPage({super.key, required this.searchResult});

  final UnionSearchResult searchResult;

  @override
  State<SearchResultPage> createState() => _SearchResultPageState();
}

class _SearchResultPageState extends State<SearchResultPage> {
  late final searchResult = ValueNotifier(widget.searchResult);
  late final searchBarController = TextEditingController(
    text: widget.searchResult.query,
  );

  @override
  void dispose() {
    searchBarController.dispose();
    searchResult.dispose();
    super.dispose();
  }

  void _submitSearch(String rawQuery) {
    final currentQuery = searchResult.value.query;
    if (!canSubmitChangedSearchQuery(
      currentQuery: currentQuery,
      nextQuery: rawQuery,
    )) {
      return;
    }
    searchResult.value = UnionSearchResult.search(
      normalizedSearchQuery(rawQuery),
    );
  }

  List<_SearchResultPageBody> buildContent(UnionSearchResult result) {
    return [
      _SearchResultPageBody(result: result, filter: _SearchResultFilter.all),
      _SearchResultPageBody(result: result, filter: _SearchResultFilter.music),
      _SearchResultPageBody(result: result, filter: _SearchResultFilter.artist),
      _SearchResultPageBody(result: result, filter: _SearchResultFilter.album),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: DefaultTabController(
          length: 4,
          child: Column(
            children: [
              Focus(
                onFocusChange: HotkeysHelper.onFocusChanges,
                child: Hero(
                  tag: searchBarKey,
                  child: TextField(
                    controller: searchBarController,
                    decoration: InputDecoration(
                      suffixIcon: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: searchBarController,
                        builder: (context, value, _) {
                          return ValueListenableBuilder<UnionSearchResult>(
                            valueListenable: searchResult,
                            builder: (context, result, _) {
                              final canSubmit = canSubmitChangedSearchQuery(
                                currentQuery: result.query,
                                nextQuery: value.text,
                              );
                              return IconButton(
                                tooltip: canSubmit ? '搜索' : '请输入新的关键词',
                                onPressed: canSubmit
                                    ? () => _submitSearch(value.text)
                                    : null,
                                icon: const Icon(Symbols.search),
                              );
                            },
                          );
                        },
                      ),
                      hintText: '搜索歌曲、艺术家、专辑',
                      border: const OutlineInputBorder(),
                    ),

                    /// when 'enter' is pressed
                    onSubmitted: _submitSearch,
                  ),
                ),
              ),
              const SizedBox(height: 8.0),
              Material(
                type: MaterialType.transparency,
                child: TabBar(
                  tabs: _SearchResultFilter.values
                      .map((filter) => Tab(text: filter.name))
                      .toList(),
                ),
              ),
              Expanded(
                child: Material(
                  type: MaterialType.transparency,
                  child: ValueListenableBuilder(
                    valueListenable: searchResult,
                    builder: (context, value, _) => TabBarView(
                      children: buildContent(value),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _SearchResultFilter {
  all('所有'),
  music('音乐'),
  artist('艺术家'),
  album('专辑');

  const _SearchResultFilter(this.name);
  final String name;
}

class _SearchResultPageBody extends StatelessWidget {
  const _SearchResultPageBody({required this.result, required this.filter});

  final UnionSearchResult result;
  final _SearchResultFilter filter;

  int get _totalCount =>
      result.audios.length + result.artists.length + result.album.length;

  Widget buildContentHeader(
    ColorScheme scheme,
    _SearchResultFilter contentType,
    int count,
  ) {
    return SliverToBoxAdapter(
      child: filter == _SearchResultFilter.all
          ? Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8.0, vertical: 10.0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      contentType.name,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: AppType.pageTitle,
                        fontWeight: AppType.weightBold,
                      ),
                    ),
                  ),
                  _ResultCount(count: count),
                ],
              ),
            )
          : const SizedBox(height: 8.0),
    );
  }

  List<Widget> buildMusicResultContent(ColorScheme scheme) {
    return [
      buildContentHeader(
          scheme, _SearchResultFilter.music, result.audios.length),
      SliverList.builder(
        itemCount: result.audios.length,
        itemBuilder: (context, i) {
          final item = result.audios[i];
          return AudioTile(
            audioIndex: 0,
            playlist: [item],
            action: IconButton(
              onPressed: () {
                context.push(app_paths.AUDIOS_PAGE, extra: item);
              },
              icon: const Icon(Symbols.location_on),
            ),
          );
        },
      ),
    ];
  }

  List<Widget> buildArtistResultContent(ColorScheme scheme) {
    return [
      buildContentHeader(
          scheme, _SearchResultFilter.artist, result.artists.length),
      SliverList.builder(
        itemCount: result.artists.length,
        itemBuilder: (context, i) => ArtistTile(artist: result.artists[i]),
      ),
    ];
  }

  List<Widget> buildAlbumResultContent(ColorScheme scheme) {
    return [
      buildContentHeader(
          scheme, _SearchResultFilter.album, result.album.length),
      SliverList.builder(
        itemCount: result.album.length,
        itemBuilder: (context, i) => AlbumTile(album: result.album[i]),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    List<Widget> slivers = [];
    switch (filter) {
      case _SearchResultFilter.all:
        if (_totalCount == 0) {
          slivers.add(
            _buildEmptyState(
              icon: Symbols.search_off,
              title: '没有找到结果',
              message: '换个关键词试试，或检查曲库是否已完成索引。',
            ),
          );
        }
        if (result.audios.isNotEmpty) {
          slivers.addAll(buildMusicResultContent(scheme));
        }
        if (result.artists.isNotEmpty) {
          slivers.addAll(buildArtistResultContent(scheme));
        }
        if (result.album.isNotEmpty) {
          slivers.addAll(buildAlbumResultContent(scheme));
        }
        break;
      case _SearchResultFilter.music:
        if (result.audios.isEmpty) {
          slivers.add(
            _buildEmptyState(
              icon: Symbols.music_note,
              title: '没有找到音乐',
              message: '这个关键词下暂时没有匹配的歌曲。',
            ),
          );
        } else {
          slivers.addAll(buildMusicResultContent(scheme));
        }
        break;
      case _SearchResultFilter.artist:
        if (result.artists.isEmpty) {
          slivers.add(
            _buildEmptyState(
              icon: Symbols.artist,
              title: '没有找到艺术家',
              message: '这个关键词下暂时没有匹配的艺术家。',
            ),
          );
        } else {
          slivers.addAll(buildArtistResultContent(scheme));
        }
        break;
      case _SearchResultFilter.album:
        if (result.album.isEmpty) {
          slivers.add(
            _buildEmptyState(
              icon: Symbols.album,
              title: '没有找到专辑',
              message: '这个关键词下暂时没有匹配的专辑。',
            ),
          );
        } else {
          slivers.addAll(buildAlbumResultContent(scheme));
        }
        break;
    }
    slivers.add(const SliverPadding(padding: EdgeInsets.only(bottom: 96.0)));
    return CustomScrollView(slivers: slivers);
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: _SearchResultEmptyState(
        icon: icon,
        title: title,
        message: message,
      ),
    );
  }
}

class _ResultCount extends StatelessWidget {
  const _ResultCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Text(
      '$count',
      style: TextStyle(
        color: scheme.onSurfaceVariant,
        fontSize: AppType.body,
      ),
    );
  }
}

class _SearchResultEmptyState extends StatelessWidget {
  const _SearchResultEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return QuietEmptyState(
      icon: icon,
      title: title,
      message: message,
      maxWidth: 380.0,
    );
  }
}
