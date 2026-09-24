import 'package:github/github.dart' as gh;
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/update_checker.dart';

void main() {
  test('parses persisted update channel identifiers', () {
    expect(UpdateChannel.parse('github'), UpdateChannel.github);
    expect(UpdateChannel.parse('gitee'), UpdateChannel.gitee);
    expect(UpdateChannel.parse(null), isNull);
    expect(UpdateChannel.parse('unknown'), isNull);
  });

  test('loads a saved update channel and leaves older preferences unset', () {
    final preference = AppPreference();
    preference.applyStoredMap({'updateChannel': 'gitee'});
    expect(UpdateChannel.parse(preference.updateChannel), UpdateChannel.gitee);

    preference.applyStoredMap(const {});
    expect(preference.updateChannel, isNull);
  });

  test('compares stable semantic versions', () {
    expect(UpdateChecker.compareSemVer('v2.3.0', '2.2.10'), greaterThan(0));
    expect(UpdateChecker.compareSemVer('2.2.1+7', 'v2.2.1+8'), 0);
  });

  test('orders prerelease identifiers by semantic-version rules', () {
    expect(UpdateChecker.compareSemVer('2.2.1', '2.2.1-rc.1'), greaterThan(0));
    expect(
      UpdateChecker.compareSemVer('2.2.1-rc.10', '2.2.1-rc.2'),
      greaterThan(0),
    );
    expect(
      UpdateChecker.compareSemVer('2.2.1-beta', '2.2.1-1'),
      greaterThan(0),
    );
  });

  test('does not treat malformed tags as updates', () {
    expect(UpdateChecker.hasNewVersion('release-next', '2.2.1'), isFalse);
    final oversizedMajor = List.filled(100, '9').join();
    expect(
      UpdateChecker.hasNewVersion('$oversizedMajor.0.0', '2.2.1'),
      isFalse,
    );
  });

  test('parses download fields from json', () {
    final info = UpdateInfo.fromJson({
      'tag_name': 'v2.3.0',
      'name': 'v2.3.0',
      'body': 'notes',
      'html_url': 'https://example.com/release',
      'installer_url': 'https://example.com/app-installer.exe',
      'installer_sha256': 'a' * 64,
      'portable_url': 'https://example.com/app-portable.zip',
      'portable_sha256': 'b' * 64,
      'size': 123456,
    });
    expect(info.installerUrl, 'https://example.com/app-installer.exe');
    expect(info.installerSha256, 'a' * 64);
    expect(info.portableUrl, 'https://example.com/app-portable.zip');
    expect(info.portableSha256, 'b' * 64);
    expect(info.size, 123456);
  });

  test('missing download fields default to null', () {
    final info = UpdateInfo.fromJson({'tag_name': 'v2.3.0'});
    expect(info.installerUrl, isNull);
    expect(info.installerSha256, isNull);
    expect(info.portableUrl, isNull);
    expect(info.portableSha256, isNull);
    expect(info.size, isNull);
    expect(
      info.hasChecksum(channel: UpdateChannel.github, portableBuild: false),
      isFalse,
    );
    expect(
      info.hasChecksum(channel: UpdateChannel.github, portableBuild: true),
      isFalse,
    );
  });

  test('keeps installer and portable metadata independent', () {
    final info = UpdateInfo.fromJson({
      'tag_name': 'v2.3.0',
      'installer_url': 'https://example.com/installer.exe',
      'installer_checksum_url': 'https://example.com/installer.exe.sha256',
      'installer_size': 120,
      'portable_url': 'https://example.com/portable.zip',
      'portable_checksum_url': 'https://example.com/portable.zip.sha256',
      'portable_size': 240,
    });

    expect(info.installerChecksumUrl, endsWith('.exe.sha256'));
    expect(info.installerSize, 120);
    expect(info.portableChecksumUrl, endsWith('.zip.sha256'));
    expect(info.portableSize, 240);
    expect(info.downloadSize(portableBuild: false), 120);
    expect(info.downloadSize(portableBuild: true), 240);
    expect(
      info.hasChecksum(channel: UpdateChannel.github, portableBuild: false),
      isTrue,
    );
    expect(
      info.hasChecksum(channel: UpdateChannel.github, portableBuild: true),
      isTrue,
    );
  });

  test('maps release assets and checksum assets', () {
    final release = gh.Release(
      tagName: 'v2.3.0',
      htmlUrl: 'https://example.com/release',
      assets: [
        gh.ReleaseAsset(
          name: 'pure_music_2.3.0_release_installer.exe',
          browserDownloadUrl: 'https://example.com/installer.exe',
          size: 120,
        ),
        gh.ReleaseAsset(
          name: 'pure_music_2.3.0_release_installer.exe.sha256',
          browserDownloadUrl: 'https://example.com/installer.exe.sha256',
        ),
        gh.ReleaseAsset(
          name: 'pure_music_2.3.0_release_portable.zip',
          browserDownloadUrl: 'https://example.com/portable.zip',
          size: 240,
        ),
        gh.ReleaseAsset(
          name: 'pure_music_2.3.0_release_portable.zip.sha256',
          browserDownloadUrl: 'https://example.com/portable.zip.sha256',
        ),
      ],
    );
    final info = UpdateInfo.fromGitHubRelease(release);

    expect(info.installerUrl, endsWith('installer.exe'));
    expect(info.installerChecksumUrl, endsWith('installer.exe.sha256'));
    expect(info.installerSize, 120);
    expect(info.portableUrl, endsWith('portable.zip'));
    expect(info.portableChecksumUrl, endsWith('portable.zip.sha256'));
    expect(info.portableSize, 240);
  });

  test('maps GitHub release assets to both download channels', () {
    final info = UpdateInfo.fromReleaseJson({
      'tag_name': 'v2.4.0',
      'html_url': 'https://github.com/example/app/releases/tag/v2.4.0',
      'assets': [
        {
          'name': 'pure_music_2.4.0_release_installer.exe',
          'browser_download_url':
              'https://github.com/example/app/releases/download/v2.4.0/pure_music_2.4.0_release_installer.exe',
          'digest': 'sha256:${'a' * 64}',
          'size': 120,
        },
        {
          'name': 'pure_music_2.4.0_release_portable.zip',
          'browser_download_url':
              'https://github.com/example/app/releases/download/v2.4.0/pure_music_2.4.0_release_portable.zip',
          'digest': 'sha256:${'b' * 64}',
          'size': 240,
        },
      ],
    }, channel: UpdateChannel.github);

    expect(
      info.downloadUrl(channel: UpdateChannel.github, portableBuild: false),
      contains('github.com/example/app/releases/download/v2.4.0'),
    );
    expect(
      info.downloadUrl(channel: UpdateChannel.gitee, portableBuild: false),
      contains('gitee.com/example/app/releases/download/v2.4.0'),
    );
    expect(info.sha256(portableBuild: false), 'a' * 64);
    expect(info.sha256(portableBuild: true), 'b' * 64);
  });

  test('maps Gitee release assets and permits missing optional checksum', () {
    final info = UpdateInfo.fromReleaseJson({
      'tag_name': 'v2.4.0',
      'assets': [
        {
          'name': 'pure_music_2.4.0_release_installer.exe',
          'browser_download_url':
              'https://gitee.com/example/app/releases/download/v2.4.0/pure_music_2.4.0_release_installer.exe',
          'size': 120,
        },
        {
          'name': 'pure_music_2.4.0_release_portable.zip',
          'browser_download_url':
              'https://gitee.com/example/app/releases/download/v2.4.0/pure_music_2.4.0_release_portable.zip',
          'size': 240,
        },
      ],
    }, channel: UpdateChannel.gitee);

    expect(
      info.downloadUrl(channel: UpdateChannel.gitee, portableBuild: true),
      contains('gitee.com/example/app/releases/download/v2.4.0'),
    );
    expect(
      info.hasChecksum(channel: UpdateChannel.gitee, portableBuild: false),
      isFalse,
    );
    expect(
      info.hasChecksum(channel: UpdateChannel.gitee, portableBuild: true),
      isFalse,
    );
  });

  test('does not reuse installer size when portable size is absent', () {
    final info = UpdateInfo.fromJson({
      'tag_name': 'v2.4.0',
      'installer_size': 120,
      'portable_size': null,
      'size': 120,
    });

    expect(info.downloadSize(portableBuild: false), 120);
    expect(info.downloadSize(portableBuild: true), isNull);
  });

  test('uses Gitee metadata urls when the selected channel is Gitee', () {
    final info = UpdateInfo.fromJson({
      'tag_name': 'v2.4.0',
      'installer_url':
          'https://github.com/example/app/releases/download/v2.4.0/app.exe',
      'gitee_installer_url':
          'https://gitee.com/example/app/releases/download/v2.4.0/app.exe',
      'portable_url':
          'https://github.com/example/app/releases/download/v2.4.0/app.zip',
      'gitee_portable_url':
          'https://gitee.com/example/app/releases/download/v2.4.0/app.zip',
    });

    expect(
      info.downloadUrl(channel: UpdateChannel.gitee, portableBuild: false),
      startsWith('https://gitee.com/'),
    );
    expect(
      info.downloadUrl(channel: UpdateChannel.gitee, portableBuild: true),
      startsWith('https://gitee.com/'),
    );
  });
}
