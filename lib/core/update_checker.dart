import 'package:dio/dio.dart';
import 'package:github/github.dart' as gh;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';

/// 版本更新信息（来源无关的数据模型）
class UpdateInfo {
  final String tagName;
  final String? name;
  final String? body;
  final String? htmlUrl;

  const UpdateInfo({
    required this.tagName,
    this.name,
    this.body,
    this.htmlUrl,
  });

  /// 从 GitHub Release 转换
  factory UpdateInfo.fromGitHubRelease(gh.Release release) => UpdateInfo(
        tagName: release.tagName ?? '',
        name: release.name,
        body: release.body,
        htmlUrl: release.htmlUrl,
      );

  /// 从 JSON Map 转换（用于 fallback 源）
  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
        tagName: json['tag_name'] as String? ?? '',
        name: json['name'] as String?,
        body: json['body'] as String?,
        htmlUrl: json['html_url'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'tag_name': tagName,
        'name': name,
        'body': body,
        'html_url': htmlUrl,
      };
}

/// 更新检查服务
///
/// 支持多个数据源按顺序 fallback：
/// 1. GitHub API（[github] package）
/// 2. HTTP JSON 端点（可通过偏好配置多个 fallback URL）
class UpdateChecker {
  UpdateChecker._();

  /// 逐个尝试所有数据源，返回第一个成功的结果，全部失败返回 null
  static Future<UpdateInfo?> checkForUpdate() async {
    // Source 1: GitHub API
    final fromGitHub = await _checkGitHub();
    if (fromGitHub != null) return fromGitHub;

    // Source 2..N: HTTP JSON fallback URLs
    final urls = AppPreference.instance.updateCheckUrls;
    for (final url in urls) {
      try {
        final fromHttp = await _checkHttpJson(url);
        if (fromHttp != null) return fromHttp;
      } catch (_) {
        // 单个 fallback URL 失败，继续尝试下一个
        continue;
      }
    }

    return null;
  }

  /// 通过 GitHub API 检查更新
  static Future<UpdateInfo?> _checkGitHub() async {
    try {
      final slug = gh.RepositorySlug.full(AppPreference.instance.updateRepoSlug);
      final release = await AppSettings.github.repositories
          .listReleases(slug)
          .first;
      final tagName = release.tagName ?? '';
      if (tagName.isEmpty) return null;
      return UpdateInfo.fromGitHubRelease(release);
    } catch (e) {
      logger.w('[UpdateChecker] GitHub API failed: $e');
      return null;
    }
  }

  /// 通过 HTTP JSON 端点检查更新
  static Future<UpdateInfo?> _checkHttpJson(String url) async {
    try {
      final response = await Dio().get<Map<String, dynamic>>(
        url,
        options: Options(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 10),
          responseType: ResponseType.json,
        ),
      );
      final data = response.data;
      if (data == null) return null;
      final info = UpdateInfo.fromJson(data);
      if (info.tagName.isEmpty) return null;
      return info;
    } catch (e) {
      logger.w('[UpdateChecker] HTTP fallback failed ($url): $e');
      return null;
    }
  }

  /// 检查是否有新版本
  static bool hasNewVersion(String remoteTag, String currentVersion) {
    return compareSemVer(remoteTag, currentVersion) > 0;
  }

  /// Semantic version comparison (提取数字部分比较)
  static int compareSemVer(String a, String b) {
    final cleanA = a.replaceAll(RegExp(r'[^0-9.]'), '');
    final cleanB = b.replaceAll(RegExp(r'[^0-9.]'), '');

    final partsA = cleanA.split('.').where((s) => s.isNotEmpty).toList();
    final partsB = cleanB.split('.').where((s) => s.isNotEmpty).toList();

    final maxLen =
        partsA.length > partsB.length ? partsA.length : partsB.length;

    for (int i = 0; i < maxLen; i++) {
      final numA = i < partsA.length ? int.tryParse(partsA[i]) ?? 0 : 0;
      final numB = i < partsB.length ? int.tryParse(partsB[i]) ?? 0 : 0;
      if (numA != numB) return numA.compareTo(numB);
    }
    return 0;
  }

  /// 是否需要提醒用户（版本不同且未被用户忽略）
  static bool shouldNotify(String remoteTag) {
    final lastSeen = AppPreference.instance.lastSeenUpdateTag;
    return remoteTag.isNotEmpty &&
        remoteTag != lastSeen &&
        hasNewVersion(remoteTag, AppSettings.version);
  }
}
