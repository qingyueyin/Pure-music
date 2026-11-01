import 'dart:io';

import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/preference.dart';

/// 升级后的一次性维护：只做没有负面影响的清理。
/// 日志留 7 天（更早的诊断日志没有回看价值），数据库做 WAL checkpoint
/// 把日志合并回主文件。曲库索引、播放历史、设置一律不动。
class UpgradeMaintenance {
  UpgradeMaintenance._();

  static const _logRetentionDays = 7;

  /// 在 AppPreference 读取完成后调用；版本号一致时直接返回，零开销。
  static Future<void> runIfNeeded() async {
    final stored = AppPreference.instance.rawVersion;
    const current = AppSettings.version;
    if (stored == current || stored == null || stored.isEmpty) return;
    try {
      await _pruneEchoLogs();
      // db 是惰性打开的，先确保打开再做 checkpoint
      await AppDb.instance.db();
      AppDb.instance.checkpointWal();
      log.app.info(
        'legacy',
        '[upgrade-maintenance] $stored -> $current done',
      );
    } catch (e, s) {
      log.app.error('legacy', '[upgrade-maintenance] failed: $e', stackTrace: s);
    }
  }

  static Future<void> _pruneEchoLogs() async {
    final appData = await getAppDataDir();
    final dir = Directory('${appData.path}\\audio_echo_logs');
    if (!dir.existsSync()) return;
    final cutoff = DateTime.now().subtract(
      const Duration(days: _logRetentionDays),
    );
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      final match = RegExp(r'audio_echo_(\d{4}-\d{2}-\d{2})T').firstMatch(
        entry.uri.pathSegments.last,
      );
      if (match == null) continue;
      final date = DateTime.tryParse(match.group(1)!);
      if (date == null || date.isAfter(cutoff)) continue;
      try {
        await entry.delete();
      } catch (_) {
        // 单个日志删不掉（被占用等）不影响其余清理
      }
    }
  }
}
