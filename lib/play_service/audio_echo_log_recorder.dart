import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/window_render_gate.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/log/log_format.dart';

class AudioEchoLogRecorder {
  AudioEchoLogRecorder._();

  static final instance = AudioEchoLogRecorder._();
  static const _maxReadableLogBytes = 512 * 1024;
  static const _readableLogHeadBytes = 32 * 1024;

  bool get isRecording => _sink != null && _fullRecording;
  bool get isActive => _sink != null;

  IOSink? _sink;
  bool _stopped = false;
  File? _file;
  String? _latestLogPath;
  Future<void> _writeQueue = Future.value();
  Timer? _logFlushTimer;
  Timer? _snapshotTimer;
  Object? _lastFlushedRecord;
  bool _fullRecording = false;
  bool _watchingTrayHidden = false;
  late final void Function() _onTrayHidden = _syncPeriodicSnapshot;

  String? get currentLogPath => _file?.path;
  String? get latestLogPath => _file?.path ?? _latestLogPath;

  Future<Directory> _ensureLogDir() async {
    final override = Platform.environment['CP_ECHO_LOG_DIR'];
    if (override != null && override.trim().isNotEmpty) {
      return Directory(override.trim()).create(recursive: true);
    }
    final appData = await getAppDataDir();
    return Directory(
      '${appData.path}\\audio_echo_logs',
    ).create(recursive: true);
  }

  String _fileSafeTs() => DateTime.now().toIso8601String().replaceAll(':', '-');

  Future<void> start({bool full = true}) async {
    if (_sink != null) {
      if (full) {
        _fullRecording = true;
        _writeLine('RECORDER|mode=full');
        await flush();
      }
      return;
    }

    final dir = await _ensureLogDir();
    final file = File('${dir.path}/audio_echo_${_fileSafeTs()}.log');
    _file = file;
    _latestLogPath = file.path;
    _stopped = false;
    _sink = file.openWrite(mode: FileMode.writeOnlyAppend);
    _fullRecording = full;
    _lastFlushedRecord = null;

    _writeLine('RECORDER|startedAt=${DateTime.now().toIso8601String()}');
    _writeLine('RECORDER|mode=${full ? 'full' : 'background'}');
    _writeLine(
      'RECORDER|eqGains=${AppPreference.instance.playbackPref.eqGains.join(",")}',
    );
    _writeLine(
      'RECORDER|audios=${AudioLibrary.instance.audioCollection.length}',
    );

    _logFlushTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        await flush();
      } catch (_) {}
    });

    _watchTrayHidden();
    _syncPeriodicSnapshot();

    try {
      snapshot(tag: 'start');
    } catch (_) {}
  }

  Future<void> stop() async {
    if (_sink == null) return;

    _logFlushTimer?.cancel();
    _snapshotTimer?.cancel();
    _logFlushTimer = null;
    _snapshotTimer = null;
    _unwatchTrayHidden();

    try {
      snapshot(tag: 'stop');
    } catch (_) {}
    _flushLoggerMemoryDelta();
    _writeLine('RECORDER|stoppedAt=${DateTime.now().toIso8601String()}');
    _stopped = true;
    await _enqueueWrite(() async {
      await _sink?.flush();
      await _sink?.close();
      _sink = null;
      _file = null;
      _fullRecording = false;
    });
  }

  Future<void> flush() {
    if (_stopped) return _writeQueue;
    _flushLoggerMemoryDelta();
    final sink = _sink;
    if (sink == null) return _writeQueue;
    return _enqueueWrite(sink.flush);
  }

  Future<String?> readLatestLog() async {
    await flush();
    var path = latestLogPath;
    if (path == null || !await File(path).exists()) {
      path = await _findLatestLogPath();
    }
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;

    final length = await file.length();
    if (length <= _maxReadableLogBytes) {
      final content = await file.readAsString();
      return 'RECORDER|sourcePath=$path\n$content';
    }

    const headBytes = _readableLogHeadBytes;
    const tailBytes = _maxReadableLogBytes - headBytes;
    final reader = await file.open();
    try {
      final head = await reader.read(headBytes);
      await reader.setPosition(length - tailBytes);
      final tail = await reader.read(tailBytes);
      final omitted = length - head.length - tail.length;
      return 'RECORDER|sourcePath=$path\n'
          '${utf8.decode(head, allowMalformed: true)}\n'
          'RECORDER|omittedBytes=$omitted\n'
          '${utf8.decode(tail, allowMalformed: true)}';
    } finally {
      await reader.close();
    }
  }

  void mark(String name, {Map<String, Object?> extra = const {}}) {
    final payload = <String, Object?>{
      'ts': DateTime.now().toIso8601String(),
      'name': name,
      ...extra,
    };
    _writeLine(
      'MARK|${payload.entries.map((e) => '${e.key}=${e.value}').join('|')}',
    );
    if (name == 'seek' || name.startsWith('smart_transition_')) {
      unawaited(flush().catchError((_) {}));
    }
  }

  // 主窗口藏进托盘后停掉周期快照，避免每 5 秒去读播放状态；完整录音写盘不在这里停。
  void _watchTrayHidden() {
    if (_watchingTrayHidden) return;
    WindowRenderGate.instance.trayHidden.addListener(_onTrayHidden);
    _watchingTrayHidden = true;
  }

  void _unwatchTrayHidden() {
    if (!_watchingTrayHidden) return;
    WindowRenderGate.instance.trayHidden.removeListener(_onTrayHidden);
    _watchingTrayHidden = false;
  }

  void _syncPeriodicSnapshot() {
    if (_sink == null ||
        _stopped ||
        WindowRenderGate.instance.trayHidden.value) {
      _snapshotTimer?.cancel();
      _snapshotTimer = null;
      return;
    }
    _snapshotTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      try {
        snapshot(tag: 'periodic');
      } catch (_) {}
    });
  }

  void snapshot({required String tag}) {
    try {
      final pb = PlayService.instance.playbackService;
      final payload = <String, Object?>{
        'ts': DateTime.now().toIso8601String(),
        'tag': tag,
        'state': pb.playerState.name,
        'pos': pb.position,
        'len': pb.length,
        'bass': pb.bassDebugStateLine,
        'exclusive': pb.wasapiExclusive.value,
        'playlistIndex': pb.playlistIndex,
        'playlistLen': pb.playlist.value.length,
        'sourceGeneration': pb.sourceGeneration,
        'smartTransition': jsonEncode(pb.smartTransitionDiagnostics),
      };
      _writeLine(
        'SNAPSHOT|${payload.entries.map((e) => '${e.key}=${e.value}').join('|')}',
      );
    } catch (_) {
      final payload = <String, Object?>{
        'ts': DateTime.now().toIso8601String(),
        'tag': tag,
      };
      _writeLine(
        'SNAPSHOT|${payload.entries.map((e) => '${e.key}=${e.value}').join('|')}',
      );
    }
  }

  Future<bool> openLogDir() async {
    try {
      final dir = await _ensureLogDir();
      if (!Platform.isWindows) return false;
      await Process.start('explorer', [dir.absolute.path], runInShell: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _flushLoggerMemoryDelta() {
    if (_sink == null || !_fullRecording) return;

    final records = LogMemory.instance.records;
    if (records.isEmpty) {
      _lastFlushedRecord = null;
      return;
    }

    var start = 0;
    final lastFlushedRecord = _lastFlushedRecord;
    if (lastFlushedRecord != null) {
      final lastIndex = records.indexWhere(
        (record) => identical(record, lastFlushedRecord),
      );
      if (lastIndex >= 0) start = lastIndex + 1;
    }
    for (final record in records.skip(start)) {
      for (final line in formatRecord(record).split('\n')) {
        _writeLine(line);
      }
    }
    _lastFlushedRecord = records.last;
  }

  void _writeLine(String line) {
    if (_stopped) return;
    final sink = _sink;
    if (sink == null) return;
    final redacted = redactDiagnosticData(line);
    unawaited(
      _enqueueWrite(() {
        sink.writeln(redacted);
      }),
    );
  }

  Future<void> _enqueueWrite(FutureOr<void> Function() operation) {
    final next = _writeQueue.then<void>((_) async {
      try {
        await operation();
      } catch (_) {}
    });
    _writeQueue = next;
    return next;
  }

  Future<String?> _findLatestLogPath() async {
    final dir = await _ensureLogDir();
    final files = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File &&
          entity.uri.pathSegments.last.startsWith('audio_echo_') &&
          entity.path.toLowerCase().endsWith('.log')) {
        files.add(entity);
      }
    }
    if (files.isEmpty) return null;
    files.sort((a, b) => a.path.compareTo(b.path));
    _latestLogPath = files.last.path;
    return _latestLogPath;
  }
}
