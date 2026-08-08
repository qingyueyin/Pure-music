import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/library/audio_library.dart';

void main() {
  tearDown(() {
    AppPreference.instance.userFolders = [];
    AppPreference.instance.folderAliases = {};
    AudioLibrary.instance.folders = [];
  });

  test('aggregated root carries alias into display name', () {
    AppPreference.instance.userFolders = [r'D:\Music'];
    AppPreference.instance.folderAliases[pendingFolderKey(r'D:\Music')] =
        '我的歌单目录';

    final roots = AudioLibrary.aggregatedRootFolders();

    expect(roots.single.alias, '我的歌单目录');
    expect(roots.single.displayName, '我的歌单目录');
  });

  test('alias lookup ignores path case and trailing slash', () {
    AppPreference.instance.userFolders = [r'D:\Music'];
    AppPreference.instance.folderAliases[pendingFolderKey('d:/music/')] =
        '规范化命中';

    final roots = AudioLibrary.aggregatedRootFolders();

    expect(roots.single.displayName, '规范化命中');
  });

  test('display name falls back to directory name without alias', () {
    AppPreference.instance.userFolders = [r'D:\Music\Sub'];
    AppPreference.instance.folderAliases.clear();

    final roots = AudioLibrary.aggregatedRootFolders();

    expect(roots.single.displayName, 'Sub');
  });

  test('applyStoredMap parses folderAliases and drops blank values', () {
    AppPreference.instance.applyStoredMap({
      'folderAliases': {
        r'D:\A': '第一',
        'd:/b/': '第二',
        r'D:\C': '   ',
        123: 'bad key',
      },
    });

    expect(
      AppPreference.instance.folderAliases[pendingFolderKey(r'D:\A')],
      '第一',
    );
    expect(
      AppPreference.instance.folderAliases[pendingFolderKey(r'D:\B')],
      '第二',
    );
    expect(AppPreference.instance.folderAliases, hasLength(2));
  });
}
