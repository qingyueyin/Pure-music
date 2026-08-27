import 'dart:async';
import 'dart:convert';

import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/rust/api/smart_sort.dart' as smart_sort;
import 'package:pure_music/native/rust/api/smart_transition.dart'
    as smart_transition;
import 'package:pure_music/services/smart_sort_cache.dart';

class SmartSortResult {
  const SmartSortResult({
    required this.audios,
    required this.idealCurve,
    required this.actualCurve,
    required this.analyzedCount,
    required this.cachedCount,
  });

  /// 编排后的乐曲列表。
  final List<Audio> audios;
  final List<double> idealCurve;
  final List<double> actualCurve;

  /// 本次实际解码分析的曲目数与命中缓存的曲目数。
  final int analyzedCount;
  final int cachedCount;
}

/// 用户停止批量分析时抛出，页面按正常流程处理而不是错误。
class SmartSortCancelledException implements Exception {
  const SmartSortCancelledException();
}

class SmartSortService {
  SmartSortService._();

  static var _nextJobId = 1 << 62;

  /// 特征缓存命中时跳过解码，仅对新增或已修改的乐曲做增量分析；
  /// 排序计算本身始终在 Rust 侧全量执行。
  /// [takeCount] 大于 0 时先按采样键分层采样该数量再编排，0 表示使用全部曲目。
  /// [smoothness] 0 叙事优先 / 1 顺滑优先；[outroStyle] 0 温暖 / 1 渐弱 / 2 燃尽；
  /// [taste] 0 全部 / 1 换口味 / 2 常听的（按播放次数偏置采样）。
  static Future<SmartSortResult> run({
    required List<Audio> tracks,
    double climaxPosition = 0.82,
    double contrast = 0.85,
    int takeCount = 0,
    double smoothness = 0.5,
    int outroStyle = 0,
    int taste = 0,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (tracks.isEmpty) throw StateError('没有可排序的乐曲');
    final libraryRoot = (await getAppDataDir()).path;
    final cache = SmartSortFeatureCache.instance;
    final kept = <Audio>[];
    final features = <String>[];
    var analyzedCount = 0;
    var cachedCount = 0;
    for (var index = 0; index < tracks.length; index++) {
      if (isCancelled?.call() ?? false) {
        throw const SmartSortCancelledException();
      }
      onProgress?.call(index, tracks.length);
      final audio = tracks[index];
      final cached = await cache.lookup(audio);
      if (cached != null) {
        features.add(cached);
        kept.add(audio);
        cachedCount++;
        continue;
      }
      try {
        final jobId = BigInt.from(_nextJobId++);
        final profileJson = await _analyzeTrack(
          jobId: jobId,
          path: audio.path,
          libraryRoot: libraryRoot,
          isCancelled: isCancelled,
        );
        if (isCancelled?.call() ?? false) {
          throw const SmartSortCancelledException();
        }
        final featureJson = _extractFeatureJson(profileJson);
        cache.put(audio, featureJson);
        features.add(featureJson);
        kept.add(audio);
        analyzedCount++;
      } catch (error, trace) {
        if (isCancelled?.call() ?? false) {
          throw const SmartSortCancelledException();
        }
        logger.w(
          '[smart sort] analyze failed, use neutral features for ${audio.path}',
          error: error,
          stackTrace: trace,
        );
        final neutralFeatures = jsonEncode({
          'integratedRmsDbfs': -42.0,
          'bpm': 0.0,
          'entranceOnsetDensity': 0.0,
          'entranceEnergyDbfs': -42.0,
          'exitOnsetDensity': 0.0,
          'exitEnergyDbfs': -42.0,
        });
        cache.put(audio, neutralFeatures);
        features.add(neutralFeatures);
        kept.add(audio);
        analyzedCount++;
      }
    }
    if (isCancelled?.call() ?? false) {
      await cache.flush();
      throw const SmartSortCancelledException();
    }
    onProgress?.call(tracks.length, tracks.length);
    await cache.flush();
    if (kept.isEmpty) throw StateError('所有乐曲分析失败');
    final playCounts = kept.map((audio) => audio.playCount).toList();
    final payload = jsonEncode({
      'features': [for (final feature in features) jsonDecode(feature)],
      'playCounts': playCounts,
    });
    final outputJson = await smart_sort.planSmartSortJson(
      payloadJson: payload,
      climaxPosition: climaxPosition,
      contrast: contrast,
      takeCount: BigInt.from(takeCount),
      smoothness: smoothness,
      outroStyle: outroStyle,
      taste: taste,
    );
    if (isCancelled?.call() ?? false) {
      throw const SmartSortCancelledException();
    }
    final decoded = jsonDecode(outputJson) as Map<String, dynamic>;
    List<double> toDoubles(Object? values) =>
        (values as List).map((value) => (value as num).toDouble()).toList();
    final order = (decoded['order'] as List).cast<int>();
    return SmartSortResult(
      audios: [for (final index in order) kept[index]],
      idealCurve: toDoubles(decoded['idealCurve']),
      actualCurve: toDoubles(decoded['actualCurve']),
      analyzedCount: analyzedCount,
      cachedCount: cachedCount,
    );
  }

  static Future<String> _analyzeTrack({
    required BigInt jobId,
    required String path,
    required String libraryRoot,
    required bool Function()? isCancelled,
  }) async {
    final analysis = smart_transition.analyzeSmartTransitionTrack(
      jobId: jobId,
      path: path,
      libraryRoot: libraryRoot,
    );
    Timer? cancellationTimer;
    var cancellationSent = false;
    if (isCancelled != null) {
      cancellationTimer = Timer.periodic(const Duration(milliseconds: 100), (
        _,
      ) {
        if (cancellationSent || !isCancelled()) return;
        cancellationSent = true;
        smart_transition.cancelSmartTransitionAnalysis(jobId: jobId);
      });
    }
    try {
      return await analysis;
    } finally {
      cancellationTimer?.cancel();
    }
  }

  /// 从 TrackProfile JSON 提取排序所需的六项特征，键名与 Rust SortFeatureInput 对应。
  static String _extractFeatureJson(String profileJson) {
    final profile = jsonDecode(profileJson) as Map<String, dynamic>;
    Map<String, dynamic> region(String key) {
      final value = profile[key];
      if (value is Map<String, dynamic>) return value;
      return <String, dynamic>{};
    }

    double field(Map<String, dynamic> map, String key, double fallback) {
      final value = (map[key] as num?)?.toDouble();
      return value != null && value.isFinite ? value : fallback;
    }

    final tempo = profile['tempo'];
    final tempoMap = tempo is Map<String, dynamic>
        ? tempo
        : <String, dynamic>{};
    final entrance = region('entrance');
    final exit = region('exit');
    return jsonEncode({
      'integratedRmsDbfs': field(profile, 'integrated_rms_dbfs', -42.0),
      'bpm': field(tempoMap, 'bpm', 0.0),
      'entranceOnsetDensity': field(entrance, 'onset_density', 0.0),
      'entranceEnergyDbfs': field(entrance, 'average_energy_dbfs', -42.0),
      'exitOnsetDensity': field(exit, 'onset_density', 0.0),
      'exitEnergyDbfs': field(exit, 'average_energy_dbfs', -42.0),
    });
  }
}
