import 'dart:async';

import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/page_scaffold.dart';
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.bar_chart, size: 64,
                color: scheme.onSurface.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text('暂无播放记录', style: TextStyle(
              color: scheme.onSurface.withValues(alpha: 0.5),
              fontSize: 16,
            )),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: data.length,
      itemBuilder: (context, i) {
        final entry = data[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: scheme.primaryContainer.withValues(alpha: 0.3),
            child: Text('${i + 1}', style: TextStyle(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            )),
          ),
          title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(entry.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${entry.playCount}', style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              )),
              Text('次播放', style: TextStyle(
                color: scheme.onSurface.withValues(alpha: 0.5),
                fontSize: 12,
              )),
            ],
          ),
          onTap: () {
            final audio = AudioLibrary.instance.audioCollection
                .where((a) => a.path == entry.path)
                .firstOrNull;
            if (audio != null) {
              showTextOnSnackBar('${audio.title} - ${audio.artist}');
            }
          },
        );
      },
    );
  }
}
