import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:pure_player_lyric/component/foreground.dart';
import 'package:pure_player_lyric/message.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pure_player_lyric/main.dart' as main_lib show hWnd;
import 'package:win32/win32.dart' as win32;

int? get hWnd => main_lib.hWnd;
set hWnd(int? value) => main_lib.hWnd = value;

class DesktopLyricController {
  ValueNotifier<bool> isPlaying = ValueNotifier(false);
  ValueNotifier<bool> isDarkMode = ValueNotifier(false);
  ValueNotifier<ThemeChangedMessage> theme = ValueNotifier(
    ThemeChangedMessage(
      false,
      Colors.blue.toARGB32(),
      Colors.white.toARGB32(),
      Colors.black.toARGB32(),
    ),
  );
  ValueNotifier<NowPlayingChangedMessage> nowPlaying = ValueNotifier(
    const NowPlayingChangedMessage("", "", ""),
  );
  ValueNotifier<LyricLineChangedMessage> lyricLine = ValueNotifier(
    const LyricLineChangedMessage("", Duration.zero, ""),
  );
  ValueNotifier<LyricProgressChangedMessage> lyricProgress = ValueNotifier(
    const LyricProgressChangedMessage(0, 0, 1.0, false),
  );
  final LinkedHashMap<int, ValueNotifier<LyricProgressChangedMessage>>
  _lineProgress = LinkedHashMap();
  static const int _maxRetainedLineProgress = 8;
  int? _activeLineId;
  int _activeLineLengthMs = 0;

  ValueListenable<LyricProgressChangedMessage> progressForLine(int? lineId) {
    if (lineId == null) return lyricProgress;
    return _lineProgress.putIfAbsent(
      lineId,
      () => ValueNotifier(lyricProgress.value),
    );
  }

  void _publishLyricProgress(LyricProgressChangedMessage message) {
    lyricProgress.value = message;
    final lineId = message.lineId;
    if (lineId == null) return;
    final lineProgress = _lineProgress.putIfAbsent(
      lineId,
      () => ValueNotifier(message),
    );
    if (!identical(lineProgress.value, message)) {
      lineProgress.value = message;
    }
    while (_lineProgress.length > _maxRetainedLineProgress) {
      _lineProgress.remove(_lineProgress.keys.first);
    }
  }

  void _handleLyricLineChanged() {
    final line = lyricLine.value;
    final nextLineId = line.lineId;
    final previousLineId = _activeLineId;
    if (previousLineId != null && previousLineId != nextLineId) {
      final lineProgress = _lineProgress[previousLineId];
      if (lineProgress != null) {
        final snapshot = lineProgress.value;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final transitMs = snapshot.playing
            ? (nowMs - snapshot.sampledAtMs).clamp(0, 60000) *
                  snapshot.playbackRate
            : 0.0;
        final progressMs = (snapshot.progressMs + transitMs)
            .clamp(-60000.0, _activeLineLengthMs.toDouble())
            .round();
        lineProgress.value = LyricProgressChangedMessage(
          progressMs,
          nowMs,
          snapshot.playbackRate,
          false,
          previousLineId,
        );
      }
    }
    _activeLineId = nextLineId;
    _activeLineLengthMs = line.length.inMilliseconds;
  }

  static void initWithArgs(List<String> args) {
    if (args.length != 1) return;

    _instance = DesktopLyricController._();
    try {
      final initArgs = InitArgsMessage.fromJson(json.decode(args.first));
      _instance!.isPlaying.value = initArgs.isPlaying;
      _instance!.nowPlaying.value = NowPlayingChangedMessage(
        initArgs.title,
        initArgs.artist,
        initArgs.album,
      );

      _instance!.isDarkMode.value = initArgs.darkMode;
      _instance!.theme.value = ThemeChangedMessage(
        initArgs.darkMode,
        initArgs.primary,
        initArgs.surfaceContainer,
        initArgs.onSurface,
      );
    } catch (err, stack) {
      stderr.write(err);
      stderr.write(stack);
    }
  }

  static DesktopLyricController? _instance;
  static DesktopLyricController get instance {
    _instance ??= DesktopLyricController._();
    return _instance!;
  }

  String _stdinBuffer = '';

  DesktopLyricController._() {
    lyricLine.addListener(_handleLyricLineChanged);
    stdin.transform(utf8.decoder).listen((event) {
      _stdinBuffer += event;
      while (true) {
        final idx = _stdinBuffer.indexOf('\n');
        if (idx < 0) break;
        final line = _stdinBuffer.substring(0, idx).trimRight();
        _stdinBuffer = _stdinBuffer.substring(idx + 1);
        if (line.isEmpty) continue;
        _handleMessageLine(line);
      }

      if (!_stdinBuffer.contains('\n')) {
        final candidate = _stdinBuffer.trim();
        if (candidate.startsWith('{') && candidate.endsWith('}')) {
          try {
            _handleMessageLine(candidate);
            _stdinBuffer = '';
          } catch (_) {}
        }
      }
    });
  }

  void _handleMessageLine(String raw) {
    try {
      final Map messageMap = json.decode(raw);
      final String type = messageMap["type"];
      final content = messageMap["message"] as Map<String, dynamic>;

      if (type == getMessageTypeName<PlayerStateChangedMessage>()) {
        final playerState = PlayerStateChangedMessage.fromJson(content);
        isPlaying.value = playerState.playing;
      } else if (type == getMessageTypeName<NowPlayingChangedMessage>()) {
        final nowPlayingMessage = NowPlayingChangedMessage.fromJson(content);
        nowPlaying.value = nowPlayingMessage;
        _publishLyricProgress(
          LyricProgressChangedMessage(
            0,
            DateTime.now().millisecondsSinceEpoch,
            1.0,
            isPlaying.value,
          ),
        );
        lyricLine.value = const LyricLineChangedMessage("", Duration.zero);
      } else if (type == getMessageTypeName<LyricLineChangedMessage>()) {
        final lyricLineMessage = LyricLineChangedMessage.fromJson(content);
        final currentProgress = lyricProgress.value;
        _publishLyricProgress(
          LyricProgressChangedMessage(
            lyricLineMessage.progressMs ?? 0,
            DateTime.now().millisecondsSinceEpoch,
            currentProgress.playbackRate,
            isPlaying.value,
            lyricLineMessage.lineId,
          ),
        );
        lyricLine.value = lyricLineMessage;
      } else if (type == getMessageTypeName<LyricProgressChangedMessage>()) {
        final progressMessage = LyricProgressChangedMessage.fromJson(content);
        if (progressMessage.lineId != null &&
            progressMessage.lineId != lyricLine.value.lineId) {
          return;
        }
        _publishLyricProgress(progressMessage);
      } else if (type == getMessageTypeName<ThemeChangedMessage>()) {
        final themeMessage = ThemeChangedMessage.fromJson(content);
        isDarkMode.value = themeMessage.darkMode;
        theme.value = themeMessage;
      } else if (type == getMessageTypeName<DesktopLyricConfigMessage>()) {
        final config = DesktopLyricConfigMessage.fromJson(content);
        textDisplayController.applyConfig(config.toJson());
      } else if (type == getMessageTypeName<UnlockMessage>()) {
        if (hWnd != null) {
          final exStyle = win32.GetWindowLongPtr(hWnd!, win32.GWL_EXSTYLE);
          win32.SetWindowLongPtr(
            hWnd!,
            win32.GWL_EXSTYLE,
            exStyle & ~win32.WS_EX_LAYERED & ~win32.WS_EX_TRANSPARENT,
          );
        }
      }
    } catch (err, stack) {
      stderr.write(err);
      stderr.write(stack);
    }
  }
}
