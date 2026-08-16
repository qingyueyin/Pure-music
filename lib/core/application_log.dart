import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:path/path.dart' as path;

final applicationLogOutput = ApplicationLogOutput();

class ApplicationLogOutput extends LogOutput {
  ApplicationLogOutput({Iterable<String>? directoryPaths})
    : _directoryPaths = directoryPaths?.toList(growable: false);

  static const _maxExportBytes = 512 * 1024;

  final List<String>? _directoryPaths;
  IOSink? _sink;
  File? _logFile;
  File? _crashFile;
  Future<void> _writeQueue = Future<void>.value();

  String? get currentLogPath => _logFile?.path;
  String? get crashLogPath => _crashFile?.path;

  @override
  Future<void> init() async {
    for (final directoryPath in _candidateDirectoryPaths()) {
      IOSink? candidateSink;
      try {
        final directory = await Directory(
          directoryPath,
        ).create(recursive: true);
        final logFile = File(
          path.join(directory.path, 'pure_music_${_dateStamp()}.log'),
        );
        candidateSink = logFile.openWrite(mode: FileMode.writeOnlyAppend);
        candidateSink.writeln(
          '${DateTime.now().toIso8601String()}|SESSION|pid=$pid',
        );
        await candidateSink.flush();
        _logFile = logFile;
        _crashFile = File(path.join(directory.path, 'crash.log'));
        _sink = candidateSink;
        return;
      } catch (_) {
        try {
          await candidateSink?.close();
        } catch (_) {}
      }
    }
  }

  @override
  void output(OutputEvent event) {
    if (event.level.index < Level.info.index) return;
    final sink = _sink;
    if (sink == null) return;
    unawaited(
      _enqueueWrite(() async {
        sink.writeln(
          '${event.origin.time.toIso8601String()}|${event.level.name.toUpperCase()}',
        );
        for (final line in event.lines) {
          sink.writeln(line);
        }
        if (event.level.index >= Level.warning.index) {
          await sink.flush();
        }
      }),
    );
  }

  Future<void> flush() {
    final sink = _sink;
    return _enqueueWrite(() async {
      await sink?.flush();
    });
  }

  void recordUnhandledSync({
    required String source,
    required Object error,
    StackTrace? stackTrace,
  }) {
    final content = StringBuffer()
      ..writeln(
        '${DateTime.now().toIso8601String()}|UNHANDLED|source=$source|pid=$pid',
      )
      ..writeln(error);
    if (stackTrace != null) content.writeln(stackTrace);
    final text = content.toString();
    final current = _crashFile;
    if (current != null && _appendCrashSync(current, text)) return;
    for (final directoryPath in _candidateDirectoryPaths()) {
      try {
        final directory = Directory(directoryPath)..createSync(recursive: true);
        final file = File(path.join(directory.path, 'crash.log'));
        if (_appendCrashSync(file, text)) {
          _crashFile = file;
          return;
        }
      } catch (_) {}
    }
  }

  Future<String?> readForExport() async {
    await flush();
    final logFile = _logFile ?? await _findLatestApplicationLog();
    final crashFile = _crashFile ?? await _findCrashLog();
    if (logFile == null && crashFile == null) return null;
    final output = StringBuffer();
    if (logFile != null && await logFile.exists()) {
      output.writeln('APPLICATION_LOG_PATH=${logFile.path}');
      output.writeln(await _readTail(logFile));
    }
    if (crashFile != null && await crashFile.exists()) {
      output.writeln('CRASH_LOG_PATH=${crashFile.path}');
      output.writeln(await _readTail(crashFile));
    }
    return output.toString();
  }

  @override
  Future<void> destroy() async {
    final sink = _sink;
    _sink = null;
    if (sink == null) return;
    await _enqueueWrite(() async {
      try {
        await sink.flush();
      } finally {
        await sink.close();
      }
    });
  }

  Iterable<String> _candidateDirectoryPaths() sync* {
    final directoryPaths = _directoryPaths;
    if (directoryPaths != null) {
      yield* directoryPaths;
      return;
    }
    final executable = Platform.resolvedExecutable;
    final executableName = path.basename(executable).toLowerCase();
    if (executableName != 'dart.exe' &&
        executableName != 'flutter_tester.exe') {
      yield path.join(path.dirname(executable), 'logs');
    }
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.trim().isNotEmpty) {
      yield path.join(localAppData, 'pure_music', 'logs');
    }
    final userProfile = Platform.environment['USERPROFILE'];
    if (userProfile != null && userProfile.trim().isNotEmpty) {
      yield path.join(userProfile, 'AppData', 'Local', 'pure_music', 'logs');
    }
    yield path.join(Directory.systemTemp.path, 'pure_music', 'logs');
  }

  Future<void> _enqueueWrite(FutureOr<void> Function() operation) {
    final queued = _writeQueue.then((_) async {
      try {
        await operation();
      } catch (_) {}
    });
    _writeQueue = queued;
    return queued;
  }

  Future<File?> _findLatestApplicationLog() async {
    for (final directoryPath in _candidateDirectoryPaths()) {
      final directory = Directory(directoryPath);
      if (!await directory.exists()) continue;
      final files = <File>[];
      try {
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is File &&
              path.basename(entity.path).startsWith('pure_music_') &&
              entity.path.toLowerCase().endsWith('.log')) {
            files.add(entity);
          }
        }
      } catch (_) {
        continue;
      }
      if (files.isEmpty) continue;
      files.sort((a, b) => a.path.compareTo(b.path));
      _logFile = files.last;
      return _logFile;
    }
    return null;
  }

  Future<File?> _findCrashLog() async {
    for (final directoryPath in _candidateDirectoryPaths()) {
      final file = File(path.join(directoryPath, 'crash.log'));
      if (await file.exists()) {
        _crashFile = file;
        return file;
      }
    }
    return null;
  }

  Future<String> _readTail(File file) async {
    final length = await file.length();
    if (length <= _maxExportBytes) return file.readAsString();
    final reader = await file.open();
    try {
      await reader.setPosition(length - _maxExportBytes);
      final bytes = await reader.read(_maxExportBytes);
      return 'LOG|omittedBytes=${length - bytes.length}\n'
          '${utf8.decode(bytes, allowMalformed: true)}';
    } finally {
      await reader.close();
    }
  }

  bool _appendCrashSync(File file, String content) {
    try {
      file.writeAsStringSync(
        content,
        mode: FileMode.writeOnlyAppend,
        flush: true,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  String _dateStamp() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }
}
