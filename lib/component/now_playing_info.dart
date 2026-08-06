import 'package:pure_player_lyric/component/foreground.dart';
import 'package:pure_player_lyric/message.dart';
import 'package:pure_player_lyric/desktop_lyric_controller.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class NowPlayingInfo extends StatelessWidget {
  const NowPlayingInfo({super.key});

  @override
  Widget build(BuildContext context) {
    final textDisplayController = context.watch<TextDisplayController>();
    final theme = context.watch<ThemeChangedMessage>();

    final textColor = textDisplayController.hasSpecifiedPlayedColor
        ? textDisplayController.playedColor
        : Color(theme.primary).withValues(alpha: 1.0);
    final textStyle = DefaultTextStyle.of(context).style.merge(
      TextStyle(
        color: textColor,
        fontWeight: lyricFontWeightFromInt(
          textDisplayController.lyricFontWeight,
        ),
      ),
    );
    final outlineColor = lyricOutlineColor(false);
    final textAlign = switch (textDisplayController.lyricTextAlign) {
      LyricTextAlign.left => TextAlign.left,
      LyricTextAlign.center => TextAlign.center,
      LyricTextAlign.right => TextAlign.right,
    };
    final crossAxisAlignment = switch (textDisplayController.lyricTextAlign) {
      LyricTextAlign.left => CrossAxisAlignment.start,
      LyricTextAlign.center => CrossAxisAlignment.center,
      LyricTextAlign.right => CrossAxisAlignment.end,
    };

    return ValueListenableBuilder(
      valueListenable: DesktopLyricController.instance.nowPlaying,
      builder: (context, nowPlaying, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: SizedBox(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: crossAxisAlignment,
              mainAxisSize: MainAxisSize.min,
              children: [
                outlinedText(
                  text: nowPlaying.title,
                  style: textStyle,
                  outlineColor: outlineColor,
                  outlineWidth: lyricOutlineWidth(textStyle.fontSize ?? 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: textAlign,
                  softWrap: false,
                ),
                outlinedText(
                  text: "${nowPlaying.artist} - ${nowPlaying.album}",
                  style: textStyle,
                  outlineColor: outlineColor,
                  outlineWidth: lyricOutlineWidth(textStyle.fontSize ?? 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: textAlign,
                  softWrap: false,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
