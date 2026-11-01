import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/page/stats_page/artists_tab.dart';
import 'package:pure_music/page/stats_page/overview_tab.dart';
import 'package:pure_music/page/stats_page/ranked_tab.dart';
import 'package:pure_music/page/stats_page/report_tab.dart';
import 'package:pure_music/page/stats_page/stats_shared.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/services/native/playback_stats_service.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsTab {
  const _StatsTab(this.label, this.icon);

  final String label;
  final IconData icon;
}

class _StatsPageState extends State<StatsPage> {
  static const _rankedLimit = 100;

  static const _tabs = [
    _StatsTab('概览', Symbols.dashboard),
    _StatsTab('艺术家·专辑', Symbols.people),
    _StatsTab('单曲榜单', Symbols.leaderboard),
    _StatsTab('报告', Symbols.insights),
  ];

  int _currentIndex = 0;
  StatsPeriod _period = StatsPeriod.current(StatsPeriodMode.week);
  int? _earliestAt;
  List<PlayCountRecord>? _topPlayed;
  List<PlayHistoryRecord> _historyEntries = const [];
  PlayHistoryStats? _history;
  StatsPeriod? _historyPeriod;
  bool _loading = true;
  bool _loadFailed = false;
  bool _historyLoading = true;
  bool _historyFailed = false;
  int _rankRequestToken = 0;
  int _historyRequestToken = 0;
  late final ValueListenable<int> _playCountRevision;

  @override
  void initState() {
    super.initState();
    _playCountRevision = PlayService.instance.playbackService.playCountRevision;
    _playCountRevision.addListener(_onStatsSourceChanged);
    AudioLibrary.libraryVersion.addListener(_onStatsSourceChanged);
    _loadStats();
  }

  void _onStatsSourceChanged() {
    if (!mounted) return;
    _loadStats();
  }

  bool get _canGoBack {
    final earliest = _earliestAt;
    if (earliest == null || earliest <= 0) return false;
    return _period.startEpoch > earliest;
  }

  bool get _canGoForward => !_period.isCurrent;

  void _setPeriodMode(StatsPeriodMode mode) {
    if (_period.mode == mode) return;
    setState(() => _period = StatsPeriod.current(mode));
    _applyHistory();
  }

  void _shiftPeriod(int delta) {
    if (delta > 0 && !_canGoForward) return;
    if (delta < 0 && !_canGoBack) return;
    setState(() => _period = _period.shift(delta));
    _applyHistory();
  }

  Future<void> _loadStats() async {
    await Future.wait([_loadRankings(), _loadHistory()]);
  }

  Future<void> _loadRankings() async {
    final requestToken = ++_rankRequestToken;
    if (!_loading) {
      setState(() {
        _loading = true;
        _loadFailed = false;
      });
    }
    try {
      final top = await PlaybackStatsService.instance.getTopPlayed(limit: -1);
      final visibleTop = top
          .where(
            (entry) => AudioLibrary.instance.audioByPath(entry.path) != null,
          )
          .toList(growable: false);
      if (!mounted || requestToken != _rankRequestToken) return;
      setState(() {
        _topPlayed = visibleTop;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestToken != _rankRequestToken) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _loadHistory() async {
    final requestToken = ++_historyRequestToken;
    setState(() {
      _historyLoading = true;
      _historyFailed = false;
    });
    try {
      final entries = await PlaybackStatsService.instance.exportPlayHistory();
      final merged = <PlayHistoryRecord>[...entries];
      if (!mounted || requestToken != _historyRequestToken) return;
      var earliest = 0;
      for (final entry in merged) {
        for (final playedAt in entry.playedAt) {
          final seconds = playedAt.toInt();
          if (earliest == 0 || seconds < earliest) earliest = seconds;
        }
      }
      setState(() {
        _historyEntries = merged;
        _earliestAt = earliest;
        _historyLoading = false;
      });
      _applyHistory();
    } catch (_) {
      if (!mounted || requestToken != _historyRequestToken) return;
      setState(() {
        _historyLoading = false;
        _historyFailed = true;
      });
    }
  }

  void _applyHistory() {
    final period = _period;
    final stats = _buildHistoryStats(_historyEntries, period);
    if (!mounted) return;
    setState(() {
      _history = stats;
      _historyPeriod = period;
      _earliestAt = stats.earliestAt.toInt();
    });
  }

  PlayHistoryStats _buildHistoryStats(
    List<PlayHistoryRecord> entries,
    StatsPeriod period,
  ) {
    final daily = <String, int>{};
    final hourly = List<int>.filled(24, 0);
    final weekdayHourly = List<int>.filled(168, 0);
    var total = 0;
    var firstAt = 0;
    var lastAt = 0;
    var earliestAt = 0;
    for (final entry in entries) {
      for (final playedAtValue in entry.playedAt) {
        final playedAt = playedAtValue.toInt();
        if (earliestAt == 0 || playedAt < earliestAt) earliestAt = playedAt;
        if (playedAt < period.startEpoch || playedAt >= period.endEpoch) {
          continue;
        }
        final time = DateTime.fromMillisecondsSinceEpoch(playedAt * 1000);
        total++;
        if (firstAt == 0 || playedAt < firstAt) firstAt = playedAt;
        if (playedAt > lastAt) lastAt = playedAt;
        final day =
            '${time.year.toString().padLeft(4, '0')}-'
            '${time.month.toString().padLeft(2, '0')}-'
            '${time.day.toString().padLeft(2, '0')}';
        daily[day] = (daily[day] ?? 0) + 1;
        hourly[time.hour] += 1;
        weekdayHourly[time.weekday % 7 * 24 + time.hour] += 1;
      }
    }
    final days = daily.keys.toList()..sort();
    return PlayHistoryStats(
      total: total,
      firstAt: firstAt,
      lastAt: lastAt,
      earliestAt: earliestAt,
      daily: days
          .map((day) => PlayHistoryDayCount(day: day, count: daily[day]!))
          .toList(growable: false),
      hourly: List<int>.unmodifiable(hourly),
      weekdayHourly: List<int>.unmodifiable(weekdayHourly),
    );
  }

  @override
  void dispose() {
    _playCountRevision.removeListener(_onStatsSourceChanged);
    AudioLibrary.libraryVersion.removeListener(_onStatsSourceChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final library = AudioLibrary.instance;
    final audios = library.audioCollection;
    final data = _rankings();
    final history = _historyPeriod == _period ? _history : null;
    final hasAnyHistory = (_earliestAt ?? 0) > 0;
    final rankedTracks = (data ?? const <PlayCountRecord>[])
        .take(_rankedLimit)
        .toList(growable: false);
    return PageScaffold(
      title: '统计',
      subtitle: '曲库与收听概览',
      actions: [
        IconButton.filledTonal(
          icon: const Icon(Symbols.refresh),
          tooltip: '刷新',
          onPressed: _loading || _historyLoading ? null : _loadStats,
          style: IconButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
          ),
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(_tabs.length, (i) {
              final selected = _currentIndex == i;
              final canSwitch = canSwitchTab(
                currentIndex: _currentIndex,
                targetIndex: i,
              );
              return _tabButton(scheme, i, selected, canSwitch);
            }),
          ),
          const SizedBox(height: Spacing.md),
          if (_currentIndex == 0 || _currentIndex == 3) ...[
            const SizedBox(height: Spacing.md),
            _periodBar(scheme),
          ],
          const SizedBox(height: Spacing.lg),
          Expanded(
            child: DirectionalTabView(
              index: _currentIndex,
              children: [
                OverviewTab(
                  totalPlays: data == null
                      ? audios.fold<int>(0, (sum, a) => sum + a.playCount)
                      : data.fold<int>(0, (sum, e) => sum + e.playCount),
                  playedTracks: data == null
                      ? audios.where((a) => a.playCount > 0).length
                      : data.length,
                  totalTracks: audios.length,
                  artistCount: _distinctArtistCount(audios),
                  albumCount: _distinctAlbumCount(audios),
                  estimatedListen: _estimatedListenSeconds(audios, data),
                  history: history,
                  hasAnyHistory: hasAnyHistory,
                  period: _period,
                ),
                ArtistsTab(
                  topArtists: buildTopArtists(audios, data),
                  topAlbums: buildTopAlbums(audios, data),
                  onTapArtist: _openArtist,
                  onTapAlbum: _openAlbum,
                ),
                RankedTab(
                  rankedTracks: rankedTracks,
                  totalPlayed: data?.length ?? 0,
                  loading: _loading,
                  loadFailed: _loadFailed,
                ),
                ReportTab(
                  history: history,
                  hasAnyHistory: hasAnyHistory,
                  period: _period,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<PlayCountRecord>? _rankings() {
    final library = AudioLibrary.instance;
    return _topPlayed
        ?.where((entry) => library.audioByPath(entry.path) != null)
        .toList(growable: false);
  }

  int _distinctArtistCount(List<Audio> audios) {
    return audios
        .map((audio) => audio.artist.trim())
        .where((artist) => artist.isNotEmpty)
        .toSet()
        .length;
  }

  int _distinctAlbumCount(List<Audio> audios) {
    return audios
        .map((audio) => audio.album.trim())
        .where((album) => album.isNotEmpty)
        .toSet()
        .length;
  }

  Widget _tabButton(
    ColorScheme scheme,
    int index,
    bool selected,
    bool canSwitch,
  ) {
    return OutlinedButton.icon(
      onPressed: canSwitch ? () => setState(() => _currentIndex = index) : null,
      icon: Icon(_tabs[index].icon, size: 18),
      label: Text(_tabs[index].label),
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(
          selected ? scheme.onSecondaryContainer : scheme.onSurface,
        ),
        backgroundColor: WidgetStatePropertyAll(
          selected ? scheme.secondaryContainer : scheme.surfaceContainerHighest,
        ),
        side: WidgetStatePropertyAll(
          BorderSide(color: selected ? scheme.primary : scheme.outline),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    );
  }

  Widget _periodBar(ColorScheme scheme) {
    return Wrap(
      spacing: Spacing.md,
      runSpacing: Spacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '收听时段',
          style: TextStyle(
            fontSize: AppType.caption,
            color: scheme.onSurfaceVariant,
          ),
        ),
        _modeSelector(scheme),
        _periodPager(scheme),
        if (_historyLoading)
          const SizedBox.square(
            dimension: Spacing.lg,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          )
        else if (_historyFailed)
          Tooltip(
            message: '统计加载失败，点右上角刷新重试',
            child: Icon(Symbols.error_outline, size: 16, color: scheme.error),
          ),
      ],
    );
  }

  Widget _modeSelector(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.smCircular,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _modeButton('日', StatsPeriodMode.day, scheme),
          _modeButton('周', StatsPeriodMode.week, scheme),
          _modeButton('月', StatsPeriodMode.month, scheme),
        ],
      ),
    );
  }

  Widget _modeButton(String label, StatsPeriodMode mode, ColorScheme scheme) {
    final selected = _period.mode == mode;
    return TextButton(
      onPressed: () => _setPeriodMode(mode),
      style: AppButton.pageAction.copyWith(
        animationDuration: MotionDuration.fast,
        backgroundColor: WidgetStatePropertyAll(
          selected ? scheme.secondaryContainer : Colors.transparent,
        ),
        foregroundColor: WidgetStatePropertyAll(
          selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
        ),
        textStyle: WidgetStatePropertyAll(
          TextStyle(
            fontSize: AppType.caption,
            fontWeight: selected
                ? AppType.weightSemibold
                : AppType.weightRegular,
          ),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
        ),
      ),
      child: Text(label),
    );
  }

  Widget _periodPager(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.smCircular,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _pagerButton(
            Symbols.chevron_left,
            '上一时段',
            _canGoBack ? () => _shiftPeriod(-1) : null,
            scheme,
          ),
          SizedBox(
            width: 176,
            child: Text(
              _period.title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.caption,
                fontWeight: AppType.weightSemibold,
                color: scheme.onSurface,
              ),
            ),
          ),
          _pagerButton(
            Symbols.chevron_right,
            '下一时段',
            _canGoForward ? () => _shiftPeriod(1) : null,
            scheme,
          ),
        ],
      ),
    );
  }

  Widget _pagerButton(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed,
    ColorScheme scheme,
  ) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      style: AppButton.iconSquare.copyWith(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? scheme.onSurfaceVariant.withValues(alpha: 0.3)
              : scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  void _openArtist(String name) {
    final artist = AudioLibrary.instance.artistCollection[name];
    if (artist == null) return;
    context.push(app_paths.STATS_ARTIST_DETAIL_PAGE, extra: artist);
  }

  void _openAlbum(String name) {
    final album = AudioLibrary.instance.albumCollection[name];
    if (album == null) return;
    context.push(app_paths.STATS_ALBUM_DETAIL_PAGE, extra: album);
  }

  int _estimatedListenSeconds(List<Audio> audios, List<PlayCountRecord>? data) {
    if (data == null) {
      return audios.fold<int>(
        0,
        (sum, audio) => sum + audio.playCount * audio.duration,
      );
    }
    var total = 0;
    for (final entry in data) {
      final audio = AudioLibrary.instance.audioByPath(entry.path);
      if (audio == null) continue;
      total += entry.playCount * audio.duration;
    }
    return total;
  }
}
