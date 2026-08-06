import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_service.dart';
import 'package:pure_music/play_service/lyric_service.dart'
    show
        lyricHighlightCatchUpDurationMs,
        lyricHighlightDeadlineMsForLine,
        lyricHighlightFinishLeadMs,
        desktopLyricPreludeLineAt;
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/desktop_lyric_colors.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/utils.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'package:desktop_lyric/message.dart' as msg;

Duration desktopLyricHighlightDuration(LyricLine line) {
  var duration = line.length;
  if (line is SyncLyricLine && line.words.isNotEmpty) {
    final lastWord = line.words.last;
    final authoredDuration = lastWord.start + lastWord.length - line.start;
    if (authoredDuration > duration) duration = authoredDuration;
  }
  return duration.isNegative ? Duration.zero : duration;
}

/// Windows Job Object 辅助——确保主进程意外终止时子进程被自动关闭
class _WinJobObject {
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>)
      _createJobObject = _kernel32.lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>),
          Pointer<Void> Function(
              Pointer<Void>, Pointer<Utf16>)>('CreateJobObjectW');

  static final int Function(Pointer<Void>, int, Pointer<Void>, int)
      _setInformationJobObject = _kernel32.lookupFunction<
          Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int, Pointer<Void>,
              int)>('SetInformationJobObject');

  static final int Function(Pointer<Void>, int) _assignProcessToJobObject =
      _kernel32.lookupFunction<Int32 Function(Pointer<Void>, IntPtr),
          int Function(Pointer<Void>, int)>('AssignProcessToJobObject');

  static final int Function(Pointer<Void>) _closeHandle =
      _kernel32.lookupFunction<Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)>('CloseHandle');

  static const int _jobObjectExtendedLimitInformation = 9;
  static const int _jobObjectLimitKillOnJobClose = 0x2000;

  /// 创建 Job Object 并将子进程加入。
  /// 当主进程终止（包括崩溃），Windows 会自动终止该 Job 内的所有进程。
  /// 返回 job handle，调用方需持有引用直至不再需要。
  static Pointer<Void>? createAndAssign(int childPid) {
    try {
      // 1) 创建 Job Object
      final job = _createJobObject(nullptr, nullptr);
      if (job == nullptr) {
        logger.w('[desktop lyric] CreateJobObjectW failed');
        return null;
      }

      // 2) 设置 JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
      // JOBOBJECT_EXTENDED_LIMIT_INFORMATION 布局 (x64):
      //   +0x00: BasicLimitInformation.PerProcessUserTimeLimit (LARGE_INTEGER, 8B)
      //   +0x08: BasicLimitInformation.PerJobUserTimeLimit   (LARGE_INTEGER, 8B)
      //   +0x10: BasicLimitInformation.LimitFlags            (DWORD, 4B)
      //   ... 其余字段不需要设置，calloc 已清零
      // 总结构体大小估算为 144B (x64)
      const infoSize = 144;
      final infoPtr = calloc<Uint8>(infoSize);
      // LimitFlags @ offset 0x10
      (infoPtr + 0x10).cast<Uint32>().value = _jobObjectLimitKillOnJobClose;

      final ret = _setInformationJobObject(
        job,
        _jobObjectExtendedLimitInformation,
        infoPtr.cast(),
        infoSize,
      );
      calloc.free(infoPtr);

      if (ret == 0) {
        logger.w('[desktop lyric] SetInformationJobObject failed, closing job');
        _closeHandle(job);
        return null;
      }

      // 3) 将子进程加入 Job
      final assignRet = _assignProcessToJobObject(job, childPid);
      if (assignRet == 0) {
        logger.w('[desktop lyric] AssignProcessToJobObject failed '
            '(进程可能已属于其他 Job)，退化至仅靠心跳超时');
        _closeHandle(job);
        return null;
      }

      logger
          .i('[desktop lyric] Job Object created, child PID=$childPid secured');
      return job;
    } catch (e) {
      logger.w('[desktop lyric] WinJobObject init error: $e');
      return null;
    }
  }

  static void close(Pointer<Void>? job) {
    if (job != null && job != nullptr) {
      _closeHandle(job);
    }
  }
}

class DesktopLyricService extends ChangeNotifier {
  final PlayService playService;
  DesktopLyricService(this.playService) {
    _positionSyncListener = _sendLyricProgressSnapshot;
    _rateListener = _sendLyricProgressSnapshot;
    _playbackService.positionSyncNotifier.addListener(_positionSyncListener);
    _playbackService.rate.addListener(_rateListener);
  }

  PlaybackService get _playbackService => playService.playbackService;

  Process? _process;
  StreamSubscription? _desktopLyricSubscription;
  StreamSubscription? _stderrSubscription;
  static const int _maxStdoutBufferSize = 65536;
  String _stdoutBuffer = '';
  static const int _maxSendQueueSize = 128;
  int _sendQueueSize = 0;
  Future<void> _sendQueue = Future.value();

  bool isLocked = false;
  bool _isKilling = false;
  bool _isRunning = false;

  // ── 位置追踪 / Job Object ──────────────────────────────
  Timer? _progressSyncTimer;
  late final VoidCallback _positionSyncListener;
  late final VoidCallback _rateListener;
  int? _currentLyricLineStartMs;
  int _currentLyricLineLengthMs = 0;
  int? _currentLyricLineId;
  int _nextLyricLineId = 0;
  Pointer<Void>? _jobHandle;

  /// 桌面歌词是否正在运行
  bool get isRunning => _isRunning;

  /// 是否正在关闭中（用于 UI 层禁用按钮）
  bool get isKilling => _isKilling;

  void _monitorProcessExit(Process process) {
    process.exitCode.then((code) {
      logger.i('[desktop lyric] process exited with code: $code');
      if (_isRunning) {
        _cleanupAfterExit();
      }
    }).catchError((e) {
      logger.w('[desktop lyric] process exit monitoring error: $e');
    });
  }

  void _cleanupAfterExit() {
    _desktopLyricSubscription?.cancel().catchError((_) {});
    _stderrSubscription?.cancel().catchError((_) {});
    _desktopLyricSubscription = null;
    _stderrSubscription = null;
    _process = null;
    _sendQueue = Future.value();
    _sendQueueSize = 0;
    _stdoutBuffer = '';
    _isRunning = false;
    _isKilling = false;
    isLocked = false;
    _progressSyncTimer?.cancel();
    _progressSyncTimer = null;
    _currentLyricLineStartMs = null;
    _currentLyricLineLengthMs = 0;
    _WinJobObject.close(_jobHandle);
    _jobHandle = null;
    notifyListeners();
  }

  Future<void> startDesktopLyric() async {
    if (_isRunning) return;

    if (_isKilling) {
      while (_isKilling) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }

    final desktopLyricPath = path.join(
      path.dirname(Platform.resolvedExecutable),
      'desktop_lyric',
      'desktop_lyric.exe',
    );
    if (!File(desktopLyricPath).existsSync()) {
      logger
          .e('[desktop lyric] desktop_lyric.exe not found: $desktopLyricPath');
      return;
    }

    final nowPlaying = _playbackService.nowPlaying;
    final currScheme = ThemeProvider.instance.darkScheme;
    const isDarkMode = true;

    Process process;
    try {
      process = await Process.start(desktopLyricPath, [
        json.encode(msg.InitArgsMessage(
          _playbackService.playerState == PlayerState.playing,
          nowPlaying?.title ?? '无',
          nowPlaying?.artist ?? '无',
          nowPlaying?.album ?? '无',
          isDarkMode,
          currScheme.primary.toARGB32(),
          currScheme.surfaceContainer.toARGB32(),
          currScheme.onSurface.toARGB32(),
        ).toJson())
      ]);
    } catch (e) {
      logger.e('[desktop lyric] failed to start process: $e');
      return;
    }

    _process = process;
    _isRunning = true;
    _sendQueue = Future.value();
    _sendQueueSize = 0;

    _stderrSubscription = process.stderr.transform(utf8.decoder).listen(
          (event) => logger.e('[desktop lyric] $event'),
        );

    _desktopLyricSubscription = process.stdout.transform(utf8.decoder).listen(
      (event) {
        if (_stdoutBuffer.length > _maxStdoutBufferSize) {
          _stdoutBuffer = _stdoutBuffer.substring(_stdoutBuffer.length ~/ 2);
          logger.w('[desktop lyric] stdout buffer truncated');
        }
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
    _monitorProcessExit(process);
    _sendInitialState();
    _sendInitialConfig();
    _startProgressSync();

    // ── 创建 Windows Job Object（崩溃保护） ──
    if (Platform.isWindows) {
      _jobHandle = _WinJobObject.createAndAssign(process.pid);
    }

    notifyListeners();
  }

  Future<bool> get canSendMessage async => _process != null && _isRunning;

  void sendMessage(msg.Message message) {
    if (_process == null || !_isRunning) return;
    if (_sendQueueSize > _maxSendQueueSize) return;

    _sendQueueSize++;
    _sendQueue = _sendQueue.then((_) async {
      _sendQueueSize--;
      final proc = _process;
      if (proc == null || !_isRunning) return;
      try {
        proc.stdin.writeln(message.buildMessageJson());
        await proc.stdin.flush();
      } catch (err, trace) {
        logger.e('[desktop lyric] send message error: $err', stackTrace: trace);
        _process = null;
        _isRunning = false;
      }
    }).catchError((e) {
      _sendQueueSize--;
      logger.w('[desktop lyric] send queue error: $e');
    });
  }

  Future<void> killDesktopLyric() async {
    if (!_isRunning) return;

    _isKilling = true;
    notifyListeners();

    final process = _process;
    if (process != null) {
      try {
        final alreadyExited = await process.exitCode
            .timeout(
              const Duration(milliseconds: 200),
            )
            .then((_) => true)
            .catchError((_) => false);

        if (!alreadyExited) {
          if (Platform.isWindows) {
            Process.run('taskkill', ['/pid', '${process.pid}', '/f'])
                .catchError((_) => ProcessResult(0, 1, '', ''));
          } else {
            process.kill(ProcessSignal.sigterm);
          }
        }
      } catch (e) {
        logger.w('[desktop lyric] killDesktopLyric error: $e');
      }
    }

    _cleanupAfterExit();
  }

  void sendConfig({
    double? lyricFontSize,
    double? translationFontSize,
    int? lyricFontWeight,
    bool? showLyricTranslation,
    bool? showRoman,
    int? romanPosition,
    bool? showNowPlayingInfo,
    int? lyricTextAlign,
    int? lyricAnimation,
    bool? enableStroke,
    double? backgroundOpacity,
    int? playedColor,
    int? unplayedColor,
    bool? followThemeColor,
    bool? useLightOutline,
  }) {
    sendMessage(msg.DesktopLyricConfigMessage(
      lyricFontSize: lyricFontSize,
      translationFontSize: translationFontSize,
      lyricFontWeight: lyricFontWeight,
      showLyricTranslation: showLyricTranslation,
      showRoman: showRoman,
      romanPosition: romanPosition,
      showNowPlayingInfo: showNowPlayingInfo,
      lyricTextAlign: lyricTextAlign,
      lyricAnimation: lyricAnimation,
      enableStroke: enableStroke,
      backgroundOpacity: backgroundOpacity,
      playedColor: playedColor,
      unplayedColor: unplayedColor,
      followThemeColor: followThemeColor,
      useLightOutline: useLightOutline,
    ));
  }

  void sendUnlockMessage() {
    sendMessage(const msg.UnlockMessage());
    isLocked = false;
    notifyListeners();
  }

  void sendThemeMessage(ColorScheme scheme, {bool darkMode = false}) {
    final primary = scheme.primary.toARGB32();
    final surfaceContainer = scheme.surfaceContainer.toARGB32();
    final onSurface = scheme.onSurface.toARGB32();
    sendMessage(msg.ThemeChangedMessage(
        darkMode, primary, surfaceContainer, onSurface));
    final colors = resolveDesktopLyricColors(
      followThemeColor: AppSettings.instance.desktopFollowThemeColor,
      brightnessMode: AppSettings.instance.desktopLyricBrightnessMode,
      scheme: scheme,
    );
    sendConfig(
      followThemeColor: AppSettings.instance.desktopFollowThemeColor,
      useLightOutline: shouldUseLightDesktopLyricOutline(colors.played),
      playedColor: colors.played.toARGB32(),
      unplayedColor: colors.unplayed.toARGB32(),
    );
  }

  void sendPlayerStateMessage(bool isPlaying) {
    sendMessage(msg.PlayerStateChangedMessage(isPlaying));
    _sendLyricProgressSnapshot();
  }

  void sendNowPlayingMessage(Audio nowPlaying) {
    _currentLyricLineStartMs = null;
    _currentLyricLineLengthMs = 0;
    _currentLyricLineId = null;
    sendMessage(msg.NowPlayingChangedMessage(
      nowPlaying.title,
      nowPlaying.artist,
      nowPlaying.album,
    ));
  }

  void sendLyricLineMessage(
    LyricLine line, {
    LyricLine? nextLine,
    required bool isWordByWord,
    int? highlightDeadlineMs,
  }) {
    final lineStartMs = line.start.inMilliseconds;
    final highlightDuration = desktopLyricHighlightDuration(line);
    final lineLengthMs = highlightDuration.inMilliseconds;
    final lineId = ++_nextLyricLineId;
    final progressMs =
        ((_playbackService.position * 1000).round() - lineStartMs)
            .clamp(-60000, lineLengthMs);
    _currentLyricLineStartMs = lineStartMs;
    _currentLyricLineLengthMs = lineLengthMs;
    _currentLyricLineId = lineId;
    final relativeHighlightDeadlineMs =
        highlightDeadlineMs == null ? null : highlightDeadlineMs - lineStartMs;

    List<msg.LyricWord>? words;
    if (line is SyncLyricLine) {
      words = line.words
          .map((w) => msg.LyricWord(
                w.start.inMilliseconds - lineStartMs,
                w.length.inMilliseconds,
                w.content,
              ))
          .toList();
      logger.i(
          '[desktop lyric] sendLyricLineMessage: line is SyncLyricLine, words count = ${words.length}, progressMs=$progressMs');
      if (words.isNotEmpty) {
        logger.i(
            '[desktop lyric] first word: ${words[0].content}, startMs=${words[0].startMs}, lengthMs=${words[0].lengthMs}');
      }
    } else {
      logger.i(
          '[desktop lyric] sendLyricLineMessage: line is ${line.runtimeType}, words = null');
    }

    String? nextContent;
    String? nextTranslation;
    String? nextRomanLyric;
    List<msg.LyricWord>? nextWords;
    if (nextLine != null) {
      if (nextLine is SyncLyricLine) {
        nextContent = nextLine.content;
        nextTranslation = nextLine.translation;
        nextRomanLyric = nextLine.romanLyric;
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
        nextRomanLyric = nextLine.romanLyric;
      }
    }

    if (line is SyncLyricLine) {
      sendMessage(msg.LyricLineChangedMessage(
        line.content,
        highlightDuration,
        line.translation,
        words,
        progressMs,
        nextContent,
        nextTranslation,
        nextWords,
        line.romanLyric,
        nextRomanLyric,
        isWordByWord,
        lineId,
        relativeHighlightDeadlineMs,
        lyricHighlightCatchUpDurationMs,
        lyricHighlightFinishLeadMs,
      ));
    } else if (line is LrcLine) {
      sendMessage(msg.LyricLineChangedMessage(
        line.content,
        highlightDuration,
        line.translation,
        words,
        progressMs,
        nextContent,
        nextTranslation,
        nextWords,
        line.romanLyric,
        nextRomanLyric,
        isWordByWord,
        lineId,
        relativeHighlightDeadlineMs,
        lyricHighlightCatchUpDurationMs,
        lyricHighlightFinishLeadMs,
      ));
    }
    _sendLyricProgressSnapshot();
  }

  void _startProgressSync() {
    _progressSyncTimer?.cancel();
    _progressSyncTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _sendLyricProgressSnapshot(),
    );
  }

  void _sendLyricProgressSnapshot() {
    final lineStartMs = _currentLyricLineStartMs;
    final lineId = _currentLyricLineId;
    if (!_isRunning ||
        _process == null ||
        lineStartMs == null ||
        lineId == null) {
      return;
    }
    final progressMs =
        ((_playbackService.position * 1000).round() - lineStartMs)
            .clamp(-60000, _currentLyricLineLengthMs);
    sendMessage(msg.LyricProgressChangedMessage(
      progressMs,
      DateTime.now().millisecondsSinceEpoch,
      _playbackService.rate.value,
      _playbackService.playerState == PlayerState.playing,
      lineId,
    ));
  }

  void _handleDesktopLyricMessage(String raw) {
    try {
      final Map messageMap = json.decode(raw);
      final String messageType = messageMap['type'];
      final messageContent = messageMap['message'] as Map<String, dynamic>;
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
            isLocked = true;
            notifyListeners();
            break;
          case msg.ControlEvent.close:
            killDesktopLyric();
            break;
        }
      }
    } catch (err) {
      logger.e('[desktop lyric] $err');
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
      if (lyric.lines.isEmpty) return;
      final positionMs = (_playbackService.position * 1000).round();
      final preludeLine = desktopLyricPreludeLineAt(lyric, positionMs);
      if (preludeLine != null) {
        sendLyricLineMessage(
          preludeLine,
          nextLine: lyric.lines.first,
          isWordByWord: lyric.isWordByWord,
        );
        return;
      }
      final update = playService.lyricService.lineUpdateForLyric(
        lyric,
        _playbackService.position,
      );
      final idx = update?.primaryIndex;
      if (idx == null || idx < 0 || idx >= lyric.lines.length) return;
      final nextLine =
          idx + 1 < lyric.lines.length ? lyric.lines[idx + 1] : null;
      sendLyricLineMessage(
        lyric.lines[idx],
        nextLine: nextLine,
        isWordByWord: lyric.isWordByWord,
        highlightDeadlineMs: lyricHighlightDeadlineMsForLine(lyric, idx),
      );
    });
  }

  void _sendInitialConfig() {
    final settings = AppSettings.instance;
    final scheme = ThemeProvider.instance.currScheme;
    final colors = resolveDesktopLyricColors(
      followThemeColor: settings.desktopFollowThemeColor,
      brightnessMode: settings.desktopLyricBrightnessMode,
      scheme: scheme,
    );
    sendConfig(
      showRoman: settings.showDesktopLyricRoman,
      romanPosition: settings.desktopLyricRomanPosition,
      lyricAnimation: settings.desktopLyricAnimation.index,
      enableStroke: settings.desktopEnableStroke,
      playedColor: colors.played.toARGB32(),
      unplayedColor: colors.unplayed.toARGB32(),
      followThemeColor: settings.desktopFollowThemeColor,
      useLightOutline: shouldUseLightDesktopLyricOutline(colors.played),
    );
  }

  @override
  void dispose() {
    // 停止桌面歌词进程
    if (_process != null) {
      _process?.kill(ProcessSignal.sigterm);
      _process = null;
    }
    // 取消所有 Stream 订阅
    _desktopLyricSubscription?.cancel();
    _desktopLyricSubscription = null;
    _stderrSubscription?.cancel();
    _stderrSubscription = null;
    _progressSyncTimer?.cancel();
    _progressSyncTimer = null;
    _playbackService.positionSyncNotifier.removeListener(_positionSyncListener);
    _playbackService.rate.removeListener(_rateListener);
    // 释放 Job Object 句柄
    _WinJobObject.close(_jobHandle);
    _jobHandle = null;

    _isRunning = false;
    _isKilling = false;
    super.dispose();
  }
}
