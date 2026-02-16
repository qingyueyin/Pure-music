import 'dart:async';
import 'dart:io';

import 'package:pure_music/app_settings.dart';
import 'package:pure_music/app_preference.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/utils.dart';

class AudioEchoLogRecorder {
  AudioEchoLogRecorder._();

  static final instance = AudioEchoLogRecorder._();

  bool get isRecording => _sink != null;

  IOSink? _sink;
  File? _file;
  Timer? _logFlushTimer;
  Timer? _snapshotTimer;
  int _lastEventIndex = 0;
  int _lastLineIndex = 0;

  String? get currentLogPath => _file?.path;

  Future<Directory> _ensureLogDir() async {
    final override = Platform.environment['CP_ECHO_LOG_DIR'];
    if (override != null && override.trim().isNotEmpty) {
      return Directory(override.trim()).create(recursive: true);
    }
    final appData = await getAppDataDir();
    return Directory('${appData.path}\\audio_echo_logs')
        .create(recursive: true);
  }

  String _fileSafeTs() => DateTime.now().toIso8601String().replaceAll(':', '-');

  Future<void> start() async {
    if (_sink != null) return;

    final dir = await _ensureLogDir();
    final file = File('${dir.path}/audio_echo_${_fileSafeTs()}.log');
    final sink = file.openWrite(mode: FileMode.writeOnlyAppend);

    _file = file;
    _sink = sink;
    _lastEventIndex = 0;
    _lastLineIndex = 0;

    _writeLine('RECORDER|startedAt=${DateTime.now().toIso8601String()}');
    _writeLine(
      'RECORDER|wasapiBufferSec=${AppPreference.instance.playbackPref.wasapiBufferSec}'
      '|wasapiEventDriven=${AppPreference.instance.playbackPref.wasapiEventDriven}',
    );
    _writeLine(
      'RECORDER|eqBypass=${AppPreference.instance.playbackPref.eqBypass}'
      '|eqGains=${AppPreference.instance.playbackPref.eqGains.join(",")}',
    );
    _writeLine(
        'RECORDER|audios=${AudioLibrary.instance.audioCollection.length}');

    _logFlushTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _flushLoggerMemoryDelta();
    });

    _snapshotTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      try {
        snapshot(tag: 'periodic');
      } catch (_) {}
    });

    try {
      snapshot(tag: 'start');
    } catch (_) {}
  }

  Future<void> stop() async {
    if (_sink == null) return;

    try {
      snapshot(tag: 'stop');
    } catch (_) {}
    _flushLoggerMemoryDelta();
    _writeLine('RECORDER|stoppedAt=${DateTime.now().toIso8601String()}');

    _logFlushTimer?.cancel();
    _snapshotTimer?.cancel();
    _logFlushTimer = null;
    _snapshotTimer = null;

    final sink = _sink!;
    _sink = null;
    _file = null;
    await sink.flush();
    await sink.close();
  }

  void mark(String name, {Map<String, Object?> extra = const {}}) {
    final payload = <String, Object?>{
      'ts': DateTime.now().toIso8601String(),
      'name': name,
      ...extra,
    };
    _writeLine(
        'MARK|${payload.entries.map((e) => '${e.key}=${e.value}').join('|')}');
  }

  void snapshot({required String tag}) {
    try {
      final pb = PlayService.instance.playbackService;
      final nowPlayingPath = pb.nowPlaying?.path ?? '';
      final payload = <String, Object?>{
        'ts': DateTime.now().toIso8601String(),
        'tag': tag,
        'state': pb.playerState.name,
        'pos': pb.position,
        'len': pb.length,
        'bass': pb.bassDebugStateLine,
        'exclusive': pb.wasapiExclusive.value,
        'bufferSec': AppPreference.instance.playbackPref.wasapiBufferSec,
        'eventDriven': AppPreference.instance.playbackPref.wasapiEventDriven,
        'eqBypass': AppPreference.instance.playbackPref.eqBypass,
        'playlistIndex': pb.playlistIndex,
        'playlistLen': pb.playlist.value.length,
        'nowPlayingPath': nowPlayingPath,
      };
      _writeLine(
        'SNAPSHOT|${payload.entries.map((e) => '${e.key}=${e.value}').join('|')}',
      );
    } catch (_) {
      final payload = <String, Object?>{
        'ts': DateTime.now().toIso8601String(),
        'tag': tag,
        'bufferSec': AppPreference.instance.playbackPref.wasapiBufferSec,
        'eventDriven': AppPreference.instance.playbackPref.wasapiEventDriven,
        'eqBypass': AppPreference.instance.playbackPref.eqBypass,
      };
      _writeLine(
        'SNAPSHOT|${payload.entries.map((e) => '${e.key}=${e.value}').join('|')}',
      );
    }
  }

  Future<void> openLogDir() async {
    final dir = await _ensureLogDir();
    if (!Platform.isWindows) return;
    try {
      await Process.start('explorer', [dir.absolute.path], runInShell: true);
    } catch (_) {}
  }

  void _flushLoggerMemoryDelta() {
    if (_sink == null) return;

    final buffer = LOGGER_MEMORY.buffer.toList(growable: false);
    if (buffer.isEmpty) return;

    if (_lastEventIndex > buffer.length) {
      _lastEventIndex = 0;
      _lastLineIndex = 0;
    }

    for (int i = _lastEventIndex; i < buffer.length; i++) {
      final event = buffer[i];
      final lines = event.lines;
      final startLine = (i == _lastEventIndex) ? _lastLineIndex : 0;
      for (int j = startLine; j < lines.length; j++) {
        _writeLine(lines[j]);
      }
      _lastLineIndex = 0;
    }
    _lastEventIndex = buffer.length;
  }

  void _writeLine(String line) {
    final sink = _sink;
    if (sink == null) return;
    sink.writeln(line);
  }
}
