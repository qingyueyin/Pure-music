import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';

String _b64(String text) => base64.encode(utf8.encode(text));

String _lxFile({
  required String lrc,
  String? tlrc,
  String? rlrc,
  String? awlrc,
}) {
  final parts = <String>['lrc:${_b64(lrc)}'];
  if (tlrc != null) parts.add('tlrc:${_b64(tlrc)}');
  if (rlrc != null) parts.add('rlrc:${_b64(rlrc)}');
  if (awlrc != null) parts.add('awlrc:${_b64(awlrc)}');
  return '$lrc\n[awlrc:${parts.join(',')}]\n';
}

void main() {
  group('LX Music 内嵌歌词标签', () {
    test('解析 awlrc 逐字歌词并合并翻译/罗马音', () {
      final text = _lxFile(
        lrc: '[offset:0]\n[00:01.000]ハロ\n[00:05.000]セカイ\n',
        tlrc: '[offset:0]\n[00:01.000]你好世界\n[00:05.000]第二行\n',
        rlrc: '[offset:0]\n[00:01.000]ha ro\n[00:05.000]se ka i\n',
        awlrc:
            '[offset:0]\n'
            '[00:01.000]<0,400>ハ<400,600>ロ\n'
            '[00:05.000]<0,500>セ<500,500>カイ\n',
      );

      final lyric = Lrc.fromLrcTextAuto(
        text,
        LyricFormat.local,
        separator: '┃',
        keepMetadata: true,
      )!;
      final lines = lyric.lines
          .whereType<SyncLyricLine>()
          .where((l) => l.words.isNotEmpty)
          .toList();
      expect(lines, hasLength(2));

      final first = lines.first;
      expect(first.start, const Duration(seconds: 1));
      expect(first.words.map((w) => w.content).join(), 'ハロ');
      expect(first.words.first.start, const Duration(seconds: 1));
      expect(first.words.first.length, const Duration(milliseconds: 400));
      // 行末单字按增强 LRC 规则取默认词长 500ms。
      expect(first.words.last.start, const Duration(milliseconds: 1400));
      expect(first.words.last.length, const Duration(milliseconds: 500));
      expect(first.translation, '你好世界');
      expect(first.romanLyric, 'ha ro');

      expect(lines.last.start, const Duration(seconds: 5));
      expect(lines.last.translation, '第二行');
    });

    test('逐字偏移相对行首计算并为间奏插入空白行', () {
      final text = _lxFile(
        lrc: '[00:01.000]A\n[00:20.000]B\n',
        awlrc: '[00:01.000]<0,500>A\n[00:20.000]<0,500>B\n',
      );

      final lyric = Lrc.fromLrcTextAuto(
        text,
        LyricFormat.local,
        keepMetadata: true,
      )!;
      final lines = lyric.lines.whereType<SyncLyricLine>().toList();
      final realLines = lines.where((l) => l.words.isNotEmpty).toList();
      expect(realLines.first.words.single.start, const Duration(seconds: 1));
      final blanks = lines.where((l) => l.words.isEmpty).toList();
      // 前奏空白行 0-1s；行末单字按增强 LRC 默认词长 500ms 结束于 1.5s，
      // 间奏空白行从 1.5s 插到 20s。
      expect(blanks, hasLength(2));
      expect(blanks.first.start, Duration.zero);
      expect(blanks.first.length, const Duration(seconds: 1));
      expect(blanks.last.start, const Duration(milliseconds: 1500));
      expect(blanks.last.length, const Duration(milliseconds: 18500));
      expect(lyric.isWordByWord, isTrue);
    });

    test('无 awlrc 时回退标签内普通歌词并补齐翻译', () {
      final text = _lxFile(
        lrc: '[00:01.000]Hello\n[00:05.000]World\n',
        tlrc: '[00:01.000]你好\n[00:05.000]世界\n',
      );

      final lyric = Lrc.fromLrcTextAuto(
        text,
        LyricFormat.local,
        separator: '┃',
        keepMetadata: true,
      )!;
      expect(lyric.lines.whereType<SyncLyricLine>(), isEmpty);
      final lines = lyric.lines
          .whereType<LrcLine>()
          .where((l) => l.content.isNotEmpty)
          .toList();
      expect(lines, hasLength(2));
      expect(lines[0].start, const Duration(seconds: 1));
      expect(lines[0].content, 'Hello');
      expect(lines[0].translation, '你好');
      expect(lines[1].start, const Duration(seconds: 5));
      expect(lines[1].content, 'World');
      expect(lines[1].translation, '世界');
    });

    test('没有标签时保持普通 LRC 行为', () {
      final lyric = Lrc.fromLrcTextAuto(
        '[00:01.000]Hello\n[00:05.000]World\n',
        LyricFormat.local,
        separator: '┃',
      )!;
      final lines = lyric.lines
          .whereType<LrcLine>()
          .where((l) => l.content.isNotEmpty)
          .toList();
      expect(lines, hasLength(2));
      expect(lines[0].start, const Duration(seconds: 1));
      expect(lines[0].content, 'Hello');
      expect(lines[1].start, const Duration(seconds: 5));
      expect(lines[1].content, 'World');
    });

    test('awlrc 中夹带的普通行整行保留并补齐时长', () {
      final text = _lxFile(
        lrc:
            '[00:01.000]逐字\n[00:03.000]普通行\n[00:04.000]又是逐字\n'
            '[00:08.000]末尾普通行\n',
        awlrc:
            '[00:01.000]<0,500>逐<500,500>字\n'
            '[00:03.000]普通行\n'
            '[00:04.000]<0,500>又<500,500>是<1000,500>逐字\n'
            '[00:08.000]末尾普通行\n',
      );

      final lyric = Lrc.fromLrcTextAuto(
        text,
        LyricFormat.local,
        separator: '┃',
        keepMetadata: true,
      )!;
      final lines = lyric.lines
          .whereType<SyncLyricLine>()
          .where((l) => l.words.isNotEmpty)
          .toList();
      expect(lines.map((l) => l.content), <String>[
        '逐字',
        '普通行',
        '又是逐字',
        '末尾普通行',
      ]);

      final plain = lines[1];
      expect(plain.start, const Duration(seconds: 3));
      expect(plain.length, const Duration(seconds: 1));
      expect(plain.words.single.content, '普通行');

      final last = lines.last;
      expect(last.start, const Duration(seconds: 8));
      // 末行没有下一行，按增强 LRC 规则行长默认 5s。
      expect(last.length, const Duration(seconds: 5));
      expect(last.words.single.content, '末尾普通行');
    });

    test('awlrc 中与逐字行同时间戳的普通行按翻译分组合并', () {
      final text = _lxFile(
        lrc: '[00:01.000]逐字\n[00:02.000]普通\n',
        awlrc:
            '[00:01.000]<0,500>逐<500,500>字\n'
            '[00:02.000]普通\n'
            '[00:02.000]同时行\n',
      );

      final lyric = Lrc.fromLrcTextAuto(
        text,
        LyricFormat.local,
        separator: '┃',
        keepMetadata: true,
      )!;
      final lines = lyric.lines
          .whereType<SyncLyricLine>()
          .where((l) => l.words.isNotEmpty)
          .toList();
      // 同一时间戳的行由现有解析按原文+翻译分组，不丢词。
      expect(lines, hasLength(2));
      expect(lines[1].start, const Duration(seconds: 2));
      expect(lines[1].content, '普通');
      expect(lines[1].translation, '同时行');
    });

    test('awlrc 中夹带的元数据标签行被跳过', () {
      // 真实洛雪导出的 awlrc 常带 [ver:]、[ti:]、[offset:] 等标签行
      final text = _lxFile(
        lrc:
            '[ver:v1.0]\n[ti:标题]\n[ar:歌手]\n[al:专辑]\n[offset:0]\n'
            '[00:01.000]Hello\n',
        awlrc:
            '[ver:v1.0]\n[ti:标题]\n[ar:歌手]\n[al:专辑]\n[offset:0]\n'
            '[00:01.000]<0,500>Hel<500,500>lo\n',
      );

      final lyric = Lrc.fromLrcTextAuto(
        text,
        LyricFormat.local,
        separator: '┃',
        keepMetadata: true,
      )!;
      final wordLines = lyric.lines
          .whereType<SyncLyricLine>()
          .where((l) => l.words.isNotEmpty)
          .toList();
      expect(wordLines, hasLength(1));
      expect(wordLines.single.content, 'Hello');
      final allContents = lyric.lines
          .whereType<SyncLyricLine>()
          .map((l) => l.content)
          .join('\n');
      expect(allContents, isNot(contains('v1.0')));
      expect(allContents, isNot(contains('标题')));
    });
  });
}
