import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/core/matcher.dart';
import 'package:pure_music/page/now_playing_page/component/vertical_lyric_view.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/services/online_lyric/api/net_lyric_api.dart' as net_api;
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

  final Map<ResultSource, List<SongSearchResult>> _resultsMap = {
    ResultSource.qq: [],
    ResultSource.ne: [],
    ResultSource.kugou: [],
  };

  final Map<ResultSource, int> _pageMap = {
    ResultSource.qq: 0,
    ResultSource.ne: 0,
    ResultSource.kugou: 0,
  };

  // API 级别分页：记录每个源已经请求到第几页
  final Map<ResultSource, int> _apiPageMap = {
    ResultSource.qq: 1,
    ResultSource.ne: 1,
    ResultSource.kugou: 1,
  };

  ResultSource _activeSource = ResultSource.qq;
  bool _isSearching = false;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  static const int _pageSize = 12;
  static const int _apiPageSize = 30;

  @override
  void initState() {
    super.initState();
    final searchQuery = widget.audio.artist.isNotEmpty
        ? '${widget.audio.title} ${widget.audio.artist}'
        : widget.audio.title;
    _searchController.text = searchQuery;
    _searchActiveSource();
    // 监听切歌：歌曲切换后自动关闭弹窗
    PlayService.instance.playbackService.nowPlayingNotifier.addListener(_onNowPlayingChanged);
  }

  @override
  void dispose() {
    PlayService.instance.playbackService.nowPlayingNotifier.removeListener(_onNowPlayingChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onNowPlayingChanged() {
    if (!mounted) return;
    final nowPlaying = PlayService.instance.playbackService.nowPlaying;
    if (nowPlaying == null || nowPlaying.path != widget.audio.path) {
      Navigator.of(context).pop();
    }
  }

  void _performSearch() {
    _searchActiveSource();
  }

  Future<void> _searchActiveSource({String? query}) async {
    final searchQuery = query ?? _searchController.text.trim();
    if (searchQuery.isEmpty) return;

    final source = _activeSource;
    setState(() {
      _isSearching = true;
      _resultsMap[source]!.clear();
      _pageMap[source] = 0;
      _apiPageMap[source] = 1;
      _hasMore = true;
    });

    try {
      final results = await _searchSingleSource(searchQuery, source, page: 1);
      // 如果是网易云源，在显示结果前先批量获取逐字/逐行类型
      if (source == ResultSource.ne && results.isNotEmpty) {
        await _fillNeLyricTypes(results);
      }
      if (mounted) {
        setState(() {
          _resultsMap[source] = results;
          _hasMore = results.length >= _apiPageSize;
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  /// 批量获取网易云结果的逐字/逐行类型
  Future<void> _fillNeLyricTypes(List<SongSearchResult> results) async {
    final neResults = results.where((r) => r.source == ResultSource.ne && r.lyricType == null && r.neSongId != null).toList();
    if (neResults.isEmpty) return;

    final futures = neResults.map((r) async {
      final cached = getCachedLyric(neSongId: r.neSongId);
      if (cached != null) {
        r.lyricType = cached.isWordByWord ? '逐字' : '逐行';
        return;
      }
      try {
        final lr = await net_api.neGetLyric(id: r.neSongId!);
        if (lr == null || !lr.hasContent) return;
        final parsed = await lr.toParsedLyric();
        if (parsed != null && parsed.isNotEmpty) {
          r.lyricType = parsed.hasWordByWord ? '逐字' : '逐行';
        }
      } catch (_) {
        // 单个请求失败不影响其他结果
      }
    });

    await Future.wait(futures);
    if (mounted) setState(() {});
  }

  /// 加载下一页（API 级别翻页）
  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    final source = _activeSource;
    final searchQuery = _searchController.text.trim();
    if (searchQuery.isEmpty) return;

    final nextApiPage = _apiPageMap[source]! + 1;
    setState(() => _isLoadingMore = true);

    try {
      final newResults = await _searchSingleSource(searchQuery, source, page: nextApiPage);
      if (mounted) {
        final existing = _resultsMap[source]!;
        final newlyAdded = <SongSearchResult>[];
        for (final r in newResults) {
          if (!_containsManualResult(existing, r)) {
            existing.add(r);
            newlyAdded.add(r);
          }
        }
        final addedCount = newlyAdded.length;
        // 重新按分数降序排列整个列表，确保最佳匹配始终在前
        existing.sort((a, b) => b.score.compareTo(a.score));
        _apiPageMap[source] = nextApiPage;
        _hasMore = newResults.isNotEmpty && addedCount > 0;
        // 加载完成后自动翻到下一页显示
        if (addedCount > 0) {
          final newMaxPage = (existing.length / _pageSize).ceil() - 1;
          if (_pageMap[source]! < newMaxPage) {
            _pageMap[source] = _pageMap[source]! + 1;
          }
        }
        // 如果是网易云源，仅获取新增结果的 lyricType
        if (source == ResultSource.ne && addedCount > 0) {
          await _fillNeLyricTypes(newlyAdded);
        }
        setState(() => _isLoadingMore = false);
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  bool _containsManualResult(List<SongSearchResult> list, SongSearchResult item) {
    for (final r in list) {
      if (r.source == item.source &&
          r.qqSongId == item.qqSongId &&
          r.kugouSongHash == item.kugouSongHash &&
          r.neSongId == item.neSongId) {
        return true;
      }
    }
    return false;
  }

  Future<List<SongSearchResult>> _searchSingleSource(
      String query, ResultSource source, {int page = 1}) async {
    List<SongSearchResult> results;
    switch (source) {
      case ResultSource.qq:
        final raw = await net_api.qqSearchLyric(keyword: query, page: page, pageSize: _apiPageSize);
        results = raw
            .map((item) => SongSearchResult.fromQQSearchItem(item, widget.audio))
            .where((r) => r != null && r.score >= 0)
            .cast<SongSearchResult>()
            .toList();
      case ResultSource.ne:
        final raw = await net_api.neSearchLyric(keyword: query, page: page, pageSize: _apiPageSize);
        results = raw
            .map((item) => SongSearchResult.fromNeSearchItem(item, widget.audio))
            .where((r) => r != null && r.score >= 0)
            .cast<SongSearchResult>()
            .toList();
      case ResultSource.kugou:
        final raw = await net_api.kgSearchLyric(keyword: query, page: page, pageSize: _apiPageSize);
        results = raw
            .map((item) => SongSearchResult.fromKugouSearchItem(item, widget.audio))
            .where((r) => r != null && r.score >= 0)
            .cast<SongSearchResult>()
            .toList();
    }
    // 按分数降序排列，最匹配的排前面，减少翻页
    results.sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  void _switchSource(ResultSource source) {
    setState(() => _activeSource = source);
    if (_resultsMap[source]!.isEmpty) {
      _searchActiveSource();
    }
  }

  void _changePage(int delta) {
    final source = _activeSource;
    final newList = _resultsMap[source]!;
    final currentPage = _pageMap[source]!;
    final nextPage = currentPage + delta;

    final maxDisplayPage = (newList.length / _pageSize).ceil() - 1;

    if (nextPage >= 0 && nextPage <= maxDisplayPage) {
      setState(() {
        _pageMap[source] = nextPage;
      });
    } else if (nextPage > maxDisplayPage && _hasMore) {
      // 需要加载更多数据
      _loadMore();
    }
  }

  Widget _buildTab(ResultSource source, String label) {
    final isActive = _activeSource == source;
    final scheme = Theme.of(context).colorScheme;
    final count = _resultsMap[source]!.length;

    return GestureDetector(
      onTap: () => _switchSource(source),
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
          child: Text('该源未找到结果', style: TextStyle(color: scheme.onSurfaceVariant)),
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
        if (fullList.length > _pageSize || _hasMore)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: start > 0 ? () => _changePage(-1) : null,
                  tooltip: '上一页',
                ),
                Text('第 ${currentPage + 1} 页${_hasMore ? '' : '（共 ${(fullList.length / _pageSize).ceil()} 页）'}'),
                IconButton(
                  icon: _isLoadingMore
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right),
                  onPressed: (end < fullList.length || _hasMore) && !_isLoadingMore
                      ? () => _changePage(1)
                      : null,
                  tooltip: _hasMore ? '加载更多' : '下一页',
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
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Row(
                  children: [
                    Text(
                      '搜索歌词',
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
                          hintText: '输入歌曲名或歌手...',
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
              Row(
                children: [
                  _buildTab(ResultSource.qq, 'QQ'),
                  const SizedBox(width: 8),
                  _buildTab(ResultSource.ne, '网易'),
                  const SizedBox(width: 8),
                  _buildTab(ResultSource.kugou, '酷狗'),
                ],
              ),
              const SizedBox(height: 8),
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
                  lyricNullable.source == LyricFormat.local);
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
            // 延迟到下一帧，确保菜单关闭动画完成后再弹 dialog
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (nowPlaying != null) {
                showDialog<String>(
                  context: context,
                  builder: (context) => SetLyricSourceDialog(audio: nowPlaying),
                );
              }
            });
          },
          child: const Text('指定默认歌词'),
        ),
        MenuItemButton(
          onPressed: lyricService.useOnlineLyric,
          leadingIcon: isLocal == false ? const Icon(Symbols.check) : null,
          child: const Text('在线'),
        ),
        MenuItemButton(
          onPressed: lyricService.useLocalLyric,
          leadingIcon: isLocal == true ? const Icon(Symbols.check) : null,
          child: const Text('本地'),
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

class SetLyricSourceDialog extends StatefulWidget {
  const SetLyricSourceDialog({super.key, required this.audio});

  final Audio audio;

  @override
  State<SetLyricSourceDialog> createState() => _SetLyricSourceDialogState();
}

class _SetLyricSourceDialogState extends State<SetLyricSourceDialog> {
  late final Future<List<SongSearchResult>> _searchFuture;
  List<SongSearchResult>? _results;

  @override
  void initState() {
    super.initState();
    _searchFuture = uniSearch(widget.audio)
        .timeout(const Duration(seconds: 20), onTimeout: () {
      logger.w('SetLyricSourceDialog uniSearch timeout');
      return [];
    }).then((results) {
      _results = results;
      for (int i = 0; i < results.length; i++) {
        final r = results[i];
        if (r.source == ResultSource.ne && r.lyricType == null && r.neSongId != null) {
          _confirmNeLyricType(results, i);
        }
      }
      return results;
    });
    // 监听切歌：歌曲切换后自动关闭弹窗
    PlayService.instance.playbackService.nowPlayingNotifier.addListener(_onNowPlayingChanged);
  }

  @override
  void dispose() {
    PlayService.instance.playbackService.nowPlayingNotifier.removeListener(_onNowPlayingChanged);
    super.dispose();
  }

  void _onNowPlayingChanged() {
    if (!mounted) return;
    final nowPlaying = PlayService.instance.playbackService.nowPlaying;
    if (nowPlaying == null || nowPlaying.path != widget.audio.path) {
      Navigator.of(context).pop();
    }
  }

  void _confirmNeLyricType(List<SongSearchResult> results, int index) {
    if (!mounted) return;
    final r = results[index];
    final cached = getCachedLyric(neSongId: r.neSongId);
    if (cached != null) {
      r.lyricType = cached.isWordByWord ? '逐字' : '逐行';
      if (mounted) setState(() {});
      return;
    }
    net_api.neGetLyric(id: r.neSongId!).then((lr) async {
      if (lr == null || !lr.hasContent) return;
      try {
        final parsed = await lr.toParsedLyric();
        if (parsed != null && parsed.isNotEmpty) {
          r.lyricType = parsed.hasWordByWord ? '逐字' : '逐行';
        }
      } catch (_) {
        // 解析失败不影响其他结果
      }
    }).whenComplete(() {
      if (mounted) setState(() {});
    });
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
              Row(
                children: [
                  Text(
                    '默认歌词',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 18.0,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: '手动搜索',
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) => ManualLyricSearchDialog(audio: widget.audio),
                      );
                    },
                  ),
                ],
              ),
              ListTile(
                title: const Text('使用本地歌词'),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8.0),
                ),
                onTap: () {
                  lyricSources[widget.audio.path] = LyricSource(LyricSourceType.local);
                  saveLyricSources();
                  PlayService.instance.lyricService.useLocalLyric();
                  Navigator.pop(context);
                },
              ),
              const Divider(),
              Flexible(
                child: FutureBuilder<List<SongSearchResult>>(
                  future: _searchFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }
                    if (snapshot.hasError || snapshot.data == null || snapshot.data!.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                snapshot.hasError ? '搜索失败' : '未找到在线歌词',
                                style: TextStyle(color: scheme.onSurfaceVariant),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '试试点击右上角 🔍 手动搜索',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    final results = _results ?? snapshot.data!;
                    // 搜索结果较少（少于 3 条）时提示手动搜索
                    final showManualHint = results.length < 3;
                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: results.length + (showManualHint ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (showManualHint && i == results.length) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                '试试手动搜索',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                                ),
                              ),
                            ),
                          );
                        }
                        return _SearchResultItem(
                          audio: widget.audio,
                          searchResult: results[i],
                        );
                      },
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

class _ManualSearchTile extends StatelessWidget {
  const _ManualSearchTile({
    required this.searchResult,
    required this.audio,
  });

  final Audio audio;
  final SongSearchResult searchResult;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(searchResult.title),
      subtitle: Text('${searchResult.artists} - ${searchResult.album}'),
      trailing: searchResult.lyricType != null
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                searchResult.lyricType!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            )
          : null,
      onTap: () {
        final source = switch (searchResult.source) {
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
        saveLyricSources();
        Navigator.pop(context);

        WidgetsBinding.instance.addPostFrameCallback((_) {
          PlayService.instance.lyricService.useOnlineLyric();
        });
      },
    );
  }
}

class _SearchResultItem extends StatelessWidget {
  const _SearchResultItem({
    required this.audio,
    required this.searchResult,
  });

  final Audio audio;
  final SongSearchResult searchResult;

  @override
  Widget build(BuildContext context) {
    final sourceText = switch (searchResult.source) {
      ResultSource.qq => 'QQ',
      ResultSource.kugou => '酷狗',
      ResultSource.ne => '网易',
    };

    return ListTile(
      onTap: () {
        final source = switch (searchResult.source) {
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
        saveLyricSources();
        Navigator.pop(context);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          PlayService.instance.lyricService.useOnlineLyric();
        });
      },
      leading: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 36),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              sourceText,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          if (searchResult.lyricType != null) ...[
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                searchResult.lyricType!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      title: Text(searchResult.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${searchResult.artists} - ${searchResult.album}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
