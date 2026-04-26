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
  
  // 按源存储结果
  final Map<ResultSource, List<SongSearchResult>> _resultsMap = {
    ResultSource.qq: [],
    ResultSource.ne: [],
    ResultSource.kugou: [],
  };
  
  // 按源存储当前页码
  final Map<ResultSource, int> _pageMap = {
    ResultSource.qq: 0,
    ResultSource.ne: 0,
    ResultSource.kugou: 0,
  };

  ResultSource _activeSource = ResultSource.qq;
  bool _isSearching = false;
  static const int _pageSize = 5;

  @override
  void initState() {
    super.initState();
    // Run auto-search and populate _resultsMap when results arrive.
    // We intentionally don't await the Future; the UI will update
    // via setState in the then callback.
    uniSearch(widget.audio).then((results) {
      if (mounted) {
        setState(() {
          _resultsMap[ResultSource.qq] = results.where((r) => r.source == ResultSource.qq).toList();
          _resultsMap[ResultSource.ne] = results.where((r) => r.source == ResultSource.ne).toList();
          _resultsMap[ResultSource.kugou] = results.where((r) => r.source == ResultSource.kugou).toList();
        });
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _performSearch() {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    
    final prevSource = _activeSource;
    
    setState(() {
      _isSearching = true;
      // 重置所有源的数据和页码
      _resultsMap.forEach((k, v) {
        v.clear();
        _pageMap[k] = 0;
      });
    });
    
    manualSearch(widget.audio, query, limit: 15).then((results) {
      if (mounted) {
        setState(() {
          _resultsMap[ResultSource.qq] = results.where((r) => r.source == ResultSource.qq).toList();
          _resultsMap[ResultSource.ne] = results.where((r) => r.source == ResultSource.ne).toList();
          _resultsMap[ResultSource.kugou] = results.where((r) => r.source == ResultSource.kugou).toList();
          _isSearching = false;
          // 保持用户之前选的Tab，除非那个源没结果
          if (_resultsMap[prevSource]!.isEmpty) {
            // 找第一个有结果的源
            if (_resultsMap[ResultSource.qq]!.isNotEmpty) {
              _activeSource = ResultSource.qq;
            } else if (_resultsMap[ResultSource.ne]!.isNotEmpty) {
              _activeSource = ResultSource.ne;
            } else if (_resultsMap[ResultSource.kugou]!.isNotEmpty) {
              _activeSource = ResultSource.kugou;
            }
          }
        });
      }
    }).catchError((e, stack) {
      logger.w('Manual search error: $e', stackTrace: stack);
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    });
  }

  void _changePage(int delta) {
    final source = _activeSource;
    final newList = _resultsMap[source]!;
    final currentPage = _pageMap[source]!;
    final nextPage = currentPage + delta;
    final maxPage = (newList.length / _pageSize).ceil() - 1;

    if (nextPage >= 0 && nextPage <= maxPage) {
      setState(() {
        _pageMap[source] = nextPage;
      });
    }
  }

  Widget _buildTab(ResultSource source, String label) {
    final isActive = _activeSource == source;
    final scheme = Theme.of(context).colorScheme;
    final count = _resultsMap[source]!.length;

    return GestureDetector(
      onTap: () => setState(() => _activeSource = source),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: isActive ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isActive ? scheme.primary : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 10,
                    color: isActive ? scheme.onPrimary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildSourceContent(ResultSource source) {
    final scheme = Theme.of(context).colorScheme;
    final fullList = _resultsMap[source]!;
    final currentPage = _pageMap[source]!;
    final start = currentPage * _pageSize;
    final end = (start + _pageSize).clamp(0, fullList.length);
    final displayList = fullList.sublist(start, end);

    if (fullList.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Text("该源未找到结果", style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: displayList.length,
            itemBuilder: (context, i) => _ManualSearchTile(
              audio: widget.audio,
              searchResult: displayList[i],
            ),
          ),
        ),
        if (fullList.length > _pageSize)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: start > 0 ? () => _changePage(-1) : null,
                  tooltip: "上一页",
                ),
                Text("第 ${currentPage + 1}/${(fullList.length / _pageSize).ceil()} 页"),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: end < fullList.length ? () => _changePage(1) : null,
                  tooltip: "下一页",
                ),
              ],
            ),
          ),
      ],
    );
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
              // Header
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
              // Search Bar
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
              const SizedBox(height: 12),
              // Tabs
              Row(
                children: [
                  _buildTab(ResultSource.qq, "QQ"),
                  const SizedBox(width: 8),
                  _buildTab(ResultSource.ne, "网易云"),
                  const SizedBox(width: 8),
                  _buildTab(ResultSource.kugou, "酷狗"),
                ],
              ),
              const SizedBox(height: 8),
              // Content
              SizedBox(
                height: 300,
                child: _isSearching
                    ? const Center(child: CircularProgressIndicator())
                    : _buildSourceContent(_activeSource),
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
    neSongId: widget.searchResult.neSongId,
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
          ResultSource.ne => LyricSourceType.ne,
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
