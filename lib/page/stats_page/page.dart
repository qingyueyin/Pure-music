import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as rust_library_db;
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/page/stats_page/artists_tab.dart';
import 'package:pure_music/page/stats_page/overview_tab.dart';
import 'package:pure_music/page/stats_page/ranked_tab.dart';
import 'package:pure_music/page/stats_page/report_tab.dart';
import 'package:pure_music/page/stats_page/stats_shared.dart';
import 'package:pure_music/play_service/play_service.dart';

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
  static const _shelfLimit = 12;
  static const _rankedLimit = 100;

  static const _tabs = [
    _StatsTab('概览', Symbols.dashboard),
    _StatsTab('艺术家·专辑', Symbols.people),
    _StatsTab('单曲榜单', Symbols.leaderboard),
    _StatsTab('报告', Symbols.insights),
  ];

  int _currentIndex = 0;
  List<rust_library_db.PlayCountEntry>? _topPlayed;
  rust_library_db.PlayHistoryStats? _history;
  bool _loading = true;
  bool _loadFailed = false;
  int _loadRequestToken = 0;
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

  Future<void> _loadStats() async {
    final requestToken = ++_loadRequestToken;
    if (!_loading) {
      setState(() {
        _loading = true;
        _loadFailed = false;
      });
    }
    try {
      final supportPath = (await getAppDataDir()).path;
      final top = await rust_library_db.getTopPlayed(
        indexPath: supportPath,
        limit: -1,
      );
      final history = await rust_library_db.getPlayHistoryStats(
        indexPath: supportPath,
      );
      final visibleTop = top
          .where(
            (entry) => AudioLibrary.instance.audioByPath(entry.path) != null,
          )
          .toList(growable: false);
      if (!mounted || requestToken != _loadRequestToken) return;
      setState(() {
        _topPlayed = visibleTop;
        _history = history;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestToken != _loadRequestToken) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
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
    final data = _topPlayed;
    final rankedTracks = (data ?? const <rust_library_db.PlayCountEntry>[])
        .take(_rankedLimit)
        .toList(growable: false);
    return PageScaffold(
      title: '统计',
      subtitle: '曲库与收听概览',
      actions: [
        IconButton.filledTonal(
          icon: const Icon(Symbols.refresh),
          tooltip: '刷新',
          onPressed: _loading ? null : _loadStats,
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
                  artistCount: library.artistCollection.length,
                  albumCount: library.albumCollection.length,
                  estimatedListen: _estimatedListenSeconds(audios, data),
                  history: _history,
                ),
                ArtistsTab(
                  topArtists: buildTopArtists(
                    audios,
                    data,
                    limit: _shelfLimit,
                  ),
                  topAlbums: buildTopAlbums(
                    audios,
                    data,
                    limit: _shelfLimit,
                  ),
                  onTapArtist: _openArtist,
                  onTapAlbum: _openAlbum,
                ),
                RankedTab(
                  rankedTracks: rankedTracks,
                  totalPlayed: data?.length ?? 0,
                  loading: _loading,
                  loadFailed: _loadFailed,
                ),
                ReportTab(history: _history),
              ],
            ),
          ),
        ],
      ),
    );
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

  int _estimatedListenSeconds(
    List<Audio> audios,
    List<rust_library_db.PlayCountEntry>? data,
  ) {
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
