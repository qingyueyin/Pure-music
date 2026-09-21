import 'dart:io';
import 'dart:convert';

/// 诊断"记住播放进度"功能
///
/// 检查：
/// 1. 设置是否已启用
/// 2. 上次保存的位置是否有效
/// 3. 日志中是否有相关记录

void main() async {
  stdout.writeln('=== 诊断"记住播放进度"功能 ===\n');

  // 1. 检查设置文件
  final settingsPath = _findSettingsFile();
  if (settingsPath == null) {
    stdout.writeln('❌ 找不到 settings.json 文件');
    stdout.writeln('   请先运行应用一次生成设置文件');
    return;
  }

  stdout.writeln('✓ 设置文件: $settingsPath');
  final settingsFile = File(settingsPath);
  final settingsJson = jsonDecode(await settingsFile.readAsString());
  final rememberEnabled = settingsJson['RememberPlaybackPosition'] ?? false;

  stdout.writeln('  RememberPlaybackPosition: $rememberEnabled');
  if (!rememberEnabled) {
    stdout.writeln('  ⚠️  功能未启用！请在设置页打开"记住播放进度"开关\n');
  } else {
    stdout.writeln('  ✓ 功能已启用\n');
  }

  // 2. 检查偏好设置文件
  final prefPath = _findPreferenceFile();
  if (prefPath == null) {
    stdout.writeln('❌ 找不到 playback_pref.json 文件');
    return;
  }

  stdout.writeln('✓ 偏好文件: $prefPath');
  final prefFile = File(prefPath);
  final prefJson = jsonDecode(await prefFile.readAsString());
  final lastPositionSeconds = prefJson['lastPositionSeconds'] ?? 0.0;
  final lastAudioPath = prefJson['lastAudioPath'] ?? '';

  stdout.writeln('  lastPositionSeconds: ${lastPositionSeconds}s');
  stdout.writeln('  lastAudioPath: $lastAudioPath');

  if (lastPositionSeconds == 0.0) {
    stdout.writeln('  ⚠️  上次保存的进度为 0，可能：');
    stdout.writeln('     - 上次退出时没有播放任何歌曲');
    stdout.writeln('     - 上次退出时功能未启用');
    stdout.writeln('     - 上次播放位置在前 1 秒或后 1 秒（被过滤）\n');
  } else {
    stdout.writeln('  ✓ 上次保存了进度: ${lastPositionSeconds.toStringAsFixed(1)}s\n');
  }

  // 3. 检查最近的日志
  stdout.writeln('=== 搜索最近的日志记录 ===\n');
  final logFiles = await _findLogFiles();

  if (logFiles.isEmpty) {
    stdout.writeln('❌ 找不到日志文件');
    return;
  }

  stdout.writeln('找到 ${logFiles.length} 个日志文件');

  // 只检查最新的日志文件
  final latestLog = logFiles.first;
  stdout.writeln('检查最新日志: ${latestLog.path}\n');

  final logContent = await latestLog.readAsString();
  final lines = logContent.split('\n');

  // 搜索相关日志
  final rememberLogs = <String>[];
  final restoreLogs = <String>[];
  final persistLogs = <String>[];

  for (final line in lines) {
    if (line.contains('[remember]')) {
      rememberLogs.add(line);
    }
    if (line.contains('[restore]')) {
      restoreLogs.add(line);
    }
    if (line.contains('[persist]')) {
      persistLogs.add(line);
    }
  }

  if (persistLogs.isNotEmpty) {
    stdout.writeln('📝 退出时保存进度 (${persistLogs.length} 条):');
    for (final log in persistLogs.take(5)) {
      stdout.writeln('  ${_formatLog(log)}');
    }
    if (persistLogs.length > 5) {
      stdout.writeln('  ... 还有 ${persistLogs.length - 5} 条');
    }
    stdout.writeln('');
  }

  if (restoreLogs.isNotEmpty) {
    stdout.writeln('🔄 启动时恢复进度 (${restoreLogs.length} 条):');
    for (final log in restoreLogs.take(5)) {
      stdout.writeln('  ${_formatLog(log)}');
    }
    if (restoreLogs.length > 5) {
      stdout.writeln('  ... 还有 ${restoreLogs.length - 5} 条');
    }
    stdout.writeln('');
  }

  if (rememberLogs.isNotEmpty) {
    stdout.writeln('💾 记住进度检查 (${rememberLogs.length} 条):');
    for (final log in rememberLogs.take(5)) {
      stdout.writeln('  ${_formatLog(log)}');
    }
    if (rememberLogs.length > 5) {
      stdout.writeln('  ... 还有 ${rememberLogs.length - 5} 条');
    }
    stdout.writeln('');
  }

  // 4. 给出诊断结果
  stdout.writeln('=== 诊断结果 ===\n');

  if (!rememberEnabled) {
    stdout.writeln('❌ 问题：功能未启用');
    stdout.writeln('   解决：在设置页打开"记住播放进度"开关\n');
  } else if (lastPositionSeconds == 0.0) {
    if (persistLogs.any((l) => l.contains('disabled'))) {
      stdout.writeln('❌ 问题：上次退出时功能未启用');
      stdout.writeln('   解决：打开功能后，播放一首歌到中间位置，然后退出应用重新打开\n');
    } else if (persistLogs.any(
      (l) => l.contains('too early') || l.contains('too close'),
    )) {
      stdout.writeln('⚠️  上次退出时播放位置在开头或结尾（< 1s 或 > length-1s）');
      stdout.writeln('   解决：播放到歌曲中间（至少 1 秒后），然后退出应用重新打开\n');
    } else {
      stdout.writeln('⚠️  上次退出时没有播放任何歌曲');
      stdout.writeln('   解决：播放一首歌到中间位置，然后退出应用重新打开\n');
    }
  } else {
    if (restoreLogs.any((l) => l.contains('will seek'))) {
      stdout.writeln('✓ 功能正常工作！');
      stdout.writeln(
        '  启动时已尝试恢复到: ${lastPositionSeconds.toStringAsFixed(1)}s\n',
      );
    } else if (restoreLogs.any((l) => l.contains('disabled'))) {
      stdout.writeln('❌ 问题：启动时功能被禁用（可能在启动后才打开）');
      stdout.writeln('   解决：确保功能一直处于开启状态\n');
    } else {
      stdout.writeln('⚠️  有保存的进度但未找到恢复日志');
      stdout.writeln('   可能需要重新启动应用来查看完整日志\n');
    }
  }
}

String? _findSettingsFile() {
  final candidates = [
    '${Platform.environment['APPDATA']}\\Pure-music\\settings.json',
    '${Platform.environment['LOCALAPPDATA']}\\Pure-music\\settings.json',
  ];

  for (final path in candidates) {
    if (File(path).existsSync()) {
      return path;
    }
  }
  return null;
}

String? _findPreferenceFile() {
  final candidates = [
    '${Platform.environment['APPDATA']}\\Pure-music\\playback_pref.json',
    '${Platform.environment['LOCALAPPDATA']}\\Pure-music\\playback_pref.json',
  ];

  for (final path in candidates) {
    if (File(path).existsSync()) {
      return path;
    }
  }
  return null;
}

Future<List<File>> _findLogFiles() async {
  final logDirs = [
    '${Platform.environment['APPDATA']}\\Pure-music\\logs',
    '${Platform.environment['LOCALAPPDATA']}\\Pure-music\\logs',
  ];

  final logFiles = <File>[];

  for (final dirPath in logDirs) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) continue;

    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.log')) {
        logFiles.add(entity);
      }
    }
  }

  // 按修改时间排序，最新的在前
  logFiles.sort((a, b) {
    final aStat = a.statSync();
    final bStat = b.statSync();
    return bStat.modified.compareTo(aStat.modified);
  });

  return logFiles;
}

String _formatLog(String log) {
  // 移除时间戳，只保留关键信息
  final match = RegExp(r'\[I\].*?\[.*?\]\s*(.*)').firstMatch(log);
  return match?.group(1) ?? log;
}
