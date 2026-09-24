import 'package:dio/dio.dart';
import 'package:github/github.dart' as gh;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';

enum UpdateChannel {
  github,
  gitee;

  String get label => switch (this) {
    UpdateChannel.github => 'GitHub 直连',
    UpdateChannel.gitee => 'Gitee 镜像',
  };

  UpdateChannel get alternate => switch (this) {
    UpdateChannel.github => UpdateChannel.gitee,
    UpdateChannel.gitee => UpdateChannel.github,
  };

  static UpdateChannel? parse(Object? value) => switch (value) {
    'github' => UpdateChannel.github,
    'gitee' => UpdateChannel.gitee,
    _ => null,
  };
}

class UpdateCheckException implements Exception {
  const UpdateCheckException(this.channel);

  final UpdateChannel channel;

  @override
  String toString() => '无法连接${channel.label}更新源';
}

/// 版本更新信息（来源无关的数据模型）
class UpdateInfo {
  final String tagName;
  final String? name;
  final String? body;
  final String? htmlUrl;
  final String? giteeHtmlUrl;
  final String? installerUrl;
  final String? giteeInstallerUrl;
  final String? installerSha256;
  final String? installerChecksumUrl;
  final String? giteeInstallerChecksumUrl;
  final int? installerSize;
  final String? portableUrl;
  final String? giteePortableUrl;
  final String? portableSha256;
  final String? portableChecksumUrl;
  final String? giteePortableChecksumUrl;
  final int? portableSize;
  final int? size;

  const UpdateInfo({
    required this.tagName,
    this.name,
    this.body,
    this.htmlUrl,
    this.giteeHtmlUrl,
    this.installerUrl,
    this.giteeInstallerUrl,
    this.installerSha256,
    this.installerChecksumUrl,
    this.giteeInstallerChecksumUrl,
    this.installerSize,
    this.portableUrl,
    this.giteePortableUrl,
    this.portableSha256,
    this.portableChecksumUrl,
    this.giteePortableChecksumUrl,
    this.portableSize,
    this.size,
  });

  factory UpdateInfo.fromGitHubRelease(gh.Release release) =>
      UpdateInfo.fromReleaseJson({
        'tag_name': release.tagName,
        'name': release.name,
        'body': release.body,
        'html_url': release.htmlUrl,
        'assets': (release.assets ?? const <gh.ReleaseAsset>[])
            .map((asset) => asset.toJson())
            .toList(growable: false),
      }, channel: UpdateChannel.github);

  factory UpdateInfo.fromReleaseJson(
    Map<String, dynamic> json, {
    required UpdateChannel channel,
    String repositorySlug = AppPreference.defaultUpdateRepoSlug,
  }) {
    final tagName = _normalizedRequiredString(json['tag_name']);
    final assets = _releaseAssets(json['assets']);
    final installer = _assetForSuffix(assets, 'installer.exe');
    final portable = _assetForSuffix(assets, 'portable.zip');
    final installerChecksum = _assetForName(
      assets,
      '${installer?['name'] ?? ''}.sha256',
    );
    final portableChecksum = _assetForName(
      assets,
      '${portable?['name'] ?? ''}.sha256',
    );
    final installerUrl = _channelAssetUrls(
      installer,
      channel: channel,
      tagName: tagName,
      repositorySlug: repositorySlug,
    );
    final portableUrl = _channelAssetUrls(
      portable,
      channel: channel,
      tagName: tagName,
      repositorySlug: repositorySlug,
    );
    final installerChecksumUrls = _channelAssetUrls(
      installerChecksum,
      channel: channel,
      tagName: tagName,
      repositorySlug: repositorySlug,
    );
    final portableChecksumUrls = _channelAssetUrls(
      portableChecksum,
      channel: channel,
      tagName: tagName,
      repositorySlug: repositorySlug,
    );
    final releasePage = _normalizedOptionalString(json['html_url']);
    final githubReleasePage = channel == UpdateChannel.github
        ? releasePage
        : _releasePageUrl(UpdateChannel.github, repositorySlug, tagName);
    final giteeReleasePage = channel == UpdateChannel.gitee
        ? releasePage ??
              _releasePageUrl(UpdateChannel.gitee, repositorySlug, tagName)
        : _releasePageUrl(UpdateChannel.gitee, repositorySlug, tagName);

    return UpdateInfo(
      tagName: tagName,
      name: _normalizedOptionalString(json['name']),
      body: _normalizedOptionalString(json['body']),
      htmlUrl: githubReleasePage,
      giteeHtmlUrl: giteeReleasePage,
      installerUrl: installerUrl.github,
      giteeInstallerUrl: installerUrl.gitee,
      installerSha256: _assetDigest(installer),
      installerChecksumUrl: installerChecksumUrls.github,
      giteeInstallerChecksumUrl: installerChecksumUrls.gitee,
      installerSize: _normalizedInt(installer?['size']),
      portableUrl: portableUrl.github,
      giteePortableUrl: portableUrl.gitee,
      portableSha256: _assetDigest(portable),
      portableChecksumUrl: portableChecksumUrls.github,
      giteePortableChecksumUrl: portableChecksumUrls.gitee,
      portableSize: _normalizedInt(portable?['size']),
      size:
          _normalizedInt(installer?['size']) ??
          _normalizedInt(portable?['size']),
    );
  }

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    final legacyInstallerUrl = _normalizedOptionalString(json['installer_url']);
    final legacyPortableUrl = _normalizedOptionalString(json['portable_url']);
    final legacyInstallerChecksum = _normalizedOptionalString(
      json['installer_checksum_url'],
    );
    final legacyPortableChecksum = _normalizedOptionalString(
      json['portable_checksum_url'],
    );
    final githubReleasePage = _normalizedOptionalString(json['html_url']);
    final fallbackSize = _normalizedInt(json['size']);
    return UpdateInfo(
      tagName: _normalizedRequiredString(json['tag_name']),
      name: _normalizedOptionalString(json['name']),
      body: _normalizedOptionalString(json['body']),
      htmlUrl:
          _normalizedOptionalString(json['github_release_url']) ??
          githubReleasePage,
      giteeHtmlUrl: _optionalStringOrFallback(
        json,
        'gitee_release_url',
        _replaceHost(githubReleasePage, 'gitee.com'),
      ),
      installerUrl: legacyInstallerUrl,
      giteeInstallerUrl: _optionalStringOrFallback(
        json,
        'gitee_installer_url',
        _replaceHost(legacyInstallerUrl, 'gitee.com'),
      ),
      installerSha256: _normalizeDigest(json['installer_sha256']),
      installerChecksumUrl: legacyInstallerChecksum,
      giteeInstallerChecksumUrl: _optionalStringOrFallback(
        json,
        'gitee_installer_checksum_url',
        _replaceHost(legacyInstallerChecksum, 'gitee.com'),
      ),
      installerSize: _optionalIntOrFallback(
        json,
        'installer_size',
        fallbackSize,
      ),
      portableUrl: legacyPortableUrl,
      giteePortableUrl: _optionalStringOrFallback(
        json,
        'gitee_portable_url',
        _replaceHost(legacyPortableUrl, 'gitee.com'),
      ),
      portableSha256: _normalizeDigest(json['portable_sha256']),
      portableChecksumUrl: legacyPortableChecksum,
      giteePortableChecksumUrl: _optionalStringOrFallback(
        json,
        'gitee_portable_checksum_url',
        _replaceHost(legacyPortableChecksum, 'gitee.com'),
      ),
      portableSize: _optionalIntOrFallback(json, 'portable_size', fallbackSize),
      size: fallbackSize,
    );
  }

  Map<String, dynamic> toJson() => {
    'tag_name': tagName,
    'name': name,
    'body': body,
    'html_url': htmlUrl,
    'gitee_release_url': giteeHtmlUrl,
    'installer_url': installerUrl,
    'gitee_installer_url': giteeInstallerUrl,
    'installer_sha256': installerSha256,
    'installer_checksum_url': installerChecksumUrl,
    'gitee_installer_checksum_url': giteeInstallerChecksumUrl,
    'installer_size': installerSize,
    'portable_url': portableUrl,
    'gitee_portable_url': giteePortableUrl,
    'portable_sha256': portableSha256,
    'portable_checksum_url': portableChecksumUrl,
    'gitee_portable_checksum_url': giteePortableChecksumUrl,
    'portable_size': portableSize,
    'size': size,
  };

  String? downloadUrl({
    required UpdateChannel channel,
    required bool portableBuild,
  }) => switch ((channel, portableBuild)) {
    (UpdateChannel.github, false) => installerUrl,
    (UpdateChannel.gitee, false) => giteeInstallerUrl,
    (UpdateChannel.github, true) => portableUrl,
    (UpdateChannel.gitee, true) => giteePortableUrl,
  };

  String? sha256({required bool portableBuild}) =>
      portableBuild ? portableSha256 : installerSha256;

  String? checksumUrl({
    required UpdateChannel channel,
    required bool portableBuild,
  }) => switch ((channel, portableBuild)) {
    (UpdateChannel.github, false) => installerChecksumUrl,
    (UpdateChannel.gitee, false) => giteeInstallerChecksumUrl,
    (UpdateChannel.github, true) => portableChecksumUrl,
    (UpdateChannel.gitee, true) => giteePortableChecksumUrl,
  };

  String? releasePageUrl(UpdateChannel channel) =>
      channel == UpdateChannel.github ? htmlUrl : giteeHtmlUrl;

  int? downloadSize({required bool portableBuild}) =>
      portableBuild ? portableSize : installerSize ?? size;

  bool hasChecksum({
    required UpdateChannel channel,
    required bool portableBuild,
  }) =>
      sha256(portableBuild: portableBuild) != null ||
      checksumUrl(channel: channel, portableBuild: portableBuild) != null;
}

typedef _ChannelAssetUrls = ({String? github, String? gitee});

List<Map<String, dynamic>> _releaseAssets(Object? value) {
  if (value is! Iterable) return const [];
  return value
      .whereType<Map>()
      .map((asset) => Map<String, dynamic>.from(asset))
      .toList(growable: false);
}

Map<String, dynamic>? _assetForSuffix(
  List<Map<String, dynamic>> assets,
  String suffix,
) {
  for (final asset in assets) {
    final name = _normalizedOptionalString(asset['name']);
    if (name != null && name.toLowerCase().endsWith(suffix.toLowerCase())) {
      return asset;
    }
  }
  return null;
}

Map<String, dynamic>? _assetForName(
  List<Map<String, dynamic>> assets,
  String expectedName,
) {
  if (expectedName == '.sha256') return null;
  for (final asset in assets) {
    if (_normalizedOptionalString(asset['name'])?.toLowerCase() ==
        expectedName.toLowerCase()) {
      return asset;
    }
  }
  return null;
}

_ChannelAssetUrls _channelAssetUrls(
  Map<String, dynamic>? asset, {
  required UpdateChannel channel,
  required String tagName,
  required String repositorySlug,
}) {
  if (asset == null) return (github: null, gitee: null);
  final rawUrl = _normalizedOptionalString(asset['browser_download_url']);
  final name = _normalizedOptionalString(asset['name']);
  final canonicalUrl =
      rawUrl ??
      (name == null || tagName.isEmpty
          ? null
          : _releaseAssetUrl(channel, repositorySlug, tagName, name));
  if (canonicalUrl == null) return (github: null, gitee: null);
  if (channel == UpdateChannel.github) {
    return (
      github: canonicalUrl,
      gitee: _replaceHost(canonicalUrl, 'gitee.com'),
    );
  }
  return (
    github: _replaceHost(canonicalUrl, 'github.com'),
    gitee: canonicalUrl,
  );
}

String? _releaseAssetUrl(
  UpdateChannel channel,
  String repositorySlug,
  String tagName,
  String assetName,
) {
  final host = channel == UpdateChannel.github ? 'github.com' : 'gitee.com';
  return 'https://$host/$repositorySlug/releases/download/'
      '${Uri.encodeComponent(tagName)}/${Uri.encodeComponent(assetName)}';
}

String _releasePageUrl(
  UpdateChannel channel,
  String repositorySlug,
  String tagName,
) {
  final host = channel == UpdateChannel.github ? 'github.com' : 'gitee.com';
  return 'https://$host/$repositorySlug/releases/tag/'
      '${Uri.encodeComponent(tagName)}';
}

String? _replaceHost(String? value, String host) {
  if (value == null || value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) return null;
  return uri.replace(scheme: 'https', host: host).toString();
}

String? _assetDigest(Map<String, dynamic>? asset) =>
    _normalizeDigest(asset?['digest']) ?? _normalizeDigest(asset?['sha256']);

String? _normalizeDigest(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim().toLowerCase();
  final digest = normalized.startsWith('sha256:')
      ? normalized.substring('sha256:'.length)
      : normalized;
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ? digest : null;
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

String? _optionalStringOrFallback(
  Map<String, dynamic> json,
  String key,
  String? fallback,
) => json.containsKey(key) ? _normalizedOptionalString(json[key]) : fallback;

int? _normalizedInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

int? _optionalIntOrFallback(
  Map<String, dynamic> json,
  String key,
  int? fallback,
) => json.containsKey(key) ? _normalizedInt(json[key]) : fallback;

/// 更新检查服务
///
/// 只访问用户选择的渠道，失败时由更新界面让用户切换。
class UpdateChecker {
  UpdateChecker._();

  static const _githubApiBase = 'https://api.github.com/repos';
  static const _giteeApiBase = 'https://gitee.com/api/v5/repos';
  static const _githubFallbackUrl =
      'https://raw.githubusercontent.com/qingyueyin/Pure-music/main/update/version.json';
  static const _giteeFallbackUrl =
      'https://gitee.com/qingyueyin/Pure-music/raw/main/update/version.json';

  static Future<UpdateInfo?> checkForUpdate({
    required UpdateChannel channel,
  }) async {
    final slug = AppPreference.instance.updateRepoSlug;
    final apiUrl = switch (channel) {
      UpdateChannel.github => '$_githubApiBase/$slug/releases/latest',
      UpdateChannel.gitee => '$_giteeApiBase/$slug/releases/latest',
    };
    final fromApi = await _checkReleaseApi(apiUrl, channel, slug);
    if (fromApi != null) return fromApi;

    final fallbackUrls = _fallbackUrls(channel);
    for (final url in fallbackUrls) {
      final info = await _checkHttpJson(url, channel);
      if (info != null) return info;
    }
    throw UpdateCheckException(channel);
  }

  static Future<UpdateInfo?> _checkReleaseApi(
    String url,
    UpdateChannel channel,
    String repositorySlug,
  ) async {
    try {
      final response = await Dio().get<Map<String, dynamic>>(
        url,
        options: Options(
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 15),
          responseType: ResponseType.json,
          headers: {
            'Accept': channel == UpdateChannel.github
                ? 'application/vnd.github+json'
                : 'application/json',
            'User-Agent': 'Pure-Music-Updater',
            if (channel == UpdateChannel.github)
              'X-GitHub-Api-Version': '2022-11-28',
          },
        ),
      );
      final data = response.data;
      if (data == null) return null;
      final info = UpdateInfo.fromReleaseJson(
        data,
        channel: channel,
        repositorySlug: repositorySlug,
      );
      if (info.tagName.isEmpty) return null;
      return info;
    } catch (error) {
      logger.w(
        '[UpdateChecker] ${channel.name} release API failed: ${error.runtimeType}',
      );
      return null;
    }
  }

  static List<String> _fallbackUrls(UpdateChannel channel) {
    final preferred = switch (channel) {
      UpdateChannel.github => _githubFallbackUrl,
      UpdateChannel.gitee => _giteeFallbackUrl,
    };
    final stored = AppPreference.instance.updateCheckUrls.where((url) {
      final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
      return channel == UpdateChannel.github
          ? host.contains('githubusercontent.com')
          : host == 'gitee.com';
    });
    return <String>{preferred, ...stored}.toList(growable: false);
  }

  static Future<UpdateInfo?> _checkHttpJson(
    String url,
    UpdateChannel channel,
  ) async {
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
    } catch (error) {
      logger.w(
        '[UpdateChecker] ${channel.name} fallback failed: ${error.runtimeType}',
      );
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
