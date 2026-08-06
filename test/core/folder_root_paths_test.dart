import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/list_action_state.dart';

void main() {
  test('duplicate and nested scan roots collapse to the parent folder', () {
    final result = appendUniquePendingFolders(
      current: const [r'D:\Music\Artist', r'E:\Library'],
      incoming: const [r'd:\music', r'E:\Library\Album', r'D:\Music\'],
    );

    expect(result, [r'E:\Library', r'd:\music']);
  });

  test('similarly prefixed folders remain separate roots', () {
    final result = appendUniquePendingFolders(
      current: const [r'D:\Music'],
      incoming: const [r'D:\Music Backup'],
    );

    expect(result, [r'D:\Music', r'D:\Music Backup']);
  });
}
