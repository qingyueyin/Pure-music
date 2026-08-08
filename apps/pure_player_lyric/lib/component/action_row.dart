import 'dart:io';

import 'package:pure_player_lyric/component/foreground.dart';
import 'package:pure_player_lyric/message.dart';
import 'package:pure_player_lyric/desktop_lyric_controller.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:win32/win32.dart' as win32;

class ActionRow extends StatelessWidget {
  const ActionRow({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeChangedMessage>();
    final lyricTextAlign = context
        .select<TextDisplayController, LyricTextAlign>(
          (controller) => controller.lyricTextAlign,
        );
    const spacer = SizedBox(width: 8);

    final mainAlignment = switch (lyricTextAlign) {
      LyricTextAlign.left => MainAxisAlignment.start,
      LyricTextAlign.center => MainAxisAlignment.center,
      LyricTextAlign.right => MainAxisAlignment.end,
    };

    return Row(
      mainAxisAlignment: mainAlignment,
      children: [
        if (lyricTextAlign != LyricTextAlign.left) const Spacer(),
        IconButton(
          onPressed: () async {
            final hWnd = win32.GetForegroundWindow();

            if (hWnd != 0) {
              final exStyle = win32.GetWindowLongPtr(hWnd, win32.GWL_EXSTYLE);

              win32.SetWindowLongPtr(
                hWnd,
                win32.GWL_EXSTYLE,
                exStyle | win32.WS_EX_LAYERED | win32.WS_EX_TRANSPARENT,
              );

              stdout.write(
                const ControlEventMessage(ControlEvent.lock).buildMessageJson(),
              );
            }
          },
          color: Color(theme.onSurface),
          icon: const Icon(Icons.lock),
        ),
        spacer,
        IconButton(
          onPressed: () {
            stdout.write(
              const ControlEventMessage(
                ControlEvent.previousAudio,
              ).buildMessageJson(),
            );
          },
          color: Color(theme.onSurface),
          icon: const Icon(Icons.skip_previous),
        ),
        spacer,
        ValueListenableBuilder(
          valueListenable: DesktopLyricController.instance.isPlaying,
          builder: (context, isPlaying, _) => IconButton(
            onPressed: () {
              stdout.write(
                ControlEventMessage(
                  isPlaying ? ControlEvent.pause : ControlEvent.start,
                ).buildMessageJson(),
              );
            },
            color: Color(theme.onSurface),
            icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
          ),
        ),
        spacer,
        IconButton(
          onPressed: () {
            stdout.write(
              const ControlEventMessage(
                ControlEvent.nextAudio,
              ).buildMessageJson(),
            );
          },
          color: Color(theme.onSurface),
          icon: const Icon(Icons.skip_next),
        ),
        spacer,
        IconButton(
          onPressed: () {
            stdout.write(
              const ControlEventMessage(ControlEvent.close).buildMessageJson(),
            );
          },
          color: Color(theme.onSurface),
          icon: const Icon(Icons.close),
        ),
        if (lyricTextAlign != LyricTextAlign.right) const Spacer(),
      ],
    );
  }
}
