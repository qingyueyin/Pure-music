import 'package:file_picker/file_picker.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/lyric_action_state.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/lyric/lyric_loader.dart';
import 'package:pure_music/core/matcher.dart';
import 'package:pure_music/page/now_playing_page/component/vertical_lyric_view.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/services/online_lyric/api/net_lyric_api.dart'
    as net_api;
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;

LyricSourceType _lyricSourceTypeFromResultSource(ResultSource source) {
  return switch (source) {
    ResultSource.qq => LyricSourceType.qq,
    ResultSource.kugou => LyricSourceType.kugou,
    ResultSource.ne => LyricSourceType.ne,
    ResultSource.amll => LyricSourceType.amll,
  };
}

bool _isSavedLyricResult(String audioPath, SongSearchResult result) {
  final saved = lyricSources[audioPath];
  if (saved == null ||
      saved.source != _lyricSourceTypeFromResultSource(result.source)) {
    return false;
  }
  return switch (result.source) {
    ResultSource.qq =>
      saved.qqSongId != null && saved.qqSongId == result.qqSongId,
    ResultSource.kugou =>
      saved.kugouSongHash != null &&
          saved.kugouSongHash == result.kugouSongHash,
    ResultSource.ne =>
      saved.neSongId != null && saved.neSongId == result.neSongId,
    ResultSource.amll =>
      saved.amllTtmlFile != null && saved.amllTtmlFile == result.amllTtmlFile,
  };
}

@visibleForTesting
Future<bool> applyValidatedOnlineLyricResult(
  Audio audio,
  SongSearchResult result, {
  Future<Lyric?> Function(Audio audio, SongSearchResult result)? loadLyric,
  Future<void> Function()? persist,
  VoidCallback? activate,
  Duration timeout = const Duration(seconds: 12),
}) async {
  final lyric =
      await (loadLyric?.call(audio, result) ??
              getOnlineLyric(
                qqSongId: result.qqSongId,
                kugouSongHash: result.kugouSongHash,
                neSongId: result.neSongId,
                amllTtmlFile: result.amllTtmlFile,
                title: audio.title,
                album: audio.album,
                artist: audio.artist,
                durationSec: audio.duration,
              ))
          .timeout(timeout);
  if (lyric == null || lyric.lines.isEmpty) return false;

  await persistLyricSource(
    audio.path,
    result.toLyricSource(),
    persist: persist,
  );
  (activate ?? PlayService.instance.lyricService.useOnlineLyric)();
  return true;
}

@visibleForTesting
Future<bool> applyValidatedLocalLyricFile(
  Audio audio,
  String lyricPath, {
  Future<Lyric?> Function(String lyricPath)? loadLyric,
  Future<void> Function()? persist,
  void Function(Lyric lyric)? activate,
  bool Function()? canActivate,
}) async {
  final normalizedPath = lyricPath.trim();
  if (normalizedPath.isEmpty) return false;
  final lyric =
      await (loadLyric?.call(normalizedPath) ??
          loadLyricFromFile(normalizedPath));
  if (lyric == null || lyric.lines.isEmpty) return false;

  await persistLyricSource(
    audio.path,
    LyricSource(LyricSourceType.local, localLyricPath: normalizedPath),
    persist: persist,
  );
  final shouldActivate =
      canActivate?.call() ??
      PlayService.instance.playbackService.nowPlaying?.path == audio.path;
  if (shouldActivate) {
    (activate ?? PlayService.instance.lyricService.useSpecificLyric)(lyric);
  }
  return true;
}

@visibleForTesting
Future<void> restoreAutomaticLocalLyric(
  Audio audio, {
  Future<void> Function()? persist,
  VoidCallback? activate,
  bool Function()? canActivate,
}) async {
  await persistLyricSource(
    audio.path,
    LyricSource(LyricSourceType.local),
    persist: persist,
  );
  final shouldActivate =
      canActivate?.call() ??
      PlayService.instance.playbackService.nowPlaying?.path == audio.path;
  if (shouldActivate) {
    (activate ?? PlayService.instance.lyricService.useLocalLyric)();
  }
}

Widget? _buildLyricResultTrailing(
  BuildContext context, {
  required bool selected,
  String? lyricType,
}) {
  if (!selected && lyricType == null) return null;
  final scheme = Theme.of(context).colorScheme;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (lyricType != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: AppRadius.xsCircular,
          ),
          child: Text(
            lyricType,
            style: TextStyle(
              fontSize: AppType.microlabel,
              fontWeight: AppType.weightSemibold,
              color: scheme.onSecondaryContainer,
            ),
          ),
        ),
      if (lyricType != null && selected) const SizedBox(width: 8),
      if (selected) const Icon(Symbols.check),
    ],
  );
}

class ManualLyricSearchDialog extends StatefulWidget {
  const ManualLyricSearchDialog({super.key, required this.audio});

  final Audio audio;

  @override
  State<ManualLyricSearchDialog> createState() =>
      _ManualLyricSearchDialogState();
}

class _CachedSearchResult {
  static const Duration ttl = Duration(seconds: 30);

  _CachedSearchResult({
    required this.results,
    required this.hasMore,
    required this.time,
  });

  final List<SongSearchResult> results;
  final bool hasMore;
  final DateTime time;

  bool get isFresh => DateTime.now().difference(time) < ttl;
}

class _ManualLyricSearchDialogState extends State<ManualLyricSearchDialog> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  final Map<ResultSource, List<SongSearchResult>> _resultsMap = {
    ResultSource.qq: [],
    ResultSource.ne: [],
    ResultSource.kugou: [],
    ResultSource.amll: [],
  };

  final Map<ResultSource, int> _pageMap = {
    ResultSource.qq: 0,
    ResultSource.ne: 0,
    ResultSource.kugou: 0,
    ResultSource.amll: 0,
  };

  // API 级别分页：记录每个源已经请求到第几页
  final Map<ResultSource, int> _apiPageMap = {
    ResultSource.qq: 1,
    ResultSource.ne: 1,
    ResultSource.kugou: 1,
    ResultSource.amll: 1,
  };

  ResultSource _activeSource = ResultSource.qq;
  bool _isSearching = false;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  SongSearchResult? _applyingResult;
  int _searchGeneration = 0;
  static const int _pageSize = 12;
  static const int _apiPageSize = 12;

  static final Map<String, _CachedSearchResult> _searchCache = {};

  static String _cacheKey(String query, ResultSource source, [int page = 1]) =>
      '${source.index}|$query|$page';

  @override
  void initState() {
    super.initState();
    final searchQuery = widget.audio.artist.isNotEmpty
        ? '${widget.audio.title} ${widget.audio.artist}'
        : widget.audio.title;
    _searchController.text = searchQuery;
    _searchFocusNode.addListener(_onSearchFocusChanged);
    _searchActiveSource();
    // 监听切歌：歌曲切换后自动关闭弹窗
    PlayService.instance.playbackService.nowPlayingNotifier.addListener(
      _onNowPlayingChanged,
    );
  }

  @override
  void dispose() {
    PlayService.instance.playbackService.nowPlayingNotifier.removeListener(
      _onNowPlayingChanged,
    );
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    if (_searchFocusNode.hasFocus) {
      HotkeysHelper.onFocusChanges(false);
    }
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchFocusChanged() {
    HotkeysHelper.onFocusChanges(_searchFocusNode.hasFocus);
  }

  void _onNowPlayingChanged() {
    if (!mounted) return;
    final nowPlaying = PlayService.instance.playbackService.nowPlaying;
    if (nowPlaying == null || nowPlaying.path != widget.audio.path) {
      Navigator.of(context).pop();
    }
  }

  void _performSearch() {
    // 用户手动触发：强制刷新，绕过缓存；若正在搜索则作废旧搜索立即重搜
    _searchActiveSource(forceRefresh: true);
  }

  Future<void> _searchActiveSource({
    String? query,
    bool forceRefresh = false,
  }) async {
    final searchQuery = query ?? _searchController.text.trim();
    if (searchQuery.isEmpty) return;

    final source = _activeSource;

    // 30 秒内的重复搜索直接复用缓存，不重新请求；手动触发时绕过
    if (!forceRefresh) {
      final cached = _searchCache[_cacheKey(searchQuery, source)];
      if (cached != null && cached.isFresh) {
        setState(() {
          _resultsMap[source] = List.of(cached.results);
          _pageMap[source] = 0;
          _apiPageMap[source] = 1;
          _hasMore = cached.hasMore;
          _isSearching = false;
        });
        return;
      }
    }

    final searchGeneration = ++_searchGeneration;
    setState(() {
      _isSearching = true;
      _resultsMap[source]!.clear();
      _pageMap[source] = 0;
      _apiPageMap[source] = 1;
      _hasMore = true;
    });

    try {
      final page = await _searchSingleSource(
        searchQuery,
        source,
        page: 1,
        forceRefresh: forceRefresh,
      ).timeout(const Duration(seconds: 15));
      if (!mounted || searchGeneration != _searchGeneration) return;
      setState(() {
        _resultsMap[source] = page.results;
        _hasMore = page.hasMore;
      });
    } catch (e, trace) {
      logger.w('Lyric source search failed: $e', stackTrace: trace);
      if (!mounted || searchGeneration != _searchGeneration) return;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('歌词搜索失败，请稍后重试')));
      }
    } finally {
      if (mounted && searchGeneration == _searchGeneration) {
        setState(() => _isSearching = false);
      }
    }
  }

  /// 加载下一页（API 级别翻页）
  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    final source = _activeSource;
    final searchQuery = _searchController.text.trim();
    if (searchQuery.isEmpty) return;

    final nextApiPage = _apiPageMap[source]! + 1;
    setState(() => _isLoadingMore = true);

    // 页缓存命中则直接合并，不重新请求
    final cached = _searchCache[_cacheKey(searchQuery, source, nextApiPage)];
    if (cached != null && cached.isFresh) {
      _mergeLoadedPage(source, nextApiPage, cached.results, cached.hasMore);
      return;
    }

    try {
      final page = await _searchSingleSource(
        searchQuery,
        source,
        page: nextApiPage,
      );
      if (mounted) {
        _mergeLoadedPage(source, nextApiPage, page.results, page.hasMore);
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  void _mergeLoadedPage(
    ResultSource source,
    int apiPage,
    List<SongSearchResult> results,
    bool hasMore,
  ) {
    if (!mounted) return;
    final existing = _resultsMap[source]!;
    final newlyAdded = <SongSearchResult>[];
    for (final r in results) {
      if (!_containsManualResult(existing, r)) {
        existing.add(r);
        newlyAdded.add(r);
      }
    }
    final addedCount = newlyAdded.length;
    // 重新按分数降序排列整个列表，确保最佳匹配始终在前
    existing.sort((a, b) => b.score.compareTo(a.score));
    _apiPageMap[source] = apiPage;
    _hasMore = hasMore;
    // 加载完成后自动翻到下一页显示
    if (addedCount > 0) {
      final newMaxPage = (existing.length / _pageSize).ceil() - 1;
      if (_pageMap[source]! < newMaxPage) {
        _pageMap[source] = _pageMap[source]! + 1;
      }
    }
    setState(() => _isLoadingMore = false);
  }

  bool _containsManualResult(
    List<SongSearchResult> list,
    SongSearchResult item,
  ) {
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

  Future<({List<SongSearchResult> results, bool hasMore})> _searchSingleSource(
    String query,
    ResultSource source, {
    int page = 1,
    bool forceRefresh = false,
  }) async {
    List<SongSearchResult> results;
    late int rawCount;
    switch (source) {
      case ResultSource.qq:
        final raw = await net_api.qqSearchLyric(
          keyword: query,
          page: page,
          pageSize: _apiPageSize,
          forceRefresh: forceRefresh,
        );
        rawCount = raw.length;
        results = raw
            .map(
              (item) => SongSearchResult.fromQQSearchItem(item, widget.audio),
            )
            .where((r) => r != null && r.score >= 0)
            .cast<SongSearchResult>()
            .toList();
      case ResultSource.ne:
        final raw = await net_api.neSearchLyric(
          keyword: query,
          page: page,
          pageSize: _apiPageSize,
          forceRefresh: forceRefresh,
        );
        rawCount = raw.length;
        results = raw
            .map(
              (item) => SongSearchResult.fromNeSearchItem(item, widget.audio),
            )
            .where((r) => r != null && r.score >= 0)
            .cast<SongSearchResult>()
            .toList();
      case ResultSource.kugou:
        final raw = await net_api.kgSearchLyric(
          keyword: query,
          page: page,
          pageSize: _apiPageSize,
          forceRefresh: forceRefresh,
        );
        rawCount = raw.length;
        results = raw
            .map(
              (item) =>
                  SongSearchResult.fromKugouSearchItem(item, widget.audio),
            )
            .where((r) => r != null && r.score >= 0)
            .cast<SongSearchResult>()
            .toList();
      case ResultSource.amll:
        final raw = await net_api
            .amllSearchSingle(
              keyword: query,
              page: page,
              pageSize: _apiPageSize,
              forceRefresh: forceRefresh,
            )
            .timeout(const Duration(seconds: 8));
        rawCount = raw.length;
        results = raw
            .map(
              (item) => SongSearchResult.fromAmllSearchItem(item, widget.audio),
            )
            .where((r) => r != null && r.score >= 0)
            .cast<SongSearchResult>()
            .toList();
    }
    // 按分数降序排列，最匹配的排前面，减少翻页
    results.sort((a, b) => b.score.compareTo(a.score));
    final validatedResults = await validateOnlineLyricResults(
      results,
    ).timeout(const Duration(seconds: 5), onTimeout: () => results);
    // 缓存该页结果，供 30 秒内的重复请求复用
    _searchCache[_cacheKey(query, source, page)] = _CachedSearchResult(
      results: List.of(validatedResults),
      hasMore: rawCount >= _apiPageSize,
      time: DateTime.now(),
    );
    return (
      // validateOnlineLyricResults 返回 growable:false 的列表，
      // 必须复制为可变列表，否则后续 clear() 崩溃导致搜索无反应
      results: List.of(validatedResults),
      hasMore: rawCount >= _apiPageSize,
    );
  }

  void _switchSource(ResultSource source) {
    if (_activeSource == source) return;
    ++_searchGeneration;
    setState(() {
      _activeSource = source;
      _isSearching = false;
      _isLoadingMore = false;
    });
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

  Future<void> _selectResult(SongSearchResult result) async {
    if (_applyingResult != null) return;
    setState(() => _applyingResult = result);
    try {
      final applied = await applyValidatedOnlineLyricResult(
        widget.audio,
        result,
      );
      if (!mounted) return;
      if (!applied) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('该歌词下载或解析失败，来源未更改')));
        return;
      }
      Navigator.pop(context);
    } catch (error, trace) {
      logger.w('Apply lyric source failed: $error', stackTrace: trace);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('歌词加载失败，请稍后重试')));
      }
    } finally {
      if (mounted) setState(() => _applyingResult = null);
    }
  }

  Widget _buildTab(ResultSource source, String label) {
    final isActive = _activeSource == source;
    final scheme = Theme.of(context).colorScheme;
    final count = _resultsMap[source]!.length;
    final canSwitch = canSwitchTab(
      currentIndex: _activeSource.index,
      targetIndex: source.index,
    );

    return GestureDetector(
      onTap: canSwitch ? () => _switchSource(source) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? scheme.primaryContainer : Colors.transparent,
          borderRadius: AppRadius.smCircular,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: isActive
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
                fontWeight: isActive ? AppType.weightBold : FontWeight.normal,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isActive
                      ? scheme.primary
                      : scheme.surfaceContainerHighest,
                  borderRadius: AppRadius.smCircular,
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: AppType.microlabel,
                    color: isActive
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
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
                child: Icon(Symbols.lyrics, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12.0),
              Text(
                '该来源暂无结果',
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: AppType.subtitle,
                  fontWeight: AppType.weightBold,
                ),
              ),
              const SizedBox(height: 4.0),
              Text(
                '可以切换来源，或调整关键词再搜索',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
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
              isApplying: identical(_applyingResult, displayList[i]),
              enabled: _applyingResult == null,
              onTap: () => _selectResult(displayList[i]),
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
                Text(
                  '第 ${currentPage + 1} 页${_hasMore ? '' : '（共 ${(fullList.length / _pageSize).ceil()} 页）'}',
                ),
                IconButton(
                  icon: _isLoadingMore
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right),
                  onPressed:
                      (end < fullList.length || _hasMore) && !_isLoadingMore
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
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
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
                        fontSize: AppType.sectionTitle,
                        fontWeight: AppType.weightBold,
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
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: '输入歌曲名或歌手...',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      onSubmitted: (_) => _performSearch(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _searchController,
                    builder: (context, value, _) {
                      final hasQuery = value.text.trim().isNotEmpty;
                      return IconButton(
                        tooltip: hasQuery ? '搜索' : '请输入关键词',
                        icon: _isSearching
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.search),
                        onPressed: hasQuery ? _performSearch : null,
                      );
                    },
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
                  const SizedBox(width: 8),
                  _buildTab(ResultSource.amll, 'AMLL'),
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
            tooltip: '歌词来源：加载中',
            onPressed: null,
            icon: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(),
            ),
          );
          final nowPlaying = PlayService.instance.playbackService.nowPlaying;
          final savedSource = nowPlaying == null
              ? null
              : lyricSources[nowPlaying.path];
          final sourceType = savedSource?.source;
          return switch (snapshot.connectionState) {
            ConnectionState.none => loadingWidget,
            ConnectionState.waiting => loadingWidget,
            ConnectionState.active => loadingWidget,
            ConnectionState.done => _SetLyricSourceBtn(sourceType: sourceType),
          };
        },
      ),
    );
  }
}

class _SetLyricSourceBtn extends StatelessWidget {
  final LyricSourceType? sourceType;
  const _SetLyricSourceBtn({this.sourceType});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyricService = PlayService.instance.lyricService;
    final isLocal = sourceType == null
        ? null
        : sourceType == LyricSourceType.local;
    final icon = switch (sourceType) {
      null => Symbols.lyrics,
      LyricSourceType.local => Symbols.lyrics,
      _ => Symbols.cloud,
    };
    final tooltip = switch (sourceType) {
      null => '歌词来源：未指定',
      LyricSourceType.local => '歌词来源：本地',
      _ => '歌词来源：在线',
    };
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
          onPressed:
              canSelectLyricSource(isCurrentLocal: isLocal, targetLocal: false)
              ? lyricService.useOnlineLyric
              : null,
          leadingIcon: isLocal == false ? const Icon(Symbols.check) : null,
          child: const Text('在线'),
        ),
        MenuItemButton(
          onPressed:
              canSelectLyricSource(isCurrentLocal: isLocal, targetLocal: true)
              ? lyricService.useLocalLyric
              : null,
          leadingIcon: isLocal == true ? const Icon(Symbols.check) : null,
          child: const Text('本地'),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: tooltip,
        onPressed: PlayService.instance.playbackService.nowPlaying == null
            ? null
            : () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                }
              },
        icon: Icon(icon, fill: sourceType == LyricSourceType.local ? 1.0 : 0.0),
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
  SongSearchResult? _applyingResult;
  bool _isApplyingLocal = false;

  @override
  void initState() {
    super.initState();
    _searchFuture = uniSearch(widget.audio)
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () {
            logger.w('SetLyricSourceDialog uniSearch timeout');
            return [];
          },
        )
        .then((results) {
          _results = results;
          for (int i = 0; i < results.length; i++) {
            final r = results[i];
            if (r.source == ResultSource.ne &&
                r.lyricType == null &&
                r.neSongId != null) {
              _confirmNeLyricType(results, i);
            }
          }
          return results;
        });
    // 监听切歌：歌曲切换后自动关闭弹窗
    PlayService.instance.playbackService.nowPlayingNotifier.addListener(
      _onNowPlayingChanged,
    );
  }

  @override
  void dispose() {
    PlayService.instance.playbackService.nowPlayingNotifier.removeListener(
      _onNowPlayingChanged,
    );
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
    net_api
        .neGetLyric(id: r.neSongId!)
        .then((lr) async {
          if (lr == null || !lr.hasContent) return;
          try {
            final parsed = await lr.toParsedLyric();
            if (parsed != null && parsed.isNotEmpty) {
              r.lyricType = parsed.hasWordByWord ? '逐字' : '逐行';
            }
          } catch (_) {
            // 解析失败不影响其他结果
          }
        })
        .whenComplete(() {
          if (mounted) setState(() {});
        });
  }

  Future<void> _selectResult(SongSearchResult result) async {
    if (_applyingResult != null || _isApplyingLocal) return;
    setState(() => _applyingResult = result);
    try {
      final applied = await applyValidatedOnlineLyricResult(
        widget.audio,
        result,
      );
      if (!mounted) return;
      if (!applied) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('该歌词下载或解析失败，来源未更改')));
        return;
      }
      Navigator.pop(context);
    } catch (error, trace) {
      logger.w('Apply lyric source failed: $error', stackTrace: trace);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('歌词加载失败，请稍后重试')));
      }
    } finally {
      if (mounted) setState(() => _applyingResult = null);
    }
  }

  Future<void> _selectLocalLyricFile() async {
    if (_applyingResult != null || _isApplyingLocal) return;
    final savedPath = lyricSources[widget.audio.path]?.localLyricPath;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        for (final ext in supportedLyricFileExtensions) ext.substring(1),
      ],
      dialogTitle: '选择歌词文件',
      initialDirectory: savedPath == null
          ? p.dirname(widget.audio.path)
          : p.dirname(savedPath),
      lockParentWindow: true,
    );
    if (!mounted || result == null || result.files.single.path == null) return;

    setState(() => _isApplyingLocal = true);
    try {
      final applied = await applyValidatedLocalLyricFile(
        widget.audio,
        result.files.single.path!,
      );
      if (!mounted) return;
      final nowPlaying = PlayService.instance.playbackService.nowPlaying;
      if (nowPlaying == null || nowPlaying.path != widget.audio.path) return;
      if (!applied) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('歌词文件读取或解析失败，来源未更改')));
        return;
      }
      Navigator.pop(context);
    } catch (error, trace) {
      logger.w('Apply local lyric file failed: $error', stackTrace: trace);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('歌词来源保存失败，来源未更改')));
      }
    } finally {
      if (mounted) setState(() => _isApplyingLocal = false);
    }
  }

  Future<void> _restoreAutomaticLocalLyric() async {
    if (_applyingResult != null || _isApplyingLocal) return;
    setState(() => _isApplyingLocal = true);
    try {
      await restoreAutomaticLocalLyric(widget.audio);
      if (!mounted) return;
      final nowPlaying = PlayService.instance.playbackService.nowPlaying;
      if (nowPlaying == null || nowPlaying.path != widget.audio.path) return;
      Navigator.pop(context);
    } catch (error, trace) {
      logger.w(
        'Restore automatic local lyric failed: $error',
        stackTrace: trace,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('歌词来源保存失败，来源未更改')));
      }
    } finally {
      if (mounted) setState(() => _isApplyingLocal = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final savedSource = lyricSources[widget.audio.path];
    final selectedLocalPath = savedSource?.source == LyricSourceType.local
        ? savedSource?.localLyricPath
        : null;
    final isAutomaticLocalSelected =
        savedSource?.source == LyricSourceType.local &&
        selectedLocalPath == null;
    final localActionsEnabled = _applyingResult == null && !_isApplyingLocal;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
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
                      fontSize: AppType.sectionTitle,
                      fontWeight: AppType.weightBold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: '手动搜索',
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) =>
                            ManualLyricSearchDialog(audio: widget.audio),
                      );
                    },
                  ),
                ],
              ),
              ListTile(
                leading: const Icon(Symbols.folder_open),
                title: const Text('选择本地歌词文件'),
                subtitle: selectedLocalPath == null
                    ? null
                    : Text(
                        p.basename(selectedLocalPath),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                selected: selectedLocalPath != null,
                selectedTileColor: scheme.secondaryContainer.withValues(
                  alpha: 0.5,
                ),
                selectedColor: scheme.onSecondaryContainer,
                trailing: _isApplyingLocal
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : selectedLocalPath != null
                    ? const Icon(Symbols.check)
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: AppRadius.smCircular,
                ),
                onTap: localActionsEnabled ? _selectLocalLyricFile : null,
              ),
              ListTile(
                leading: const Icon(Symbols.restart_alt),
                title: const Text('自动匹配本地歌词'),
                selected: isAutomaticLocalSelected,
                selectedTileColor: scheme.secondaryContainer.withValues(
                  alpha: 0.5,
                ),
                selectedColor: scheme.onSecondaryContainer,
                trailing: isAutomaticLocalSelected
                    ? const Icon(Symbols.check)
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: AppRadius.smCircular,
                ),
                onTap: localActionsEnabled && !isAutomaticLocalSelected
                    ? _restoreAutomaticLocalLyric
                    : null,
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
                    if (snapshot.hasError ||
                        snapshot.data == null ||
                        snapshot.data!.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                snapshot.hasError ? '搜索失败' : '未找到在线歌词',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '试试点击右上角 🔍 手动搜索',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant.withValues(
                                    alpha: 0.6,
                                  ),
                                  fontSize: AppType.body,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    final results = _results ?? snapshot.data!;
                    final showManualHint = results.isEmpty;
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
                                  fontSize: AppType.body,
                                  color: scheme.onSurfaceVariant.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }
                        return _SearchResultItem(
                          audio: widget.audio,
                          searchResult: results[i],
                          isApplying: identical(_applyingResult, results[i]),
                          enabled: localActionsEnabled,
                          onTap: () => _selectResult(results[i]),
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
    required this.isApplying,
    required this.enabled,
    required this.onTap,
  });

  final Audio audio;
  final SongSearchResult searchResult;
  final bool isApplying;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _isSavedLyricResult(audio.path, searchResult);
    return ListTile(
      title: Text(searchResult.title),
      subtitle: Text('${searchResult.artists} - ${searchResult.album}'),
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.5),
      selectedColor: scheme.onSecondaryContainer,
      trailing: isApplying
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _buildLyricResultTrailing(
              context,
              selected: selected,
              lyricType: searchResult.lyricType,
            ),
      onTap: enabled ? onTap : null,
    );
  }
}

class _SearchResultItem extends StatelessWidget {
  const _SearchResultItem({
    required this.audio,
    required this.searchResult,
    required this.isApplying,
    required this.enabled,
    required this.onTap,
  });

  final Audio audio;
  final SongSearchResult searchResult;
  final bool isApplying;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _isSavedLyricResult(audio.path, searchResult);
    final sourceText = switch (searchResult.source) {
      ResultSource.qq => 'QQ',
      ResultSource.kugou => '酷狗',
      ResultSource.ne => '网易',
      ResultSource.amll => 'AMLL',
    };

    return ListTile(
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.5),
      selectedColor: scheme.onSecondaryContainer,
      trailing: isApplying
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : selected
          ? const Icon(Symbols.check)
          : null,
      onTap: enabled ? onTap : null,
      leading: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 36),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: AppRadius.xsCircular,
            ),
            child: Text(
              sourceText,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppType.microlabel,
                fontWeight: AppType.weightSemibold,
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
                borderRadius: AppRadius.xsCircular,
              ),
              child: Text(
                searchResult.lyricType!,
                style: TextStyle(
                  fontSize: AppType.microlabel,
                  fontWeight: AppType.weightSemibold,
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      title: Text(
        searchResult.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${searchResult.artists} - ${searchResult.album}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
