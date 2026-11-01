import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqlite3/open.dart';

/// 系统自带的 winsqlite3.dll 只给 Windows 组件自己用，ABI 与版本都不受保证，
/// 大事务写入时可能把堆写坏（进程级 0xC0000374）。程序目录里带了官方
/// sqlite3.dll（由 sqlite3_flutter_libs 打进产物）时优先用它。
///
/// 所有打开 SQLite 的地方都必须先调一次，保证整个进程只加载同一个库，
/// 避免一份数据被两个不同版本的 SQLite 同时持有。
void ensureSqliteRuntime() {
  if (_applied) return;
  _applied = true;
  if (!Platform.isWindows) return;
  final bundled = File(
    path.join(File(Platform.resolvedExecutable).parent.path, 'sqlite3.dll'),
  );
  if (!bundled.existsSync()) return;
  open.overrideFor(
    OperatingSystem.windows,
    () => ffi.DynamicLibrary.open(bundled.path),
  );
}

bool _applied = false;
