import 'dart:convert';
import 'dart:io';

import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';

/// 一份已生成的演出编排：按顺序记录乐曲路径与当时的参数，可随时恢复重放。
class ConcertProgram {
  const ConcertProgram({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.climaxPosition,
    required this.contrast,
    required this.setSize,
    required this.smoothness,
    required this.outroStyle,
    required this.taste,
    required this.paths,
    this.sourcePaths = const [],
    this.idealCurve = const [],
    this.actualCurve = const [],
  });

  factory ConcertProgram.fromMap(Map<String, dynamic> map) => ConcertProgram(
    id: map['id']?.toString() ?? '',
    name: map['name']?.toString() ?? '',
    createdAt:
        DateTime.tryParse(map['createdAt']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    climaxPosition: (map['climaxPosition'] as num?)?.toDouble() ?? 0.82,
    contrast: (map['contrast'] as num?)?.toDouble() ?? 0.85,
    setSize: (map['setSize'] as num?)?.toInt() ?? 0,
    smoothness: (map['smoothness'] as num?)?.toDouble() ?? 0.5,
    outroStyle: (map['outroStyle'] as num?)?.toInt() ?? 0,
    taste: (map['taste'] as num?)?.toInt() ?? 0,
    paths: [
      for (final path in map['paths'] ?? const [])
        if (path is String) path,
    ],
    sourcePaths: [
      for (final path in map['sourcePaths'] ?? const [])
        if (path is String) path,
    ],
    idealCurve: [
      for (final value in map['idealCurve'] ?? const [])
        if (value is num) value.toDouble(),
    ],
    actualCurve: [
      for (final value in map['actualCurve'] ?? const [])
        if (value is num) value.toDouble(),
    ],
  );

  final String id;
  final String name;
  final DateTime createdAt;
  final double climaxPosition;
  final double contrast;

  /// 演出抽取的曲目数；0 表示使用全部素材。
  final int setSize;

  /// 顺滑度 0..1：叙事优先 ↔ 顺滑优先。
  final double smoothness;

  /// 收尾风格：0 温暖 / 1 渐弱 / 2 燃尽。
  final int outroStyle;

  /// 抽取口味：0 全部 / 1 换口味 / 2 常听的。
  final int taste;

  /// 生成演出时的完整素材池；旧存档没有该字段时回退到 paths。
  final List<String> sourcePaths;
  final List<String> paths;
  final List<double> idealCurve;
  final List<double> actualCurve;

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'climaxPosition': climaxPosition,
    'contrast': contrast,
    'setSize': setSize,
    'smoothness': smoothness,
    'outroStyle': outroStyle,
    'taste': taste,
    'sourcePaths': sourcePaths,
    'paths': paths,
    'idealCurve': idealCurve,
    'actualCurve': actualCurve,
  };
}

/// 演出编排的本地持久化：appData/concert_programs.json，最新在前，超出上限自动淘汰。
class ConcertProgramStore {
  ConcertProgramStore._();

  static final ConcertProgramStore instance = ConcertProgramStore._();

  static const _fileName = 'concert_programs.json';
  static const _maxPrograms = 20;

  final List<ConcertProgram> programs = [];
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await getAppDataDir();
      final file = File('${dir.path}${Platform.pathSeparator}$_fileName');
      if (!file.existsSync()) return;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          programs.add(ConcertProgram.fromMap(item));
        }
      }
    } catch (error, trace) {
      logger.w(
        '[smart sort] program store load failed',
        error: error,
        stackTrace: trace,
      );
    }
  }

  Future<void> _flush() async {
    try {
      final dir = await getAppDataDir();
      final file = File('${dir.path}${Platform.pathSeparator}$_fileName');
      await file.writeAsString(
        jsonEncode([for (final program in programs) program.toMap()]),
        flush: true,
      );
    } catch (error, trace) {
      logger.w(
        '[smart sort] program store save failed',
        error: error,
        stackTrace: trace,
      );
    }
  }

  /// 插入或更新（同 id 原位更新并提到最前），超限淘汰最旧。
  Future<void> upsert(ConcertProgram program) async {
    programs.removeWhere((existing) => existing.id == program.id);
    programs.insert(0, program);
    while (programs.length > _maxPrograms) {
      programs.removeLast();
    }
    await _flush();
  }

  Future<void> remove(String id) async {
    programs.removeWhere((program) => program.id == id);
    await _flush();
  }
}
