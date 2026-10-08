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
        lrc: '[offset:0]\n[00:01.000]Hello world\n[00:05.000]Second line\n',
        tlrc: '[offset:0]\n[00:01.000]你好世界\n[00:05.000]第二行\n',
        rlrc: '[offset:0]\n[00:01.000]Hello world\n[00:05.000]Second line\n',
        awlrc: '[offset:0]\n'
            '[00:01.000]<0,400>Hello <400,600>world\n'
            '[00:05.000]<0,500>Second <500,500>line\n',
      );

      final lyric = Lrc.fromLrcTextAuto(
        text,
        LyricFormat.local,
        separator: '┃',
        keepMetadata: true,
      )!;
      final lines = lyric.lines.whereType<SyncLyricLine>().toList();
      expect(lines, hasLength(2));

      final first = lines.first;
      expect(first.start, const Duration(seconds: 1));
      expect(first.words.map((w) => w.content).join(), 'Hello world');
      expect(first.words.first.start, const Duration(seconds: 1));
      expect(first.words.first.length, const Duration(milliseconds: 400));
      expect(first.words.last.start, const Duration(milliseconds: 1400));
      expect(first.translation, '你好世界');
      expect(first.romanLyric, 'Hello world');

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
      expect(lines.any((l) => l.words.isEmpty), isTrue);
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
      final lines = lyric.lines.whereType<LrcLine>().toList();
      expect(
        lines.map((l) => l.content).where((c) => c.isNotEmpty),
        containsAll(<String>['Hello', 'World']),
      );
      final translated = lines.map((l) => l.translation).whereType<String>();
      expect(translated, containsAll(<String>['你好', '世界']));
    });

    test('没有标签时保持普通 LRC 行为', () {
      final lyric = Lrc.fromLrcTextAuto(
        '[00:01.000]Hello\n[00:05.000]World\n',
        LyricFormat.local,
        separator: '┃',
      )!;
      expect(lyric.lines.whereType<LrcLine>(), isNotEmpty);
    });

    test('awlrc 中夹带的普通行整行保留并补齐时长', () {
      final text = _lxFile(
        lrc: '[00:01.000]逐字\n[00:03.000]普通行\n[00:04.000]又是逐字\n'
            '[00:08.000]末尾普通行\n',
        awlrc: '[00:01.000]<0,500>逐<500,500>字\n'
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
      final lines = lyric.lines.whereType<SyncLyricLine>().toList();
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
      expect(last.length, const Duration(seconds: 5));
      expect(last.words.single.content, '末尾普通行');
    });
  });
}