import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/ttml.dart' show Ttml;
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_service.dart';
import 'package:pure_music/play_service/lyric_service.dart'
    show
        lyricHighlightCatchUpDurationMs,
        lyricHighlightDeadlineMsForLine,
        lyricHighlightFinishLeadMs,
        desktopLyricPreludeLineAt,
        isDesktopLyricTransitionLine;
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
  if (line is SyncLyricLine) {
    if (line.bgEnd != null) {
      final authoredDuration = line.bgEnd! - line.start;
      if (authoredDuration > duration) duration = authoredDuration;
    }
    if (line.bgWords.isNotEmpty) {
      final lastWord = line.bgWords.last;
      final authoredDuration = lastWord.start + lastWord.length - line.start;
      if (authoredDuration > duration) duration = authoredDuration;
    }
  }
  return duration.isNegative ? Duration.zero : duration;
}

/// Windows Job Object 辅助——确保主进程意外终止时子进程被自动关闭
class _WinJobObject {
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>)
  _createJobObject = _kernel32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>)
      >('CreateJobObjectW');

  static final int Function(Pointer<Void>, int, Pointer<Void>, int)
  _setInformationJobObject = _kernel32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Void>, int)
      >('SetInformationJobObject');

  static final int Function(Pointer<Void>, Pointer<Void>)
  _assignProcessToJobObject = _kernel32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)
      >('AssignProcessToJobObject');

  static final Pointer<Void> Function(int, int, int) _openProcess = _kernel32
      .lookupFunction<
        Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)
      >('OpenProcess');

  static final int Function(Pointer<Void>) _closeHandle = _kernel32
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');

  static const int _jobObjectExtendedLimitInformation = 9;
  static const int _jobObjectLimitKillOnJobClose = 0x2000;
  static const int _processTerminate = 0x0001;
  static const int _processSetQuota = 0x0100;

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
      final process = _openProcess(
        _processSetQuota | _processTerminate,
        0,
        childPid,
      );
      if (process == nullptr) {
        logger.w('[desktop lyric] OpenProcess failed, closing job');
        _closeHandle(job);
        return null;
      }

      try {
        final assignRet = _assignProcessToJobObject(job, process);
        if (assignRet == 0) {
          logger.w(
            '[desktop lyric] AssignProcessToJobObject failed '
            '(进程可能已属于其他 Job)，退化至仅靠心跳超时',
          );
          _closeHandle(job);
          return null;
        }

        logger.i(
          '[desktop lyric] Job Object created, child PID=$childPid secured',
        );
        return job;
      } finally {
        _closeHandle(process);
      }
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
  late final msg.MessageFrameDecoder _stdoutDecoder = msg.MessageFrameDecoder(
    maxBufferLength: _maxStdoutBufferSize,
    onOverflow: () => logger.w('[desktop lyric] stdout buffer truncated'),
  );
  static const int _maxSendQueueSize = 128;
  int _sendQueueSize = 0;
  Future<void> _sendQueue = Future.value();
  int _processGeneration = 0;

  bool isLocked = false;
  bool _isStarting = false;
  bool _isKilling = false;
  bool _isRunning = false;

  // ── 位置追踪 / Job Object ──────────────────────────────
  Timer? _progressSyncTimer;
  late final VoidCallback _positionSyncListener;
  late final VoidCallback _rateListener;
  int? _currentLyricLineStartMs;
  int _currentLyricLineLengthMs = 0;
  int? _currentLyricLineId;
  Lyric? _mappedLyric;
  final Map<int, int> _lineIdByIndex = <int, int>{};
  final Map<int, int> _gapLineIdByStart = <int, int>{};
  int _nextLyricLineId = 0;
  int _nextSyntheticLineId = -1;
  Pointer<Void>? _jobHandle;

  /// 桌面歌词是否正在运行
  bool get isRunning => _isRunning;

  /// 是否正在关闭中（用于 UI 层禁用按钮）
  bool get isKilling => _isKilling;

  void _monitorProcessExit(Process process, int generation) {
    process.exitCode
        .then((code) {
          logger.i('[desktop lyric] process exited with code: $code');
          _cleanupAfterExit(
            expectedProcess: process,
            expectedGeneration: generation,
          );
        })
        .catchError((e) {
          logger.w('[desktop lyric] process exit monitoring error: $e');
        });
  }

  void _cleanupAfterExit({Process? expectedProcess, int? expectedGeneration}) {
    if (expectedProcess != null && !identical(_process, expectedProcess)) {
      return;
    }
    if (expectedGeneration != null &&
        expectedGeneration != _processGeneration) {
      return;
    }
    _processGeneration++;
    _desktopLyricSubscription?.cancel().catchError((_) {});
    _stderrSubscription?.cancel().catchError((_) {});
    _desktopLyricSubscription = null;
    _stderrSubscription = null;
    _process = null;
    _sendQueue = Future.value();
    _sendQueueSize = 0;
    _stdoutDecoder.clear();
    _isRunning = false;
    _isKilling = false;
    isLocked = false;
    _progressSyncTimer?.cancel();
    _progressSyncTimer = null;
    _currentLyricLineStartMs = null;
    _currentLyricLineLengthMs = 0;
    _currentLyricLineId = null;
    _mappedLyric = null;
    _lineIdByIndex.clear();
    _gapLineIdByStart.clear();
    _nextLyricLineId = 0;
    _nextSyntheticLineId = -1;
    _WinJobObject.close(_jobHandle);
    _jobHandle = null;
    notifyListeners();
  }

  Future<void> startDesktopLyric() async {
    if (_isRunning || _isStarting) return;
    _isStarting = true;

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
      logger.e(
        '[desktop lyric] desktop_lyric.exe not found: $desktopLyricPath',
      );
      _isStarting = false;
      return;
    }

    final nowPlaying = _playbackService.nowPlaying;
    final currScheme = ThemeProvider.instance.darkScheme;
    const isDarkMode = true;

    Process process;
    try {
      process = await Process.start(desktopLyricPath, [
        json.encode(
          msg.InitArgsMessage(
            _playbackService.playerState == PlayerState.playing,
            nowPlaying?.title ?? '无',
            nowPlaying?.artist ?? '无',
            nowPlaying?.album ?? '无',
            isDarkMode,
            currScheme.primary.toARGB32(),
            currScheme.surfaceContainer.toARGB32(),
            currScheme.onSurface.toARGB32(),
          ).toJson(),
        ),
      ]);
    } catch (e) {
      logger.e('[desktop lyric] failed to start process: $e');
      _isStarting = false;
      return;
    }

    final generation = ++_processGeneration;
    _process = process;
    _isRunning = true;
    _isStarting = false;
    _sendQueue = Future.value();
    _sendQueueSize = 0;

    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .listen((event) => logger.e('[desktop lyric] $event'));

    _desktopLyricSubscription = process.stdout.transform(utf8.decoder).listen((
      event,
    ) {
      _stdoutDecoder.add(event, _handleDesktopLyricMessage);
    });

    _stdoutDecoder.clear();
    _monitorProcessExit(process, generation);
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
    final process = _process;
    final generation = _processGeneration;
    if (process == null || !_isRunning) return;
    if (_sendQueueSize >= _maxSendQueueSize) return;

    _sendQueueSize++;
    _sendQueue = _sendQueue
        .then((_) async {
          if (generation != _processGeneration ||
              !identical(process, _process) ||
              !_isRunning) {
            return;
          }
          try {
            process.stdin.writeln(message.buildMessageJson());
            await process.stdin.flush();
          } catch (err, trace) {
            logger.e(
              '[desktop lyric] send message error: $err',
              stackTrace: trace,
            );
            _cleanupAfterExit(
              expectedProcess: process,
              expectedGeneration: generation,
            );
          }
        })
        .catchError((e) {
          logger.w('[desktop lyric] send queue error: $e');
        })
        .whenComplete(() {
          if (generation == _processGeneration && _sendQueueSize > 0) {
            _sendQueueSize--;
          }
        });
  }

  Future<void> killDesktopLyric() async {
    if (!_isRunning) return;

    _isKilling = true;
    notifyListeners();

    final process = _process;
    final generation = _processGeneration;
    if (process != null) {
      try {
        final alreadyExited = await process.exitCode
            .timeout(const Duration(milliseconds: 200))
            .then((_) => true)
            .catchError((_) => false);

        if (!alreadyExited) {
          if (Platform.isWindows) {
            Process.run('taskkill', [
              '/pid',
              '${process.pid}',
              '/f',
            ]).catchError((_) => ProcessResult(0, 1, '', ''));
          } else {
            process.kill(ProcessSignal.sigterm);
          }
        }
      } catch (e) {
        logger.w('[desktop lyric] killDesktopLyric error: $e');
      }
    }

    _cleanupAfterExit(expectedProcess: process, expectedGeneration: generation);
  }

  void sendConfig({
    double? lyricFontSize,
    double? translationFontSize,
    int? lyricFontWeight,
    bool? showLyricTranslation,
    bool? showRoman,
    int? romanPosition,
    int? translationPosition,
    bool? showNowPlayingInfo,
    bool? hideOnPause,
    int? lyricTextAlign,
    int? lyricAnimation,
    bool? enableStroke,
    double? backgroundOpacity,
    int? playedColor,
    int? unplayedColor,
    bool? followThemeColor,
    bool? useLightOutline,
    bool? useVerticalDisplayMode,
    bool? showDoubleLine,
    bool? hoverHide,
    bool? fullscreenHide,
    double? lineGap,
    bool? enablePinTop,
    bool? useMultiLineMode,
    int? multiLineAnimation,
    bool? hidePlayedLines,
    double? fontOpacity,
  }) {
    sendMessage(
      msg.DesktopLyricConfigMessage(
        lyricFontSize: lyricFontSize,
        translationFontSize: translationFontSize,
        lyricFontWeight: lyricFontWeight,
        showLyricTranslation: showLyricTranslation,
        showRoman: showRoman,
        romanPosition: romanPosition,
        translationPosition: translationPosition,
        showNowPlayingInfo: showNowPlayingInfo,
        hideOnPause: hideOnPause,
        lyricTextAlign: lyricTextAlign,
        lyricAnimation: lyricAnimation,
        enableStroke: enableStroke,
        backgroundOpacity: backgroundOpacity,
        playedColor: playedColor,
        unplayedColor: unplayedColor,
        followThemeColor: followThemeColor,
        useLightOutline: useLightOutline,
        useVerticalDisplayMode: useVerticalDisplayMode,
        showDoubleLine: showDoubleLine,
        hoverHide: hoverHide,
        fullscreenHide: fullscreenHide,
        lineGap: lineGap,
        enablePinTop: enablePinTop,
        useMultiLineMode: useMultiLineMode,
        multiLineAnimation: multiLineAnimation,
        hidePlayedLines: hidePlayedLines,
        fontOpacity: fontOpacity,
      ),
    );
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
    sendMessage(
      msg.ThemeChangedMessage(darkMode, primary, surfaceContainer, onSurface),
    );
    final colors = resolveDesktopLyricColors(
      followThemeColor: AppSettings.instance.desktopFollowThemeColor,
      brightnessMode: AppSettings.instance.desktopLyricBrightnessMode,
      scheme: scheme,
      customPlayedColor: AppSettings.instance.desktopPlayedColor,
      customUnplayedColor: AppSettings.instance.desktopUnplayedColor,
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
    _mappedLyric = null;
    _lineIdByIndex.clear();
    _gapLineIdByStart.clear();
    _nextLyricLineId = 0;
    _nextSyntheticLineId = -1;
    sendMessage(
      msg.NowPlayingChangedMessage(
        nowPlaying.title,
        nowPlaying.artist,
        nowPlaying.album,
      ),
    );
  }

  void sendLyricLineMessage(
    LyricLine line, {
    LyricLine? nextLine,
    required bool isWordByWord,
    int? highlightDeadlineMs,
    int? lineIndex,
    int? syntheticLineId,
  }) {
    final lineStartMs = line.start.inMilliseconds;
    final highlightDuration = desktopLyricHighlightDuration(line);
    final lineLengthMs = highlightDuration.inMilliseconds;
    final lineId =
        syntheticLineId ??
        (lineIndex == null
            ? _nextSyntheticLineId--
            : _lineIdForIndex(lineIndex));
    final progressMs =
        ((_playbackService.position * 1000).round() - lineStartMs).clamp(
          -60000,
          lineLengthMs,
        );
    _currentLyricLineStartMs = lineStartMs;
    _currentLyricLineLengthMs = lineLengthMs;
    _currentLyricLineId = lineId;
    final relativeHighlightDeadlineMs = highlightDeadlineMs == null
        ? null
        : highlightDeadlineMs - lineStartMs;

    List<msg.LyricWord>? words;
    if (line is SyncLyricLine) {
      words = line.words
          .map(
            (w) => msg.LyricWord(
              w.start.inMilliseconds - lineStartMs,
              w.length.inMilliseconds,
              w.content,
            ),
          )
          .toList();
      logger.i(
        '[desktop lyric] sendLyricLineMessage: line is SyncLyricLine, words count = ${words.length}, progressMs=$progressMs',
      );
      if (words.isNotEmpty) {
        logger.i(
          '[desktop lyric] first word: ${words[0].content}, startMs=${words[0].startMs}, lengthMs=${words[0].lengthMs}',
        );
      }
    } else {
      logger.i(
        '[desktop lyric] sendLyricLineMessage: line is ${line.runtimeType}, words = null',
      );
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
            .map(
              (w) => msg.LyricWord(
                w.start.inMilliseconds,
                w.length.inMilliseconds,
                w.content,
              ),
            )
            .toList();
      } else if (nextLine is UnsyncLyricLine) {
        nextContent = nextLine.content;
        nextTranslation = nextLine.translation;
        nextRomanLyric = nextLine.romanLyric;
      }
    }

    if (line is SyncLyricLine) {
      sendMessage(
        msg.LyricLineChangedMessage(
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
        ),
      );
    } else if (line is LrcLine) {
      sendMessage(
        msg.LyricLineChangedMessage(
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
        ),
      );
    }
    _sendLyricProgressSnapshot();
  }

  int _lineIdForIndex(int index) {
    final existing = _lineIdByIndex[index];
    if (existing != null) return existing;
    final lineId = ++_nextLyricLineId;
    _lineIdByIndex[index] = lineId;
    return lineId;
  }

  int _gapLineIdForStart(int startMs) {
    return _gapLineIdByStart.putIfAbsent(startMs, () => _nextSyntheticLineId--);
  }

  int syntheticLineIdForStart(int startMs) => _gapLineIdForStart(startMs);

  void sendFullLyricMessage(Lyric lyric) {
    if (!identical(_mappedLyric, lyric)) {
      _mappedLyric = lyric;
      _lineIdByIndex.clear();
      _gapLineIdByStart.clear();
      _nextLyricLineId = 0;
      _nextSyntheticLineId = -1;
    }
    final switchStartMs = playService.lyricService.switchStartMsForLyric(lyric);
    final lines = <msg.FullLyricLine>[];
    for (var index = 0; index < lyric.lines.length; index++) {
      final line = lyric.lines[index];
      final content = _desktopLyricLineContent(line);
      final isTransition = isDesktopLyricTransitionLine(line);
      if ((content == null || content.trim().isEmpty) && !isTransition) {
        continue;
      }
      final startMs = _desktopLyricLineStartMs(line);
      final endMs = _desktopLyricLineEndMs(lyric, line);
      final words = line is SyncLyricLine
          ? line.words
                .map(
                  (word) => msg.LyricWord(
                    word.start.inMilliseconds - line.start.inMilliseconds,
                    word.length.inMilliseconds,
                    word.content,
                  ),
                )
                .toList(growable: false)
          : null;
      final highlightDeadlineMs = isTransition
          ? null
          : lyricHighlightDeadlineMsForLine(lyric, index);
      lines.add(
        msg.FullLyricLine(
          isTransition ? _gapLineIdForStart(startMs) : _lineIdForIndex(index),
          isTransition ? null : content,
          isTransition ? null : line.translation,
          isTransition ? null : line.romanLyric,
          line.start.inMilliseconds,
          endMs - line.start.inMilliseconds,
          isTransition ? null : words,
          highlightDeadlineMs == null
              ? null
              : highlightDeadlineMs - line.start.inMilliseconds,
          isTransition
              ? startMs
              : index < switchStartMs.length
              ? switchStartMs[index]
              : startMs,
        ),
      );
    }
    sendMessage(msg.FullLyricChangedMessage(lines));
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
        ((_playbackService.position * 1000).round() - lineStartMs).clamp(
          -60000,
          _currentLyricLineLengthMs,
        );
    sendMessage(
      msg.LyricProgressChangedMessage(
        progressMs,
        DateTime.now().millisecondsSinceEpoch,
        _playbackService.rate.value,
        _playbackService.playerState == PlayerState.playing,
        lineId,
      ),
    );
  }

  void _handleDesktopLyricMessage(String raw) {
    try {
      final Map messageMap = json.decode(raw);
      final String messageType = messageMap['type'];
      final messageContent = messageMap['message'] as Map<String, dynamic>;
      if (messageType == msg.getMessageTypeName<msg.UnlockMessage>()) {
        isLocked = false;
        notifyListeners();
      } else if (messageType ==
          msg.getMessageTypeName<msg.ControlEventMessage>()) {
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
      sendFullLyricMessage(lyric);
      final positionMs = (_playbackService.position * 1000).round();
      final preludeLine = desktopLyricPreludeLineAt(lyric, positionMs);
      if (preludeLine != null) {
        final firstLine = lyric.lines.firstWhere(
          (line) => _desktopLyricLineContent(line)?.trim().isNotEmpty == true,
        );
        sendLyricLineMessage(
          preludeLine,
          nextLine: firstLine,
          isWordByWord: lyric.isWordByWord,
          syntheticLineId: syntheticLineIdForStart(
            preludeLine.start.inMilliseconds,
          ),
        );
        return;
      }
      final update = playService.lyricService.lineUpdateForLyric(
        lyric,
        _playbackService.position,
      );
      final idx = update?.primaryIndex;
      if (idx == null || idx < 0 || idx >= lyric.lines.length) return;
      final candidateLine = lyric.lines[idx];
      if (isDesktopLyricTransitionLine(candidateLine)) {
        var nextIndex = idx + 1;
        while (nextIndex < lyric.lines.length &&
            !_hasDesktopLyricContent(lyric.lines[nextIndex])) {
          nextIndex += 1;
        }
        sendLyricLineMessage(
          candidateLine,
          nextLine: nextIndex < lyric.lines.length
              ? lyric.lines[nextIndex]
              : null,
          isWordByWord: lyric.isWordByWord,
          syntheticLineId: syntheticLineIdForStart(
            _desktopLyricLineStartMs(candidateLine),
          ),
        );
        return;
      }
      var currentIndex = idx;
      while (currentIndex >= 0 &&
          !_hasDesktopLyricContent(lyric.lines[currentIndex])) {
        currentIndex -= 1;
      }
      if (currentIndex < 0) return;
      final currentLine = lyric.lines[currentIndex];
      var nextIndex = currentIndex + 1;
      while (nextIndex < lyric.lines.length &&
          !_hasDesktopLyricContent(lyric.lines[nextIndex])) {
        nextIndex += 1;
      }
      final nextLine = nextIndex < lyric.lines.length
          ? lyric.lines[nextIndex]
          : null;
      sendLyricLineMessage(
        currentLine,
        nextLine: nextLine,
        isWordByWord: lyric.isWordByWord,
        highlightDeadlineMs: lyricHighlightDeadlineMsForLine(
          lyric,
          currentIndex,
        ),
        lineIndex: currentIndex,
      );
    });
  }

  String? _desktopLyricLineContent(LyricLine line) {
    return switch (line) {
      SyncLyricLine() => line.content,
      UnsyncLyricLine() => line.content,
      _ => null,
    };
  }

  bool _hasDesktopLyricContent(LyricLine line) {
    return _desktopLyricLineContent(line)?.trim().isNotEmpty == true;
  }

  int _desktopLyricLineStartMs(LyricLine line) {
    return line is SyncLyricLine && line.words.isNotEmpty
        ? line.words.first.start.inMilliseconds
        : line.start.inMilliseconds;
  }

  int _desktopLyricLineEndMs(Lyric lyric, LyricLine line) {
    var end = line.start.inMilliseconds + line.length.inMilliseconds;
    if (line is SyncLyricLine && line.words.isNotEmpty) {
      final lastWord = line.words.last;
      final wordEnd =
          lastWord.start.inMilliseconds + lastWord.length.inMilliseconds;
      if (lyric is! Ttml) return wordEnd;
      end = end > wordEnd ? end : wordEnd;
    }
    if (lyric is Ttml && line is SyncLyricLine) {
      if (line.bgEnd != null) {
        end = end > line.bgEnd!.inMilliseconds
            ? end
            : line.bgEnd!.inMilliseconds;
      }
      if (line.bgWords.isNotEmpty) {
        final lastBgWord = line.bgWords.last;
        final bgEnd =
            lastBgWord.start.inMilliseconds + lastBgWord.length.inMilliseconds;
        end = end > bgEnd ? end : bgEnd;
      }
    }
    return end;
  }

  void _sendInitialConfig() {
    final settings = AppSettings.instance;
    final scheme = ThemeProvider.instance.currScheme;
    final colors = resolveDesktopLyricColors(
      followThemeColor: settings.desktopFollowThemeColor,
      brightnessMode: settings.desktopLyricBrightnessMode,
      scheme: scheme,
      customPlayedColor: settings.desktopPlayedColor,
      customUnplayedColor: settings.desktopUnplayedColor,
    );
    sendConfig(
      lyricFontSize: settings.desktopLyricFontSize,
      translationFontSize: settings.desktopTranslationFontSize,
      lyricFontWeight: settings.desktopLyricFontWeight,
      showLyricTranslation: settings.desktopShowTranslation,
      showNowPlayingInfo: settings.desktopShowNowPlayingInfo,
      hideOnPause: settings.desktopHideOnPause,
      showRoman: settings.showDesktopLyricRoman,
      romanPosition: settings.desktopLyricRomanPosition,
      translationPosition: settings.desktopUseVerticalDisplayMode
          ? settings.desktopLyricTranslationPosition
          : 1,
      lyricTextAlign:
          settings.desktopShowDoubleLine && settings.desktopLyricTextAlign == 3
          ? 3
          : settings.desktopLyricTextAlign.clamp(0, 2).toInt(),
      lyricAnimation: settings.desktopLyricAnimation.index,
      enableStroke: settings.desktopEnableStroke,
      backgroundOpacity: settings.desktopBackgroundOpacity,
      playedColor: colors.played.toARGB32(),
      unplayedColor: colors.unplayed.toARGB32(),
      followThemeColor: settings.desktopFollowThemeColor,
      useLightOutline: shouldUseLightDesktopLyricOutline(colors.played),
      useVerticalDisplayMode: settings.desktopUseVerticalDisplayMode,
      showDoubleLine: settings.desktopShowDoubleLine,
      hoverHide: settings.desktopHoverHide,
      fullscreenHide: settings.desktopFullscreenHide,
      lineGap: settings.desktopLineGap,
      enablePinTop: settings.desktopEnablePinTop,
      useMultiLineMode: settings.desktopUseMultiLineMode,
      multiLineAnimation: settings.desktopMultiLineAnimation.index,
      hidePlayedLines: settings.desktopHidePlayedLines,
      fontOpacity: settings.desktopFontOpacity,
    );
  }

  @override
  void dispose() {
    _processGeneration++;
    _isStarting = false;
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
    _mappedLyric = null;
    _lineIdByIndex.clear();
    _nextLyricLineId = 0;
    _nextSyntheticLineId = -1;
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
