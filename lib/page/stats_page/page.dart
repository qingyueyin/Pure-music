import 'dart:typed_data';

import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as rust_library_db;
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  List<rust_library_db.PlayCountEntry>? _topPlayed;
  bool _loading = true;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    if (!_loading) {
      setState(() {
        _loading = true;
        _loadFailed = false;
      });
    }
    try {
      final supportPath = (await getAppDataDir()).path;
      final librarySize = AudioLibrary.instance.audioCollection.length;
      final top = await rust_library_db.getTopPlayed(
        indexPath: supportPath,
        limit: librarySize > 100 ? librarySize : 100,
      );
      if (!mounted) return;
      setState(() {
        _topPlayed = top;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
      body: _buildBody(scheme),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    final library = AudioLibrary.instance;
    final audios = library.audioCollection;
    final data = _topPlayed;
    final totalPlays = data == null
        ? audios.fold<int>(0, (sum, audio) => sum + audio.playCount)
        : data.fold<int>(0, (sum, entry) => sum + entry.playCount);
    final playedTracks = data == null
        ? audios.where((audio) => audio.playCount > 0).length
        : data.length;
    final totalDuration = audios.fold<int>(
      0,
      (sum, audio) => sum + audio.duration,
    );
    final topArtists = _buildTopArtists(audios, data);
    final rankedTracks = (data ?? const <rust_library_db.PlayCountEntry>[])
        .take(100)
        .toList();

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.sm,
            Spacing.sm,
            Spacing.sm,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: _buildOverview(
              scheme,
              totalPlays: totalPlays,
              playedTracks: playedTracks,
              totalTracks: audios.length,
              artistCount: library.artistCollection.length,
              albumCount: library.albumCollection.length,
              totalDuration: totalDuration,
            ),
          ),
        ),
        if (topArtists.isNotEmpty)
          SliverToBoxAdapter(child: _buildArtistSection(scheme, topArtists)),
        SliverToBoxAdapter(
          child: _buildSectionTitle(
            scheme,
            title: '最常播放',
            subtitle: _loading
                ? '正在更新'
                : _loadFailed && rankedTracks.isNotEmpty
                ? '刷新失败，显示上次结果'
                : data != null && data.length > rankedTracks.length
                ? '前 ${rankedTracks.length} 首曲目'
                : '${rankedTracks.length} 首曲目',
          ),
        ),
        if (_loading)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
              child: LinearProgressIndicator(
                minHeight: 2,
                backgroundColor: scheme.surfaceContainerHighest.withValues(
                  alpha: 0.35,
                ),
              ),
            ),
          )
        else if (_loadFailed && rankedTracks.isEmpty)
          SliverToBoxAdapter(
            child: _buildMessage(
              scheme,
              icon: Symbols.sync_problem,
              text: '播放记录读取失败',
            ),
          )
        else if (rankedTracks.isEmpty)
          SliverToBoxAdapter(
            child: _buildMessage(
              scheme,
              icon: Symbols.bar_chart,
              text: '播放几首歌曲后，这里会出现排行',
            ),
          )
        else
          SliverList.builder(
            itemCount: rankedTracks.length,
            itemBuilder: (context, index) => _buildRow(
              scheme,
              rankedTracks[index],
              index: index,
              maxPlays: rankedTracks.first.playCount,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: Spacing.bottomNav)),
      ],
    );
  }

  Widget _buildOverview(
    ColorScheme scheme, {
    required int totalPlays,
    required int playedTracks,
    required int totalTracks,
    required int artistCount,
    required int albumCount,
    required int totalDuration,
  }) {
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.smCircular,
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 1000
              ? 4
              : constraints.maxWidth >= 520
              ? 2
              : 1;
          final width =
              (constraints.maxWidth - (columns - 1) * Spacing.sm) / columns;
          return Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              _overviewMetric(
                scheme,
                width: width,
                icon: Symbols.play_arrow,
                color: scheme.primary,
                label: '累计播放',
                value: formatCount(totalPlays),
              ),
              _overviewMetric(
                scheme,
                width: width,
                icon: Symbols.library_music,
                color: scheme.tertiary,
                label: '听过的曲目',
                value: '$playedTracks / $totalTracks',
              ),
              _overviewMetric(
                scheme,
                width: width,
                icon: Symbols.album,
                color: scheme.secondary,
                label: '艺术家 / 专辑',
                value: '$artistCount / $albumCount',
              ),
              _overviewMetric(
                scheme,
                width: width,
                icon: Symbols.schedule,
                color: scheme.onSurfaceVariant,
                label: '曲库总时长',
                value: formatDuration(totalDuration),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _overviewMetric(
    ColorScheme scheme, {
    required double width,
    required IconData icon,
    required Color color,
    required String label,
    required String value,
  }) {
    return SizedBox(
      width: width,
      height: 68,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: AppRadius.smCircular,
              ),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.pageTitle,
                      fontWeight: AppType.weightSemibold,
                      color: scheme.onSurface,
                    ),
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArtistSection(
    ColorScheme scheme,
    List<_ArtistPlayStat> artists,
  ) {
    final maxPlays = artists.first.playCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.sm, Spacing.xl, Spacing.sm, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '常听艺术家',
            style: TextStyle(
              fontSize: AppType.sectionTitle,
              fontWeight: AppType.weightSemibold,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: Spacing.md),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 980
                  ? 3
                  : constraints.maxWidth >= 560
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * Spacing.lg) / columns;
              return Wrap(
                spacing: Spacing.lg,
                runSpacing: Spacing.md,
                children: [
                  for (var i = 0; i < artists.length; i++)
                    SizedBox(
                      width: width,
                      child: _buildArtistStat(
                        scheme,
                        artists[i],
                        rank: i + 1,
                        maxPlays: maxPlays,
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildArtistStat(
    ColorScheme scheme,
    _ArtistPlayStat artist, {
    required int rank,
    required int maxPlays,
  }) {
    final fraction = maxPlays > 0 ? artist.playCount / maxPlays : 0.0;
    return Row(
      children: [
        SizedBox(
          width: 28,
          child: Text(
            rank.toString().padLeft(2, '0'),
            style: TextStyle(
              fontSize: AppType.caption,
              fontWeight: AppType.weightSemibold,
              color: rank <= 3 ? scheme.tertiary : scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      artist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.body,
                        fontWeight: AppType.weightMedium,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Text(
                    '${formatCount(artist.playCount)} 次',
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: AppRadius.xsCircular,
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 3,
                  backgroundColor: scheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    scheme.tertiary.withValues(alpha: 0.72),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionTitle(
    ColorScheme scheme, {
    required String title,
    required String subtitle,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.sm,
        Spacing.xl,
        Spacing.sm,
        Spacing.md,
      ),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: AppType.sectionTitle,
              fontWeight: AppType.weightSemibold,
              color: scheme.onSurface,
            ),
          ),
          const Spacer(),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(
    ColorScheme scheme, {
    required IconData icon,
    required String text,
  }) {
    return SizedBox(
      height: 180,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 40,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
            ),
            const SizedBox(height: Spacing.md),
            Text(
              text,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: AppType.body,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(
    ColorScheme scheme,
    rust_library_db.PlayCountEntry entry, {
    required int index,
    required int maxPlays,
  }) {
    final fraction = maxPlays > 0 ? entry.playCount / maxPlays : 0.0;
    final library = AudioLibrary.instance;
    final audio = library.audioByPath(entry.path);

    return DirectionalListItemEntrance(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: 2,
        ),
        child: SizedBox(
          height: 64,
          child: Material(
            color: Colors.transparent,
            borderRadius: AppRadius.smCircular,
            child: InkWell(
              hoverColor: scheme.onSurface.withValues(alpha: Alpha.hover),
              borderRadius: AppRadius.smCircular,
              onTap: audio == null
                  ? null
                  : () {
                      final audioIndex = library.audioCollection.indexOf(audio);
                      if (audioIndex < 0) return;
                      PlayService.instance.playbackService.play(
                        audioIndex,
                        library.audioCollection,
                      );
                    },
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final showAlbum = constraints.maxWidth >= 760;
                  final albumWidth = constraints.maxWidth >= 1100
                      ? 260.0
                      : 180.0;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 36,
                          child: Text(
                            '${index + 1}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: AppType.caption,
                              fontWeight: index < 3
                                  ? AppType.weightBold
                                  : AppType.weightRegular,
                              color: index < 3
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        _CoverWidget(audio: audio),
                        const SizedBox(width: Spacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                entry.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppType.subtitle,
                                  color: scheme.onSurface,
                                  fontWeight: AppType.weightMedium,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                entry.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppType.body,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (showAlbum) ...[
                          const SizedBox(width: Spacing.lg),
                          SizedBox(
                            width: albumWidth,
                            child: Text(
                              audio?.album ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppType.body,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: Spacing.lg),
                        _buildCount(scheme, entry.playCount, fraction),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCount(ColorScheme scheme, int count, double fraction) {
    return SizedBox(
      width: 84,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${formatCount(count)} 次',
            style: TextStyle(
              fontSize: AppType.body,
              fontWeight: AppType.weightSemibold,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: AppRadius.xsCircular,
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 3,
              backgroundColor: scheme.primaryContainer.withValues(alpha: 0.3),
              valueColor: AlwaysStoppedAnimation<Color>(
                scheme.primary.withValues(alpha: 0.68),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<_ArtistPlayStat> _buildTopArtists(
    List<Audio> audios,
    List<rust_library_db.PlayCountEntry>? entries,
  ) {
    final counts = <String, int>{};
    final source = entries == null
        ? audios
              .where((audio) => audio.playCount > 0)
              .map((audio) => (audio, audio.artist, audio.playCount))
        : entries.map((entry) {
            final audio = AudioLibrary.instance.audioByPath(entry.path);
            return (audio, entry.artist, entry.playCount);
          });
    for (final item in source) {
      final audio = item.$1;
      final artists = audio != null && audio.splitedArtists.isNotEmpty
          ? audio.splitedArtists
          : <String>[item.$2];
      for (final artist in artists) {
        final name = artist.trim();
        if (name.isEmpty) continue;
        counts.update(
          name,
          (value) => value + item.$3,
          ifAbsent: () => item.$3,
        );
      }
    }
    final result =
        counts.entries
            .map((entry) => _ArtistPlayStat(entry.key, entry.value))
            .toList()
          ..sort((a, b) {
            final byCount = b.playCount.compareTo(a.playCount);
            return byCount != 0 ? byCount : a.name.compareTo(b.name);
          });
    return result.take(6).toList(growable: false);
  }
}

class _CoverWidget extends StatefulWidget {
  final Audio? audio;

  const _CoverWidget({required this.audio});

  @override
  State<_CoverWidget> createState() => _CoverWidgetState();
}

class _CoverWidgetState extends State<_CoverWidget> {
  Uint8List? _cached;

  @override
  void initState() {
    super.initState();
    _cached = widget.audio?.smallCoverBytes;
    if (_cached == null) _load();
  }

  @override
  void didUpdateWidget(_CoverWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.audio, widget.audio)) return;
    _cached = widget.audio?.smallCoverBytes;
    if (_cached == null) _load();
  }

  Future<void> _load() async {
    final audio = widget.audio;
    final bytes = await audio?.loadSmallCoverBytes();
    if (mounted && identical(widget.audio, audio) && bytes != null) {
      setState(() => _cached = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cached != null) {
      return ClipRRect(
        borderRadius: AppRadius.smCircular,
        child: Image.memory(
          _cached!,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _placeholder(context),
        ),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: AppRadius.smCircular,
      ),
      child: Icon(
        Symbols.music_note,
        size: 22,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
      ),
    );
  }
}

class _ArtistPlayStat {
  const _ArtistPlayStat(this.name, this.playCount);

  final String name;
  final int playCount;
}

String formatCount(int value) {
  if (value >= 10000) {
    return '${_trimCompact(value / 10000)} 万';
  }
  if (value >= 1000) {
    return '${_trimCompact(value / 1000)} 千';
  }
  return value.toString();
}

String _trimCompact(double value) {
  final formatted = value.toStringAsFixed(1);
  return formatted.endsWith('.0')
      ? formatted.substring(0, formatted.length - 2)
      : formatted;
}

String formatDuration(int seconds) {
  if (seconds <= 0) return '0 分钟';
  final totalMinutes = seconds ~/ 60;
  final days = totalMinutes ~/ (24 * 60);
  final hours = totalMinutes.remainder(24 * 60) ~/ 60;
  final minutes = totalMinutes.remainder(60);
  if (days > 0) return '$days 天 $hours 小时';
  if (hours > 0) return '$hours 小时 $minutes 分钟';
  return '$minutes 分钟';
}
