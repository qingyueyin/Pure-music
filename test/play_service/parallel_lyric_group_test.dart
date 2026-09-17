import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/ttml.dart';
import 'package:pure_music/play_service/lyric_service.dart';

SyncLyricLine _line(int startMs, int lengthMs, {String agent = 'v1'}) {
  final line = SyncLyricLine(
    Duration(milliseconds: startMs),
    Duration(milliseconds: lengthMs),
    [SyncLyricWord(Duration(milliseconds: startMs), Duration(milliseconds: lengthMs), 'x')],
  );
  line.agent = agent;
  return line;
}

void main() {
  group('buildParallelLyricGroups', () {
    test('bg 和声拖尾不会把下一行误判为并行组成员', () {
      // 主行 0：主词 0-2000ms，但 bg 和声一直唱到 6000ms。
      final lineWithLongBg = _line(0, 2000);
      lineWithLongBg.bgText = '和声';
      lineWithLongBg.bgStart = const Duration(milliseconds: 2000);
      lineWithLongBg.bgEnd = const Duration(milliseconds: 6000);

      // 下一行 1：3000-5000ms，主词时间跟行 0 的主词完全不重叠，
      // 只是恰好落在行 0 的 bg 拖尾区间内。
      final nextLine = _line(3000, 2000);

      final lyric = Ttml([lineWithLongBg, nextLine]);

      final lineStartMs = [0, 3000];
      // lineEndMs 模拟 _lyricLineRenderEndMs：行 0 含 bg 拖尾到 6000。
      final lineEndMs = [6000, 5000];

      final groups = buildParallelLyricGroups(
        lyric: lyric,
        lineStartMs: lineStartMs,
        lineEndMs: lineEndMs,
      );

      expect(groups, isEmpty);
    });

    test('主词时间真正重叠时仍然识别为并行组', () {
      final lineA = _line(0, 3000, agent: 'v1');
      final lineB = _line(500, 3000, agent: 'v2');
      final lyric = Ttml([lineA, lineB], LyricFormat.local, null, true);

      final lineStartMs = [0, 500];
      final lineEndMs = [3000, 3500];

      final groups = buildParallelLyricGroups(
        lyric: lyric,
        lineStartMs: lineStartMs,
        lineEndMs: lineEndMs,
      );

      expect(groups, hasLength(1));
      expect(groups.single.members, [0, 1]);
    });

    test('group.endMs 仍然保留 bg 拖尾时长，只是不参与重叠判定', () {
      final lineA = _line(0, 3000, agent: 'v1');
      final lineB = _line(500, 3000, agent: 'v2');
      lineB.bgText = '和声';
      lineB.bgStart = const Duration(milliseconds: 3500);
      lineB.bgEnd = const Duration(milliseconds: 8000);
      final lyric = Ttml([lineA, lineB], LyricFormat.local, null, true);

      final lineStartMs = [0, 500];
      final lineEndMs = [3000, 8000];

      final groups = buildParallelLyricGroups(
        lyric: lyric,
        lineStartMs: lineStartMs,
        lineEndMs: lineEndMs,
      );

      expect(groups, hasLength(1));
      expect(groups.single.endMs, 8000);
    });
  });
}
