import 'dart:async';

import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/component/album_tile.dart';
import 'package:pure_music/component/artist_tile.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/search_action_state.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/library/union_search_result.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/core/utils.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class _SearchCountText extends StatelessWidget {
  const _SearchCountText({required this.count, required this.selected});

  final int count;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Text(
      '$count',
      style: TextStyle(
        color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
        fontSize: AppType.caption,
        fontWeight: AppType.weightMedium,
      ),
    );
  }
}

class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState({
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
  Timer? _queuedNextResetTimer;
  Audio? _queuedNextAudio;
  Audio? _addingAudioToPlaylist;
  Playlist? _addingTargetPlaylist;
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
    _queuedNextResetTimer?.cancel();
    _searchController.dispose();
    _result.dispose();
    _isSearching.dispose();
    super.dispose();
  }

  void _onQueryChanged(String raw) {
    final query = normalizedSearchQuery(raw);
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

  void _addSearchResultToNext(Audio audio) {
    PlayService.instance.playbackService.addToNext(audio);
    _queuedNextResetTimer?.cancel();
    setState(() => _queuedNextAudio = audio);
    _queuedNextResetTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() => _queuedNextAudio = null);
    });
  }

  Future<void> _addSearchResultToPlaylist(
    Audio audio,
    Playlist playlist,
  ) async {
    if (_addingAudioToPlaylist != null) {
      return;
    }

    final added = playlist.containsPath(audio.path);
    if (added) {
      showTextOnSnackBar('歌曲“${audio.title}”已存在');
      return;
    }

    setState(() {
      _addingAudioToPlaylist = audio;
      _addingTargetPlaylist = playlist;
    });
    try {
      playlist.addPath(audio.path);
      final saved = await savePlaylists();
      if (!mounted) return;
      if (!saved) {
        playlist.removeByPath(audio.path);
        showTextOnSnackBar('保存歌单失败', variant: ToastVariant.error);
        return;
      }
      showTextOnSnackBar('成功将“${audio.title}”添加到歌单“${playlist.name}”');
    } finally {
      _addingAudioToPlaylist = null;
      _addingTargetPlaylist = null;
      if (mounted) setState(() {});
    }
  }

  Widget _musicActionBar(Audio audio) {
    final isAddingThisAudio = identical(_addingAudioToPlaylist, audio);
    final isQueuedNext = identical(_queuedNextAudio, audio);
    final hasNowPlaying =
        PlayService.instance.playbackService.nowPlaying != null;
    final canAddNext = canAddAudioToNext(
      hasNowPlaying: hasNowPlaying,
      isPendingFeedback: isQueuedNext,
    );
    final playlistMemberships = playlists
        .map((playlist) => playlist.containsPath(audio.path))
        .toList(growable: false);
    final canOpenPlaylistMenu = canOpenSingleAudioAddToPlaylistMenu(
      hasAudio: true,
      isBusy: _addingAudioToPlaylist != null,
      alreadyInPlaylists: playlistMemberships,
    );
    final alreadyInAllPlaylists =
        playlists.isNotEmpty && playlistMemberships.every((value) => value);
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: isQueuedNext
              ? '已加入下一首'
              : hasNowPlaying
                  ? '下一首播放'
                  : '先播放一首歌',
          style: IconButton.styleFrom(
            backgroundColor: isQueuedNext ? scheme.primaryContainer : null,
            disabledBackgroundColor:
                isQueuedNext ? scheme.primaryContainer : null,
            disabledForegroundColor:
                isQueuedNext ? scheme.onPrimaryContainer : null,
          ),
          onPressed: canAddNext ? () => _addSearchResultToNext(audio) : null,
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Icon(
              isQueuedNext ? Symbols.check : Symbols.plus_one,
              key: ValueKey(isQueuedNext),
            ),
          ),
        ),
        MenuAnchor(
          consumeOutsideTap: true,
          menuChildren: List.generate(playlists.length, (playlistIndex) {
            final playlist = playlists[playlistIndex];
            final isAddingTarget =
                isAddingThisAudio && identical(_addingTargetPlaylist, playlist);
            final alreadyInPlaylist = playlist.containsPath(audio.path);
            return MenuItemButton(
              onPressed: _addingAudioToPlaylist == null && !alreadyInPlaylist
                  ? () => _addSearchResultToPlaylist(audio, playlist)
                  : null,
              leadingIcon: isAddingTarget
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      alreadyInPlaylist ? Symbols.check : Symbols.queue_music,
                    ),
              child: Text(playlist.name),
            );
          }),
          builder: (context, controller, _) {
            return IconButton(
              tooltip: isAddingThisAudio
                  ? '添加中'
                  : alreadyInAllPlaylists
                      ? '已存在于所有歌单'
                      : '添加到歌单',
              onPressed: canOpenPlaylistMenu
                  ? () {
                      if (controller.isOpen) {
                        controller.close();
                      } else {
                        controller.open();
                      }
                    }
                  : null,
              icon: isAddingThisAudio
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      alreadyInAllPlaylists
                          ? Symbols.check
                          : Symbols.queue_music,
                    ),
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
    final width = (size.width - 64).clamp(280.0, 900.0).toDouble();
    final height = (size.height - 180).clamp(300.0, 720.0).toDouble();

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
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
                style: TextStyle(color: scheme.onSurface),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Symbols.search),
                  hintText: '搜索歌曲、艺术家、专辑',
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _searchController,
                    builder: (context, value, _) {
                      final hasText = canShowSearchClearAction(value.text);
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
                      final canSwitch = canSwitchTab(
                          currentIndex: _currentIndex, targetIndex: i);
                      final count = switch (i) {
                        0 => result.audios.length,
                        1 => result.artists.length,
                        _ => result.album.length,
                      };
                      final showCount = selected &&
                          result.query.isNotEmpty &&
                          result.query ==
                              normalizedSearchQuery(_searchController.text);
                      return FilterChip(
                        selected: selected,
                        showCheckmark: false,
                        avatar: Icon(
                          _tabs[i].icon,
                          size: 18,
                          color: selected
                              ? scheme.onSecondaryContainer
                              : scheme.onSurfaceVariant,
                        ),
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_tabs[i].label),
                            if (showCount) ...[
                              const SizedBox(width: 6),
                              _SearchCountText(
                                count: count,
                                selected: selected,
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
                        backgroundColor: Colors.transparent,
                        color: WidgetStateProperty.resolveWith((states) {
                          if (states.contains(WidgetState.selected)) return scheme.secondaryContainer;
                          return Colors.transparent;
                        }),
                        side: BorderSide(
                          color: selected
                              ? scheme.primary
                              : scheme.outlineVariant,
                          width: selected ? 1.5 : 1.0,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        onSelected: canSwitch
                            ? (_) {
                                setState(() => _currentIndex = i);
                                final query = normalizedSearchQuery(
                                  _searchController.text,
                                );
                                if (query.isNotEmpty) {
                                  _searchVersion++;
                                  _search(query);
                                }
                              }
                            : null,
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
                    return const _SearchEmptyState(
                      icon: Symbols.search,
                      title: '输入关键词开始搜索',
                      message: '支持搜索歌曲、艺术家、专辑。',
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
      return const _SearchEmptyState(
        icon: Symbols.music_note,
        title: '没有找到相关音乐',
        message: '换个关键词，或者切到艺术家、专辑再看。',
      );
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
      return const _SearchEmptyState(
        icon: Symbols.person,
        title: '没有找到相关艺术家',
        message: '换个关键词，或者回到音乐结果里找。',
      );
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
      return const _SearchEmptyState(
        icon: Symbols.album,
        title: '没有找到相关专辑',
        message: '换个关键词，或者先从歌曲结果进入专辑。',
      );
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
