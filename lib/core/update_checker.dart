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

  const UpdateInfo({required this.tagName, this.name, this.body, this.htmlUrl});

  /// 从远程发布数据转换
  factory UpdateInfo.fromGitHubRelease(gh.Release release) => UpdateInfo(
    tagName: release.tagName ?? '',
    name: release.name,
    body: release.body,
    htmlUrl: release.htmlUrl,
  );

  /// 从 JSON Map 转换（用于 fallback 源）
  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
    tagName: _normalizedRequiredString(json['tag_name']),
    name: _normalizedOptionalString(json['name']),
    body: _normalizedOptionalString(json['body']),
    htmlUrl: _normalizedOptionalString(json['html_url']),
  );

  Map<String, dynamic> toJson() => {
    'tag_name': tagName,
    'name': name,
    'body': body,
    'html_url': htmlUrl,
  };
}

String _normalizedRequiredString(Object? value) {
  if (value is! String) return '';
  return value.trim();
}

String? _normalizedOptionalString(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

/// 更新检查服务
///
/// 按顺序尝试主发布接口和备用 JSON 端点。
class UpdateChecker {
  UpdateChecker._();

  /// 逐个尝试所有数据源，返回第一个成功的结果，全部失败返回 null
  static Future<UpdateInfo?> checkForUpdate() async {
    // 优先尝试主发布接口。
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

  /// 通过主发布接口检查更新
  static Future<UpdateInfo?> _checkGitHub() async {
    try {
      final slug = gh.RepositorySlug.full(
        AppPreference.instance.updateRepoSlug,
      );
      final release = await AppSettings.github.repositories
          .listReleases(slug)
          .first
          .timeout(const Duration(seconds: 15));
      final tagName = release.tagName ?? '';
      if (tagName.isEmpty) return null;
      return UpdateInfo.fromGitHubRelease(release);
    } catch (e) {
      logger.w('[UpdateChecker] primary source failed: ${e.runtimeType}');
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
      logger.w('[UpdateChecker] fallback source failed: ${e.runtimeType}');
      return null;
    }
  }

  /// 检查是否有新版本
  static bool hasNewVersion(String remoteTag, String currentVersion) {
    return compareSemVer(remoteTag, currentVersion) > 0;
  }

  /// 比较语义化版本；无效版本不触发更新。
  static int compareSemVer(String a, String b) {
    final versionA = _SemVer.tryParse(a);
    final versionB = _SemVer.tryParse(b);
    if (versionA == null || versionB == null) return 0;
    return versionA.compareTo(versionB);
  }

  /// 是否需要提醒用户（版本不同且未被用户忽略）
  static bool shouldNotify(String remoteTag) {
    final lastSeen = AppPreference.instance.lastSeenUpdateTag;
    return remoteTag.isNotEmpty &&
        remoteTag != lastSeen &&
        hasNewVersion(remoteTag, AppSettings.version);
  }
}

class _SemVer implements Comparable<_SemVer> {
  const _SemVer(this.major, this.minor, this.patch, this.preRelease);

  final int major;
  final int minor;
  final int patch;
  final List<String> preRelease;

  static final _pattern = RegExp(
    r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
    caseSensitive: false,
  );

  static _SemVer? tryParse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) return null;
    final major = int.tryParse(match.group(1)!);
    final minor = int.tryParse(match.group(2)!);
    final patch = int.tryParse(match.group(3)!);
    if (major == null || minor == null || patch == null) return null;
    return _SemVer(major, minor, patch, match.group(4)?.split('.') ?? const []);
  }

  @override
  int compareTo(_SemVer other) {
    for (final comparison in [
      major.compareTo(other.major),
      minor.compareTo(other.minor),
      patch.compareTo(other.patch),
    ]) {
      if (comparison != 0) return comparison;
    }

    if (preRelease.isEmpty || other.preRelease.isEmpty) {
      return preRelease.isEmpty == other.preRelease.isEmpty
          ? 0
          : (preRelease.isEmpty ? 1 : -1);
    }
    final length = preRelease.length < other.preRelease.length
        ? preRelease.length
        : other.preRelease.length;
    for (var i = 0; i < length; i++) {
      final left = preRelease[i];
      final right = other.preRelease[i];
      if (left == right) continue;
      final leftNumber = int.tryParse(left);
      final rightNumber = int.tryParse(right);
      if (leftNumber != null && rightNumber != null) {
        return leftNumber.compareTo(rightNumber);
      }
      if (leftNumber != null) return -1;
      if (rightNumber != null) return 1;
      return left.compareTo(right);
    }
    return preRelease.length.compareTo(other.preRelease.length);
  }
}
