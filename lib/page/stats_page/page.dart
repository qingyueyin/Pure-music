import 'dart:async';
import 'dart:typed_data';

import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as rust_library_db;
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

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() => _loading = true);
    try {
      final supportPath = (await getAppDataDir()).path;
      final top = await rust_library_db.getTopPlayed(
        indexPath: supportPath,
        limit: 100,
      );
      if (!mounted) return;
      setState(() {
        _topPlayed = top;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PageScaffold(
      title: '统计',
      subtitle: '最常播放的曲目',
      actions: [
        IconButton(
          icon: const Icon(Symbols.refresh),
          tooltip: '刷新',
          onPressed: _loading ? null : _loadStats,
        ),
      ],
      body: _buildBody(scheme),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final data = _topPlayed;
    if (data == null || data.isEmpty) {
      return _buildEmpty(scheme);
    }
    final totalPlays = data.fold(0, (int sum, e) => sum + e.playCount);
    final maxPlays = data.first.playCount;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildSummary(scheme, data.length, totalPlays)),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => _buildRow(scheme, data[i], maxPlays),
            childCount: data.length,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }

  Widget _buildEmpty(ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.bar_chart, size: 64,
              color: scheme.onSurface.withValues(alpha: 0.2)),
          const SizedBox(height: Spacing.lg),
          Text('暂无播放记录', style: TextStyle(
            color: scheme.onSurface.withValues(alpha: 0.45),
            fontSize: AppType.body,
          )),
        ],
      ),
    );
  }

  Widget _buildSummary(ColorScheme scheme, int trackCount, int totalPlays) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.sm, Spacing.sm, Spacing.sm, Spacing.md),
      child: Row(
        children: [
          _statChip(scheme, Symbols.music_note, '$trackCount', '首歌曲'),
          const SizedBox(width: Spacing.md),
          _statChip(scheme, Symbols.play_arrow, formatCount(totalPlays), '次播放'),
        ],
      ),
    );
  }

  Widget _statChip(ColorScheme scheme, IconData icon, String value, String label) {
    return Expanded(
      child: AnimatedContainer(
        duration: MotionDuration.base,
        curve: MotionCurve.standard,
        padding: const EdgeInsets.symmetric(vertical: Spacing.md, horizontal: Spacing.lg),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: AppRadius.smCircular,
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: scheme.primary),
            const SizedBox(width: Spacing.sm),
            Text(value, style: TextStyle(
              fontSize: AppType.hero,
              fontWeight: AppType.weightBold,
              color: scheme.onSurface,
            )),
            const SizedBox(width: Spacing.xs),
            Text(label, style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurface.withValues(alpha: 0.45),
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(ColorScheme scheme, rust_library_db.PlayCountEntry entry, int maxPlays) {
    final fraction = maxPlays > 0 ? entry.playCount / maxPlays : 0.0;
    final audio = AudioLibrary.instance.audioCollection
        .where((a) => a.path == entry.path)
        .firstOrNull;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: MotionDuration.base,
        curve: MotionCurve.standard,
        builder: (context, t, _) {
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 20),
              child: Container(
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: AppRadius.smCircular,
                ),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: AppRadius.smCircular,
                  child: InkWell(
                    borderRadius: AppRadius.smCircular,
                    onTap: audio != null
                        ? () {
                            PlayService.instance.playbackService.play(
                              AudioLibrary.instance.audioCollection.indexOf(audio),
                              AudioLibrary.instance.audioCollection,
                            );
                          }
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.all(Spacing.sm),
                      child: Row(
                        children: [
                          _CoverWidget(audio: audio),
                          const SizedBox(width: Spacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(entry.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppType.subtitle,
                                    color: scheme.onSurface,
                                    fontWeight: AppType.weightMedium,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(entry.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppType.body,
                                    color: scheme.onSurface.withValues(alpha: 0.45),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: Spacing.md),
                          _buildCount(scheme, entry.playCount, fraction),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCount(ColorScheme scheme, int count, double fraction) {
    return SizedBox(
      width: 60,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            formatCount(count),
            style: TextStyle(
              fontSize: AppType.body,
              fontWeight: AppType.weightBold,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 3,
              backgroundColor: scheme.primaryContainer.withValues(alpha: 0.3),
              valueColor: AlwaysStoppedAnimation<Color>(
                scheme.primary.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
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
    if (_cached == null) {
      _load();
    }
  }

  @override
  void didUpdateWidget(_CoverWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audio != widget.audio) {
      final bytes = widget.audio?.smallCoverBytes;
      if (bytes != null) {
        setState(() => _cached = bytes);
      } else {
        setState(() => _cached = null);
        _load();
      }
    }
  }

  Future<void> _load() async {
    final bytes = await widget.audio?.loadSmallCoverBytes();
    if (mounted && bytes != null) {
      setState(() => _cached = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cached != null) {
      return ClipRRect(
        borderRadius: AppRadius.smCircular,
        child: Image.memory(
          _cached!, width: 48, height: 48, fit: BoxFit.cover,
        ),
      );
    }
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: AppRadius.smCircular,
      ),
    );
  }
}

String formatCount(int n) {
  if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}w';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return n.toString();
}
