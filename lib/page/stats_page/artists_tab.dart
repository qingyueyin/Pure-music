import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/scroll_aware_future_builder.dart';
import 'package:pure_music/component/stacked_list_view.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/stats_page/stats_shared.dart';

/// 艺术家·专辑 tab：常听艺术家与常听专辑的横向货架。
class ArtistsTab extends StatelessWidget {
  const ArtistsTab({
    super.key,
    required this.topArtists,
    required this.topAlbums,
    required this.onTapArtist,
    required this.onTapAlbum,
  });

  final List<NamedPlayStat> topArtists;
  final List<NamedPlayStat> topAlbums;
  final void Function(String name) onTapArtist;
  final void Function(String name) onTapAlbum;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (topArtists.isEmpty && topAlbums.isEmpty) {
      return SmoothScrollListView(
        padding: const EdgeInsets.only(bottom: Spacing.bottomNav + Spacing.sm),
        children: [
          statsMessage(
            context,
            icon: Symbols.people,
            text: '播放几首歌曲后，这里会出现常听榜单',
            height: 260,
          ),
        ],
      );
    }
    return SmoothScrollListView(
      padding: const EdgeInsets.only(bottom: Spacing.bottomNav + Spacing.sm),
      children: [
        if (topArtists.isNotEmpty)
          _shelfSection(
            context,
            title: '常听艺术家',
            subtitle: '${topArtists.length} 位',
            items: topArtists,
            accent: scheme.tertiary,
            isArtist: true,
            onTap: onTapArtist,
          ),
        if (topAlbums.isNotEmpty)
          _shelfSection(
            context,
            title: '常听专辑',
            subtitle: '${topAlbums.length} 张',
            items: topAlbums,
            accent: scheme.secondary,
            isArtist: false,
            onTap: onTapAlbum,
          ),
      ],
    );
  }

  Widget _shelfSection(
    BuildContext context, {
    required String title,
    required String subtitle,
    required List<NamedPlayStat> items,
    required Color accent,
    required bool isArtist,
    required void Function(String name) onTap,
  }) {
    final maxPlays = items.first.playCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        statsSectionTitle(context, title: title, subtitle: subtitle),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
          child: Wrap(
            spacing: Spacing.md,
            runSpacing: Spacing.md,
            children: [
              for (var index = 0; index < items.length; index++)
                _shelfCard(
                  context,
                  item: items[index],
                  rank: index + 1,
                  maxPlays: maxPlays,
                  accent: accent,
                  isArtist: isArtist,
                  onTap: onTap,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _shelfCard(
    BuildContext context, {
    required NamedPlayStat item,
    required int rank,
    required int maxPlays,
    required Color accent,
    required bool isArtist,
    required void Function(String name) onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fraction = maxPlays > 0 ? item.playCount / maxPlays : 0.0;
    return SizedBox(
      width: 180,
      height: 112,
      child: Container(
        padding: const EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: AppRadius.smCircular,
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: AppRadius.smCircular,
            hoverColor: scheme.onSurface.withValues(alpha: Alpha.hover),
            onTap: () => onTap(item.name),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Text(
                      rank.toString().padLeft(2, '0'),
                      style: TextStyle(
                        fontSize: AppType.caption,
                        fontWeight: AppType.weightSemibold,
                        color: rank <= 3 ? accent : scheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${formatCount(item.playCount)} 次',
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    _itemCover(context, item, isArtist: isArtist),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.subtitle,
                          fontWeight: AppType.weightMedium,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                ClipRRect(
                  borderRadius: AppRadius.xsCircular,
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 4,
                    backgroundColor: scheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      accent.withValues(alpha: 0.72),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 曲库同款封面：艺术家圆头像、专辑方封面；库里查不到时用占位图。
  Widget _itemCover(
    BuildContext context,
    NamedPlayStat item, {
    required bool isArtist,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Icon(
      Symbols.queue_music,
      size: 48,
      color: scheme.onSurface,
    );
    final placeholderBox = Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.22),
        shape: isArtist ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: isArtist ? null : AppRadius.smCircular,
      ),
      child: placeholder,
    );
    final ImageProvider? cached;
    final Future<ImageProvider?> Function() load;
    final String identity;
    if (isArtist) {
      final artist = AudioLibrary.instance.artistCollection[item.name];
      final hasWorks = artist != null && artist.works.isNotEmpty;
      identity = '${artist?.primaryPath ?? item.name}|48';
      cached = hasWorks ? artist.cachedThumbnailPicture(size: 48) : null;
      load = () => hasWorks
          ? artist.thumbnailPicture(size: 48)
          : Future<ImageProvider?>.value(null);
    } else {
      final album = AudioLibrary.instance.albumCollection[item.name];
      final hasWorks = album != null && album.works.isNotEmpty;
      identity = '${album?.primaryPath ?? item.name}|48';
      cached = hasWorks ? album.cachedThumbnailCover(size: 48) : null;
      load = () => hasWorks
          ? album.thumbnailCover(size: 48)
          : Future<ImageProvider?>.value(null);
    }
    return ScrollAwareFutureBuilder<ImageProvider?>(
      identity: identity,
      initialData: cached,
      future: load,
      builder: (context, snapshot) {
        if (snapshot.data == null) return placeholderBox;
        final image = Image(
          image: snapshot.data!,
          width: 48,
          height: 48,
          errorBuilder: (_, _, _) => placeholder,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        );
        if (isArtist) return ClipOval(child: image);
        return ClipRRect(borderRadius: AppRadius.smCircular, child: image);
      },
    );
  }
}
