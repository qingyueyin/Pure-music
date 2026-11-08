import 'package:flutter/foundation.dart';

import '../application_log.dart';
import 'log_format.dart';
import 'log_policy.dart';
import 'log_record.dart';

const _memoryCapacity = 2000;

class LogMemory {
  LogMemory._();

  static final instance = LogMemory._();

  final _records = <LogRecord>[];

  List<LogRecord> get records => List.unmodifiable(_records);

  void add(LogRecord record) {
    _records.add(record);
    while (_records.length > _memoryCapacity) {
      _records.removeAt(0);
    }
  }

  void clear() => _records.clear();
}

class LogChannel {
  LogChannel(this.module);

  final LogModule module;

  void trace(
    String event,
    String message, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => _write(LogLevel.trace, event, message, fields, error, stackTrace);

  void debug(
    String event,
    String message, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => _write(LogLevel.debug, event, message, fields, error, stackTrace);

  void info(
    String event,
    String message, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => _write(LogLevel.info, event, message, fields, error, stackTrace);

  void warn(
    String event,
    String message, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => _write(LogLevel.warn, event, message, fields, error, stackTrace);

  void error(
    String event,
    String message, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => _write(LogLevel.error, event, message, fields, error, stackTrace);

  void fatal(
    String event,
    String message, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => _write(LogLevel.fatal, event, message, fields, error, stackTrace);

  void _write(
    LogLevel level,
    String event,
    String message,
    Map<String, Object?> fields,
    Object? error,
    StackTrace? stackTrace,
  ) {
    log.write(
      LogRecord(
        time: DateTime.now(),
        level: level,
        module: module,
        event: event,
        message: message,
        fields: fields,
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }
}

class AppLog {
  static const _dedupWindow = Duration(seconds: 2);
  static const _dedupMaxKeys = 256;
  static const _dedupModules = {
    LogModule.lyric,
    LogModule.onlineLyric,
    LogModule.desktopLyric,
  };

  final app = LogChannel(LogModule.app);
  final playback = LogChannel(LogModule.playback);
  final bass = LogChannel(LogModule.bass);
  final lyric = LogChannel(LogModule.lyric);
  final onlineLyric = LogChannel(LogModule.onlineLyric);
  final smtc = LogChannel(LogModule.smtc);
  final memory = LogChannel(LogModule.memory);
  final library = LogChannel(LogModule.library);
  final desktopLyric = LogChannel(LogModule.desktopLyric);
  final settings = LogChannel(LogModule.settings);
  final update = LogChannel(LogModule.update);
  final window = LogChannel(LogModule.window);
  final hotkey = LogChannel(LogModule.hotkey);
  final lastfm = LogChannel(LogModule.lastfm);
  final rust = LogChannel(LogModule.rust);

  final _dedupEntries = <String, _DedupEntry>{};

  void write(LogRecord record) {
    final effective = _dedup(record);
    if (effective == null) return;
    if (keepInMemory(effective.level)) LogMemory.instance.add(effective);
    applicationLogOutput.writeRecord(effective);
    if (kDebugMode && effective.level.index >= LogLevel.warn.index) {
      debugPrint(formatRecord(effective));
    }
  }

  LogRecord? _dedup(LogRecord record) {
    if (!_dedupModules.contains(record.module)) return record;
    final key =
        '${record.module.wire}|${record.level.name}|${record.event}|'
        '${record.message}|${record.fields}|${record.error}';
    final now = record.time;
    final entry = _dedupEntries[key];
    if (entry != null) {
      final delta = now.difference(entry.time);
      if (!delta.isNegative && delta < _dedupWindow) {
        entry.suppressed++;
        return null;
      }
    }
    if (_dedupEntries.length >= _dedupMaxKeys) {
      _dedupEntries.removeWhere(
        (_, value) => now.difference(value.time) >= _dedupWindow,
      );
    }
    _dedupEntries[key] = _DedupEntry(now);
    if (entry == null || entry.suppressed == 0) return record;
    return LogRecord(
      time: record.time,
      level: record.level,
      module: record.module,
      event: record.event,
      message: record.message,
      fields: {...record.fields, 'repeat': entry.suppressed},
      error: record.error,
      stackTrace: record.stackTrace,
    );
  }
}

class _DedupEntry {
  _DedupEntry(this.time);

  final DateTime time;
  int suppressed = 0;
}

final log = AppLog();
