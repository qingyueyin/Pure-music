import 'dart:math';

import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/core/matcher.dart';
import 'package:pure_music/page/now_playing_page/component/vertical_lyric_view.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class ManualLyricSearchDialog extends StatefulWidget {
  const ManualLyricSearchDialog({super.key, required this.audio});

  final Audio audio;

  @override
  State<ManualLyricSearchDialog> createState() => _ManualLyricSearchDialogState();
}

class _ManualLyricSearchDialogState extends State<ManualLyricSearchDialog> {
  final _searchController = TextEditingController();
  List<SongSearchResult> _allResults = [];
  List<SongSearchResult> _displayResults = [];
  bool _isSearching = false;
  String _currentQuery = "";
  int _currentPage = 0;
  static const int _pageSize = 5;
  late final Future<List<SongSearchResult>> _autoSearchResults;

  @override
  void initState() {
    super.initState();
    _autoSearchResults = uniSearch(widget.audio);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _performSearch() {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    
    _currentQuery = query;
    _currentPage = 0;
    
    setState(() {
      _isSearching = true;
      _displayResults = [];
    });
    
    manualSearch(widget.audio, query, limit: 15).then((results) {
      if (mounted && _currentQuery == query) {
        setState(() {
          _allResults = results;
          _displayResults = results.take(_pageSize).toList();
          _isSearching = false;
        });
      }
    }).catchError((_) {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    });
  }

  void _nextPage() {
    _currentPage++;
    final start = _currentPage * _pageSize;
    final end = start + _pageSize;
    if (start < _allResults.length) {
      setState(() {
        _displayResults = _allResults.sublist(start, end.clamp(0, _allResults.length));
      });
    }
  }

  void _prevPage() {
    if (_currentPage > 0) {
      _currentPage--;
      final start = _currentPage * _pageSize;
      setState(() {
        _displayResults = _allResults.sublist(start, (start + _pageSize).clamp(0, _allResults.length));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 384, maxWidth: 600),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Row(
                  children: [
                    Text(
                      "搜索歌词",
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 18.0,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Focus(
                      onFocusChange: HotkeysHelper.onFocusChanges,
                      child: TextField(
                        controller: _searchController,
                        decoration: const InputDecoration(
                          hintText: "输入歌曲名或歌手...",
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        onSubmitted: (_) => _performSearch(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: _isSearching 
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    onPressed: _isSearching ? null : _performSearch,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (_displayResults.isNotEmpty)
                Flexible(
                  child: Column(
                    children: [
                      Expanded(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: _displayResults.length,
                          itemBuilder: (context, i) => _ManualSearchTile(
                            audio: widget.audio,
                            searchResult: _displayResults[i],
                          ),
                        ),
                      ),
                      if (_allResults.length > _pageSize)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.chevron_left),
                              onPressed: _currentPage > 0 ? _prevPage : null,
                              tooltip: "上一页",
                            ),
                            Text("第 ${_currentPage + 1} 页"),
                            IconButton(
                              icon: const Icon(Icons.chevron_right),
                              onPressed: (_currentPage + 1) * _pageSize < _allResults.length ? _nextPage : null,
                              tooltip: "下一页",
                            ),
                          ],
                        ),
                    ],
                  ),
                )
              else if (_isSearching)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: CircularProgressIndicator(),
                  ),
                )
              else
                FutureBuilder(
                  future: _autoSearchResults,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(16.0),
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }
                    final results = snapshot.data ?? [];
                    if (results.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Center(child: Text("未找到结果，请手动搜索")),
                      );
                    }
                    return Flexible(
                      child: Column(
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(bottom: 8.0),
                            child: Text(
                              "自动匹配结果",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                          Expanded(
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: results.length,
                              itemBuilder: (context, i) => _ManualSearchTile(
                                audio: widget.audio,
                                searchResult: results[i],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class SetLyricSourceBtn extends StatelessWidget {
  const SetLyricSourceBtn({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PlayService.instance.lyricService,
      builder: (context, _) => FutureBuilder(
        future: PlayService.instance.lyricService.currLyricFuture,
        builder: (context, snapshot) {
          const loadingWidget = IconButton(
            onPressed: null,
            icon: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(),
            ),
          );
          final lyricNullable = snapshot.data;
          final isLocal = lyricNullable == null
              ? null
              : (lyricNullable is Lrc &&
                  lyricNullable.source == LrcSource.local);
          return switch (snapshot.connectionState) {
            ConnectionState.none => loadingWidget,
            ConnectionState.waiting => loadingWidget,
            ConnectionState.active => loadingWidget,
            ConnectionState.done => _SetLyricSourceBtn(isLocal: isLocal),
          };
        },
      ),
    );
  }
}

class _SetLyricSourceBtn extends StatelessWidget {
  final bool? isLocal;
  const _SetLyricSourceBtn({this.isLocal});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricService = PlayService.instance.lyricService;
    return MenuAnchor(
      onOpen: () {
        alwaysShowLyricViewControls = true;
      },
      onClose: () {
        alwaysShowLyricViewControls = false;
      },
      menuChildren: [
        MenuItemButton(
          onPressed: () {
            final nowPlaying = PlayService.instance.playbackService.nowPlaying;
            showDialog<String>(
              context: context,
              builder: (context) => SetLyricSourceDialog(audio: nowPlaying!),
            );
          },
          child: const Text("指定默认歌词"),
        ),
        MenuItemButton(
          onPressed: lyricService.useOnlineLyric,
          leadingIcon: isLocal == false ? const Icon(Symbols.check) : null,
          child: const Text("在线"),
        ),
        MenuItemButton(
          onPressed: lyricService.useLocalLyric,
          leadingIcon: isLocal == true ? const Icon(Symbols.check) : null,
          child: const Text("本地"),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        onPressed: PlayService.instance.playbackService.nowPlaying == null
            ? null
            : () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                }
              },
        icon: const Icon(Symbols.lyrics),
        color: scheme.onSecondaryContainer,
      ),
    );
  }
}

class SetLyricSourceDialog extends StatelessWidget {
  const SetLyricSourceDialog({super.key, required this.audio});

  final Audio audio;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 384, maxWidth: 600),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    "默认歌词",
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 18.0,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: "手动搜索",
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) => ManualLyricSearchDialog(audio: audio),
                      );
                    },
                  ),
                ],
              ),
              ListTile(
                title: const Text("使用本地歌词"),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8.0),
                ),
                onTap: () {
                  lyricSources[audio.path] = LyricSource(LyricSourceType.local);
                  PlayService.instance.lyricService.useLocalLyric();
                  Navigator.pop(context);
                },
              ),
              const Divider(),
              Flexible(
                child: FutureBuilder(
                  future: uniSearch(audio),
                  builder: (context, snapshot) {
                    if (snapshot.data == null) {
                      return const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }
                    if (snapshot.data!.isEmpty) {
                      return const Center(
                        child: Text("未找到在线歌词"),
                      );
                    }
                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: snapshot.data!.length,
                      itemBuilder: (context, i) => _LyricSourceTile(
                        audio: audio,
                        searchResult: snapshot.data![i],
                      ),
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
}

class _ManualSearchTile extends StatefulWidget {
  const _ManualSearchTile({
    required this.searchResult,
    required this.audio,
  });

  final Audio audio;
  final SongSearchResult searchResult;

  @override
  State<_ManualSearchTile> createState() => _ManualSearchTileState();
}

class _ManualSearchTileState extends State<_ManualSearchTile> {
  late final lyric = getOnlineLyric(
    qqSongId: widget.searchResult.qqSongId,
    kugouSongHash: widget.searchResult.kugouSongHash,
    neSongId: widget.searchResult.neSongId,
  );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Lyric?>(
      future: lyric,
      builder: (context, lyricSnapshot) {
        if (lyricSnapshot.connectionState != ConnectionState.done ||
            lyricSnapshot.data == null ||
            lyricSnapshot.data!.lines.isEmpty) {
          return const SizedBox.shrink();
        }

        final sourceText = switch (widget.searchResult.source) {
          ResultSource.qq => "QQ",
          ResultSource.kugou => "酷狗",
          ResultSource.ne => "网易云",
        };

        return ListTile(
          title: Text(widget.searchResult.title),
          subtitle: Text("${widget.searchResult.artists} - ${widget.searchResult.album}"),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              sourceText,
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          onTap: () {
            final source = switch (widget.searchResult.source) {
              ResultSource.qq => LyricSourceType.qq,
              ResultSource.kugou => LyricSourceType.kugou,
              ResultSource.ne => LyricSourceType.ne,
            };
            lyricSources[widget.audio.path] = LyricSource(
              source,
              qqSongId: widget.searchResult.qqSongId,
              kugouSongHash: widget.searchResult.kugouSongHash,
              neSongId: widget.searchResult.neSongId,
            );
            PlayService.instance.lyricService.useOnlineLyric();
            Navigator.pop(context);
          },
        );
      },
    );
  }
}

class _LyricSourceTile extends StatefulWidget {
  const _LyricSourceTile({
    required this.searchResult,
    required this.audio,
  });

  final Audio audio;
  final SongSearchResult searchResult;

  @override
  State<_LyricSourceTile> createState() => _LyricSourceTileState();
}

class _LyricSourceTileState extends State<_LyricSourceTile> {
  late final lyric = getOnlineLyric(
    qqSongId: widget.searchResult.qqSongId,
    kugouSongHash: widget.searchResult.kugouSongHash,
  );

  @override
  Widget build(BuildContext context) {
    const loadingWidget = Padding(
      padding: EdgeInsets.symmetric(vertical: 8.0),
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(),
        ),
      ),
    );
    return FutureBuilder<Lyric?>(
      future: lyric,
      builder: (context, lyricSnapshot) =>
          switch (lyricSnapshot.connectionState) {
        ConnectionState.none => loadingWidget,
        ConnectionState.waiting => loadingWidget,
        ConnectionState.active => loadingWidget,
        ConnectionState.done =>
          lyricSnapshot.data == null || lyricSnapshot.data!.lines.isEmpty
              ? const SizedBox.shrink()
              : buildTile(
                  context,
                  widget.audio,
                  widget.searchResult,
                  lyricSnapshot.data!,
                ),
      },
    );
  }

  Widget buildTile(
    BuildContext context,
    Audio audio,
    SongSearchResult searchResult,
    Lyric lyric,
  ) {
    final sourceText = switch (searchResult.source) {
      ResultSource.qq => "QQ",
      ResultSource.kugou => "酷狗",
      ResultSource.ne => "网易云",
    };

    return ListTile(
      onTap: () {
        LyricSourceType source = switch (searchResult.source) {
          ResultSource.qq => LyricSourceType.qq,
          ResultSource.kugou => LyricSourceType.kugou,
          ResultSource.ne => LyricSourceType.kugou,
        };
        lyricSources[audio.path] = LyricSource(
          source,
          qqSongId: searchResult.qqSongId,
          kugouSongHash: searchResult.kugouSongHash,
          neSongId: searchResult.neSongId,
        );
        PlayService.instance.lyricService.useSpecificLyric(lyric);

        Navigator.pop(context);
      },
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8.0),
      ),
      leading: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(sourceText),
        ],
      ),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            searchResult.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            "${searchResult.artists} - ${searchResult.album}",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      subtitle: StreamBuilder(
        stream: PlayService.instance.playbackService.positionStream,
        builder: (context, positionSnapshot) {
          final currLineIndex = max(lyric.lines.lastIndexWhere(
            (element) {
              return element.start.inMilliseconds <
                  (positionSnapshot.data ?? 0) * 1000;
            },
          ), 0);

          final LyricLine currLine = lyric.lines[currLineIndex];
          if (currLine is LrcLine) {
            return Text(
              currLine.content,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
          } else {
            final syncLine = currLine as SyncLyricLine;

            return Text(
              "${syncLine.content}${syncLine.translation != null ? "┃${syncLine.translation}" : ""}",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
          }
        },
      ),
    );
  }
}
