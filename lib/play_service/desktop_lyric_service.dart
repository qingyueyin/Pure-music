import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_service.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/utils.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'package:desktop_lyric/message.dart' as msg;

class DesktopLyricService extends ChangeNotifier {
  final PlayService playService;
  DesktopLyricService(this.playService);

  PlaybackService get _playbackService => playService.playbackService;

  Future<Process?> desktopLyric = Future.value(null);
  StreamSubscription? _desktopLyricSubscription;
  String _stdoutBuffer = '';
  Future<void> _sendQueue = Future.value();

  LyricLine? _currentLyricLine;
  Timer? _positionTimer;

  Future<void> startDesktopLyric() async {
    final desktopLyricPath = path.join(
      path.dirname(Platform.resolvedExecutable),
      "desktop_lyric",
      'desktop_lyric.exe',
    );
    if (!File(desktopLyricPath).existsSync()) {
      logger
          .e("[desktop lyric] desktop_lyric.exe not found: $desktopLyricPath");
      return;
    }

    final nowPlaying = _playbackService.nowPlaying;
    final currScheme = ThemeProvider.instance.darkScheme;
    const isDarkMode = true;
    desktopLyric = Process.start(desktopLyricPath, [
      json.encode(msg.InitArgsMessage(
        _playbackService.playerState == PlayerState.playing,
        nowPlaying?.title ?? "无",
        nowPlaying?.artist ?? "无",
        nowPlaying?.album ?? "无",
        isDarkMode,
        currScheme.primary.toARGB32(),
        currScheme.surfaceContainer.toARGB32(),
        currScheme.onSurface.toARGB32(),
      ).toJson())
    ]);

    final process = await desktopLyric;
    _sendQueue = Future.value();

    process?.stderr.transform(utf8.decoder).listen((event) {
      logger.e("[desktop lyric] $event");
    });

    _desktopLyricSubscription = process?.stdout.transform(utf8.decoder).listen(
      (event) {
        _stdoutBuffer += event;
        while (true) {
          final idx = _stdoutBuffer.indexOf('\n');
          if (idx < 0) break;
          final line = _stdoutBuffer.substring(0, idx).trimRight();
          _stdoutBuffer = _stdoutBuffer.substring(idx + 1);
          if (line.isEmpty) continue;
          _handleDesktopLyricMessage(line);
        }

        if (!_stdoutBuffer.contains('\n')) {
          final candidate = _stdoutBuffer.trim();
          if (candidate.startsWith('{') && candidate.endsWith('}')) {
            try {
              _handleDesktopLyricMessage(candidate);
              _stdoutBuffer = '';
            } catch (_) {}
          }
        }
      },
    );

    _stdoutBuffer = '';
    _sendInitialState();
    notifyListeners();
  }

  Future<bool> get canSendMessage => desktopLyric.then(
        (value) => value != null,
      );

  void sendMessage(msg.Message message) {
    _sendQueue = _sendQueue.then((_) async {
      final value = await desktopLyric;
      if (value == null) return;
      try {
        value.stdin.writeln(message.buildMessageJson());
        await value.stdin.flush();
        await Future.delayed(const Duration(milliseconds: 10));
      } catch (err, trace) {
        logger.e(err, stackTrace: trace);
      }
    });
  }

  void killDesktopLyric() {
    _positionTimer?.cancel();
    _positionTimer = null;
    
    desktopLyric.then((value) {
      value?.kill();
      desktopLyric = Future.value(null);
      _sendQueue = Future.value();
      _stdoutBuffer = '';

      _desktopLyricSubscription?.cancel();
      _desktopLyricSubscription = null;

      notifyListeners();
    }).catchError((err, trace) {
      logger.e(err, stackTrace: trace);
    });
  }

  void sendThemeModeMessage(bool darkMode) {
    sendMessage(msg.ThemeModeChangedMessage(darkMode));
  }

  void sendThemeMessage(ColorScheme scheme) {
    final primary = scheme.primary.toARGB32();
    final surfaceContainer = scheme.surfaceContainer.toARGB32();
    final onSurface = scheme.onSurface.toARGB32();
    sendMessage(msg.ThemeChangedMessage(primary, surfaceContainer, onSurface));
    sendMessage(
      msg.PreferenceChangedMessage(primary, surfaceContainer, onSurface),
    );
  }

  void sendPlayerStateMessage(bool isPlaying) {
    sendMessage(msg.PlayerStateChangedMessage(isPlaying));
    
    if (_positionTimer != null) {
      _positionTimer?.cancel();
      _positionTimer = null;
    }
    
    if (isPlaying) {
      _startPositionTimer();
    }
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      _sendPositionMessage();
    });
  }

  void _sendPositionMessage() {
    if (_currentLyricLine is! SyncLyricLine) return;
    
    final line = _currentLyricLine as SyncLyricLine;
    final currentMs = (_playbackService.position * 1000).round();
    final lineStartMs = line.start.inMilliseconds;
    
    if (currentMs < lineStartMs) return;
    
    final words = line.words;
    int wordIndex = -1;
    for (int i = 0; i < words.length; i++) {
      final wordStart = words[i].start.inMilliseconds;
      if (currentMs >= wordStart) {
        wordIndex = i;
      } else {
        break;
      }
    }
    
    if (wordIndex < 0) return;
    
    final currentWord = words[wordIndex];
    final wordStartMs = currentWord.start.inMilliseconds;
    final wordLengthMs = currentWord.length.inMilliseconds;
    
    double progress = 0.0;
    if (wordLengthMs > 0) {
      final elapsed = currentMs - wordStartMs;
      progress = (elapsed / wordLengthMs * 100).clamp(0.0, 100.0);
    }
    
    sendMessage(msg.PositionMessage(wordIndex, progress));
  }

  void sendNowPlayingMessage(Audio nowPlaying) {
    sendMessage(msg.NowPlayingChangedMessage(
      nowPlaying.title,
      nowPlaying.artist,
      nowPlaying.album,
    ));
  }

  void sendLyricLineMessage(LyricLine line, {LyricLine? nextLine}) {
    _currentLyricLine = line;
    
    List<msg.LyricWord>? words;
    if (line is SyncLyricLine) {
      final progressMs = ((_playbackService.position * 1000).round() -
              line.start.inMilliseconds)
          .clamp(0, line.length.inMilliseconds);
      final lineStartMs = line.start.inMilliseconds;
      words = line.words
          .map((w) => msg.LyricWord(
                w.start.inMilliseconds - lineStartMs,
                w.length.inMilliseconds,
                w.content,
              ))
          .toList();
      logger.i("[desktop lyric] sendLyricLineMessage: line is SyncLyricLine, words count = ${words.length}, progressMs=$progressMs");
      if (words.isNotEmpty) {
        logger.i("[desktop lyric] first word: ${words[0].content}, startMs=${words[0].startMs}, lengthMs=${words[0].lengthMs}");
      }
    } else {
      logger.i("[desktop lyric] sendLyricLineMessage: line is ${line.runtimeType}, words = null");
    }

    String? nextContent;
    String? nextTranslation;
    List<msg.LyricWord>? nextWords;
    if (nextLine != null) {
      if (nextLine is SyncLyricLine) {
        nextContent = nextLine.content;
        nextTranslation = nextLine.translation;
        nextWords = nextLine.words
            .map((w) => msg.LyricWord(
                  w.start.inMilliseconds,
                  w.length.inMilliseconds,
                  w.content,
                ))
            .toList();
      } else if (nextLine is UnsyncLyricLine) {
        nextContent = nextLine.content;
        nextTranslation = nextLine.translation;
      }
    }

    if (line is SyncLyricLine) {
      final progressMs = ((_playbackService.position * 1000).round() -
              line.start.inMilliseconds)
          .clamp(0, line.length.inMilliseconds);
      sendMessage(msg.LyricLineChangedMessage(
        line.content,
        line.length,
        line.translation,
        words,
        progressMs,
        nextContent,
        nextTranslation,
        nextWords,
      ));
    } else if (line is LrcLine) {
      final splitted = line.content.split("┃");
      final content = splitted.first;
      final translation = splitted.length > 1 ? splitted[1] : null;
      final progressMs = ((_playbackService.position * 1000).round() -
              line.start.inMilliseconds)
          .clamp(0, line.length.inMilliseconds);
      sendMessage(msg.LyricLineChangedMessage(
        content,
        line.length,
        translation,
        words,
        progressMs,
        nextContent,
        nextTranslation,
        nextWords,
      ));
    }
  }

  void _handleDesktopLyricMessage(String raw) {
    try {
      final Map messageMap = json.decode(raw);
      final String messageType = messageMap["type"];
      final messageContent = messageMap["message"] as Map<String, dynamic>;
      if (messageType == msg.getMessageTypeName<msg.ControlEventMessage>()) {
        final controlEvent = msg.ControlEventMessage.fromJson(messageContent);
        switch (controlEvent.event) {
          case msg.ControlEvent.pause:
            _playbackService.pause();
            break;
          case msg.ControlEvent.start:
            _playbackService.start();
            break;
          case msg.ControlEvent.previousAudio:
            _playbackService.lastAudio();
            break;
          case msg.ControlEvent.nextAudio:
            _playbackService.nextAudio();
            break;
          case msg.ControlEvent.lock:
            logger.i("[desktop lyric] received lock event");
            break;
          case msg.ControlEvent.close:
            killDesktopLyric();
            break;
        }
      }
    } catch (err) {
      logger.e("[desktop lyric] $err");
    }
  }

  void _sendInitialState() {
    final nowPlaying = _playbackService.nowPlaying;
    if (nowPlaying != null) {
      sendNowPlayingMessage(nowPlaying);
    }
    sendPlayerStateMessage(_playbackService.playerState == PlayerState.playing);

    playService.lyricService.currLyricFuture.then((lyric) {
      if (lyric == null) return;
      final posMs = (_playbackService.position * 1000).floor();
      int idx = 0;
      for (int i = 0; i < lyric.lines.length; i++) {
        if (lyric.lines[i].start.inMilliseconds <= posMs) {
          idx = i;
        } else {
          break;
        }
      }
      if (lyric.lines.isEmpty) return;
      final nextLine = idx + 1 < lyric.lines.length ? lyric.lines[idx + 1] : null;
      sendLyricLineMessage(lyric.lines[idx], nextLine: nextLine);
    });
  }
}
