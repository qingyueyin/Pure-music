import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_stripper.dart';
import 'package:pure_music/lyric/ttml.dart';
import 'package:pure_music/services/online_lyric/parsers/lrc_tool.dart';

void main() {
  group('lyric metadata detection', () {
    test('keeps ordinary lyrics with punctuation', () {
      expect(
        LrcLine.isLyricMetadataLine(
          '<00:00.378>I <00:00.633>can <00:00.906>see '
          "<00:01.370>you're <00:01.602>standing <00:02.034>on "
          '<00:02.387>the <00:02.565>edge<00:03.980>',
        ),
        isFalse,
      );
      expect(LrcLine.isLyricMetadataLine("I said: don't leave"), isFalse);
      expect(
          LrcLine.isLyricMetadataLine('You - me, against the world'), isFalse);
      expect(LrcLine.isLyricMetadataLine('They provide the light'), isFalse);
    });

    test('recognizes explicit credit labels', () {
      expect(LrcLine.isLyricMetadataLine('作词：Someone'), isTrue);
      expect(LrcLine.isLyricMetadataLine('Lyrics: Someone'), isTrue);
      expect(LrcLine.isLyricMetadataLine('Written by Someone'), isTrue);
      expect(
        LrcLine.isLyricMetadataLine(
          '母带后期处理录音室 Mastering Studio：原艾母带工程 '
          '东京 Mugwort Mastering Tokyo',
        ),
        isTrue,
      );
      expect(
        LrcLine.isLyricMetadataLine('Mastering Engineer: Someone'),
        isTrue,
      );
      expect(LrcLine.isLyricMetadataLine('混音/母带工程师：Someone'), isTrue);
      expect(LrcLine.isLyricMetadataLine('人声录音工程师：Someone'), isTrue);
      expect(
        LrcLine.isLyricMetadataLine('Mixing & Mastering Engineer: Someone'),
        isTrue,
      );
      expect(LrcLine.isLyricMetadataLine('吉他录制录音棚：劳国贤工作室'), isTrue);
      expect(LrcLine.isLyricMetadataLine('人声录制录音棚：BIG.J Studio'), isTrue);
      expect(LrcLine.isLyricMetadataLine('混音师：赵靖'), isTrue);
      expect(LrcLine.isLyricMetadataLine('混音母带棚：BIG.J Studio'), isTrue);
      expect(LrcLine.isLyricMetadataLine('执行制作：Someone'), isTrue);
      expect(LrcLine.isLyricMetadataLine('后期协力：Someone'), isTrue);
      expect(LrcLine.isLyricMetadataLine('和声编写及演唱：Someone'), isTrue);
      expect(
        LrcLine.isLyricMetadataLine('吉他、贝斯及键盘演奏：Someone'),
        isTrue,
      );
      expect(LrcLine.isLyricMetadataLine('周杰伦 人声录制：Someone'), isTrue);
      const additionalCredits = <String>[
        '额外编程：Derrick Sepnio',
        '数字编辑：Derrick Sepnio',
        'Vocal:ランコ',
        '原曲:天空のグリニッジ',
        '音响总监：金少刚',
        '乐队总监：刘卓@维伴音乐',
        '打击乐：刘效松@维伴音乐',
        '电脑工程：郎梓朔@维伴音乐',
      ];
      for (final credit in additionalCredits) {
        expect(LrcLine.isLyricMetadataLine(credit), isTrue, reason: credit);
      }
    });

    test('AMLL TTML only blanks its exact creator row', () {
      final creatorLine = TtmlLine(
        const Duration(seconds: 10),
        const Duration(seconds: 2),
        [
          SyncLyricWord(
            const Duration(seconds: 10),
            const Duration(seconds: 2),
            '【创作者：Someone】',
          ),
        ],
        'Creator: Someone',
      );
      final firstLyricLine = TtmlLine(
        const Duration(seconds: 12),
        const Duration(seconds: 2),
        [
          SyncLyricWord(
            const Duration(seconds: 12),
            const Duration(seconds: 2),
            'Mmm, mmm',
          ),
        ],
      );
      final genericMetadataLine = TtmlLine(
        const Duration(seconds: 14),
        const Duration(seconds: 2),
        [
          SyncLyricWord(
            const Duration(seconds: 14),
            const Duration(seconds: 2),
            '作词：Someone',
          ),
        ],
      );

      blankAmllTtmlCreatorLines([
        creatorLine,
        firstLyricLine,
        genericMetadataLine,
      ]);

      expect(creatorLine.words, isEmpty);
      expect(creatorLine.translation, isNull);
      expect(firstLyricLine.content, 'Mmm, mmm');
      expect(genericMetadataLine.content, '作词：Someone');
    });

    test('keeps lyric-like text near compound credit wording', () {
      expect(LrcLine.isLyricMetadataLine('母带着我的梦走远'), isFalse);
      expect(
        LrcLine.isLyricMetadataLine('Mastering the art of letting go: I tried'),
        isFalse,
      );
      expect(
        LrcLine.isLyricMetadataLine('The studio: where we used to hide'),
        isFalse,
      );
      expect(LrcLine.isLyricMetadataLine('混音在回忆里：我听见你'), isFalse);
      expect(LrcLine.isLyricMetadataLine('女：'), isFalse);
      expect(LrcLine.isLyricMetadataLine('我说：别走'), isFalse);
      expect(
        LrcLine.isLyricMetadataLine('把回忆重新制作：送给你'),
        isFalse,
      );
      expect(
        LrcLine.isLyricMetadataLine('你的声音与吉他：都留在雨里'),
        isFalse,
      );
      expect(
        LrcLine.isLyricMetadataLine('I was recorded by the river: all night'),
        isFalse,
      );
      expect(
        LrcLine.isLyricMetadataLine('The piano by the window: still plays'),
        isFalse,
      );
      expect(
        LrcLine.isLyricMetadataLine('Publishing my thoughts: one by one'),
        isFalse,
      );
    });

    test('recognizes an English production credit block', () {
      const credits = <String>[
        'Publishing, administered by: Songs Of Universal, Inc. (BMI), '
            'April Base',
        'Publishing, administered by: Kobalt Songs Music Publishing (ASCAP), '
            'Justin Deyarmond Edison Vernon (ASCAP).',
        'Taylor Swift vocals recorded by: Laura Sisk at the Kitty Committee '
            'Studio (Los Angeles, CA)',
        'Bon Iver vocals recorded by: Justin Vernon at April Base '
            '(Fall Creek, WI)',
        'Piano, Electric Guitar, Synthesizer, OP-1, Drum Programming, '
            'Percussion by: Aaron Dessner (Hudson Valley, NY)',
        'Orchestration by: Bryce Dessner (Biarritz, FR)',
        'Violin and Viola by: Rob Moose (Brooklyn, NY) recorded by Rob Moose',
        'Bon Iver appears courtesy of: Jagjaguwar',
      ];

      for (final credit in credits) {
        expect(LrcLine.isLyricMetadataLine(credit), isTrue, reason: credit);
      }

      final metadataLines = <LrcLine>[
        for (var i = 0; i < credits.length; i++)
          LrcLine(
            Duration(seconds: i),
            credits[i],
            requiredIsBlank: false,
            length: const Duration(seconds: 1),
          ),
      ];
      final lyricLine = LrcLine(
        const Duration(seconds: 20),
        'I can see you standing honey',
        requiredIsBlank: false,
        length: const Duration(seconds: 4),
      );
      final lines = <LyricLine>[...metadataLines, lyricLine];

      blankMetadataLines(lines);

      expect(metadataLines.every((line) => line.isBlank), isTrue);
      expect(lines, hasLength(2));
      expect(lines.first.start, Duration.zero);
      expect(lines.first.length, const Duration(seconds: 20));
      expect(lines.last, same(lyricLine));
    });

    test('keeps the first enhanced line and its translation', () {
      final lyric = Lrc.fromLrcTextAuto(
        '[00:00.378] <00:00.378>I <00:00.633>can <00:00.906>see '
        "<00:01.370>you're <00:01.602>standing <00:02.034>on "
        '<00:02.387>the <00:02.565>edge<00:03.980>\n'
        '[00:00.378]我看见你正站在悬崖边缘\n'
        '[00:05.000]<00:05.000>The <00:05.300>next '
        '<00:05.700>line<00:06.200>',
        LyricFormat.local,
      );

      final first = lyric!.lines.firstWhere(
        (line) => line is SyncLyricLine && line.words.isNotEmpty,
      ) as SyncLyricLine;
      expect(
        first.words.map((word) => word.content).join().trim(),
        "I can see you're standing on the edge",
      );
      expect(first.translation, '我看见你正站在悬崖边缘');
    });

    test('keeps the first line through the online parser', () {
      final lyric = LrcTool.parse(
        '[00:00.378]<00:00.378>I <00:00.633>can <00:00.906>see '
        "<00:01.370>you're <00:01.602>standing <00:02.034>on "
        '<00:02.387>the <00:02.565>edge<00:03.980>\n'
        '[00:05.000]<00:05.000>The <00:05.300>next '
        '<00:05.700>line<00:06.200>',
        transText: '[00:00.378]我看见你正站在悬崖边缘',
      );

      final first = lyric!.lines.firstWhere((line) => line.content.isNotEmpty);
      expect(first.content.trim(), "I can see you're standing on the edge");
      expect(first.translation, '我看见你正站在悬崖边缘');
    });

    test('only blanks explicit metadata at the header', () {
      final lyricLine = SyncLyricLine(
        const Duration(milliseconds: 378),
        const Duration(seconds: 4),
        [
          SyncLyricWord(
            const Duration(milliseconds: 378),
            const Duration(seconds: 4),
            "I can see you're standing on the edge",
          ),
        ],
        '我看见你正站在悬崖边缘',
      );
      final lines = <LyricLine>[
        SyncLyricLine(
          Duration.zero,
          const Duration(milliseconds: 300),
          [
            SyncLyricWord(
              Duration.zero,
              const Duration(milliseconds: 300),
              '母带后期处理录音室 Mastering Studio：原艾母带工程 '
              '东京 Mugwort Mastering Tokyo',
            ),
          ],
        ),
        lyricLine,
      ];

      blankMetadataLines(lines);

      expect((lines.first as SyncLyricLine).words, isEmpty);
      expect(lyricLine.words, isNotEmpty);
      expect(lyricLine.translation, '我看见你正站在悬崖边缘');
    });

    test('blanks title and artist lines matching the current song', () {
      const samples = <(String, String, List<String>)>[
        ('大人中 - 卢广仲 (Crowd Lu)', '大人中', ['卢广仲']),
        (
          'Too Good At Goodbyes - Sam Smith',
          'Too Good At Goodbyes',
          ['Sam Smith']
        ),
        ('我要的幸福 - 孙燕姿', '我要的幸福', ['孙燕姿']),
        (
          'Beautiful Things - Benson Boone',
          'Beautiful Things',
          ['Benson Boone']
        ),
      ];

      for (final sample in samples) {
        final titleLine = LrcLine(
          Duration.zero,
          sample.$1,
          requiredIsBlank: false,
        );
        final lyricLine = LrcLine(
          const Duration(seconds: 5),
          "I can see you're standing on the edge",
          requiredIsBlank: false,
        );
        final lines = <LyricLine>[titleLine, lyricLine];

        blankMetadataLines(
          lines,
          StripOptions(matchTitle: sample.$2, matchArtists: sample.$3),
        );

        expect(titleLine.isBlank, isTrue, reason: sample.$1);
        expect(lyricLine.content, "I can see you're standing on the edge");
      }
    });

    test('matches title versions and artist aliases without exact spelling',
        () {
      const samples = <(String, String, List<String>)>[
        ('大人中 (Live Version) - Crowd Lu', '大人中', ['卢广仲 (Crowd Lu)']),
        ('光年之外（重混版） - G.E.M.', '光年之外', ['G.E.M.邓紫棋']),
        ('晴天 Remix - 周杰倫', '晴天', ['周杰伦']),
        (
          'exile - Taylor Swift feat. Bon Iver',
          'exile (Live)',
          ['Taylor Swift', 'Bon Iver'],
        ),
        ('光年之外 (Light Years Away) - 邓紫棋', '光年之外', ['G.E.M.邓紫棋']),
        (
          'みんなの謎なぞ - 100回嘔吐/歌愛ユキ/v flower',
          'みんなの謎なぞ',
          ['100回嘔吐/歌愛ユキ/v flower'],
        ),
        ('心的距离(国) - 陈奕迅 (Eason Chan)', '心的距离', ['陈奕迅']),
        ('♪藤井风 - もうええわ 算了吧', 'もうええわ', ['藤井風']),
        (
          'Born Again ft. Doja Cat & RAYE - LISA/Doja Cat/RAYE',
          'Born Again',
          ['LISA/Doja Cat/RAYE'],
        ),
      ];

      for (final sample in samples) {
        final titleLine = LrcLine(
          Duration.zero,
          sample.$1,
          requiredIsBlank: false,
        );
        final lyricLine = LrcLine(
          const Duration(seconds: 5),
          '真正的第一句歌词',
          requiredIsBlank: false,
        );
        final lines = <LyricLine>[titleLine, lyricLine];

        blankMetadataLines(
          lines,
          StripOptions(matchTitle: sample.$2, matchArtists: sample.$3),
        );

        expect(titleLine.isBlank, isTrue, reason: sample.$1);
        expect(lyricLine.content, '真正的第一句歌词');
      }
    });

    test('blanks a reversed title line with a music-note prefix', () {
      final titleLine = LrcLine(
        const Duration(milliseconds: 10573),
        '♪藤井风 - 调子にのっちゃって',
        requiredIsBlank: false,
        translation: '得意忘形',
        length: const Duration(seconds: 3),
      );
      final lyricLine = LrcLine(
        const Duration(seconds: 20),
        'あなたの言叶は この鼻を伸ばす',
        requiredIsBlank: false,
      );
      final lines = <LyricLine>[titleLine, lyricLine];

      blankMetadataLines(
        lines,
        const StripOptions(
          matchTitle: '调子にのっちゃって',
          matchArtists: ['藤井風'],
        ),
      );

      expect(lines, hasLength(2));
      expect(lines.first.start, Duration.zero);
      expect(lines.first.length, const Duration(seconds: 20));
      expect((lines.first as LrcLine).isBlank, isTrue);
      expect(lines.last, same(lyricLine));
    });

    test('keeps an unrelated title-like lyric with current song metadata', () {
      final firstLine = LrcLine(
        Duration.zero,
        'You - me, against the world',
        requiredIsBlank: false,
      );
      final lines = <LyricLine>[
        firstLine,
        LrcLine(
          const Duration(seconds: 5),
          'The next line',
          requiredIsBlank: false,
        ),
      ];

      blankMetadataLines(
        lines,
        const StripOptions(
          matchTitle: 'Beautiful Things',
          matchArtists: ['Benson Boone'],
        ),
      );

      expect(firstLine.content, 'You - me, against the world');
      expect(firstLine.isBlank, isFalse);
    });

    test('does not infer a title line from only a title or artist match', () {
      const samples = <(String, String, List<String>)>[
        (
          'Beautiful Things - someone I used to know',
          'Beautiful Things',
          ['Benson Boone'],
        ),
        (
          'Another Song (Remix) - Benson Boone',
          'Beautiful Things',
          ['Benson Boone'],
        ),
        ('晴天以后 - 周杰伦的背影', '晴天', ['周杰伦']),
      ];

      for (final sample in samples) {
        final firstLine = LrcLine(
          Duration.zero,
          sample.$1,
          requiredIsBlank: false,
        );
        final lines = <LyricLine>[
          firstLine,
          LrcLine(
            const Duration(seconds: 5),
            'The next line',
            requiredIsBlank: false,
          ),
        ];

        blankMetadataLines(
          lines,
          StripOptions(matchTitle: sample.$2, matchArtists: sample.$3),
        );

        expect(firstLine.content, sample.$1);
        expect(firstLine.isBlank, isFalse, reason: sample.$1);
      }
    });

    test('stops the metadata block before a trailing dialogue label', () {
      final metadataLines = <LrcLine>[
        LrcLine(
          Duration.zero,
          '吉他录制录音棚：劳国贤工作室',
          requiredIsBlank: false,
        ),
        LrcLine(
          const Duration(seconds: 1),
          '人声录制录音棚：BIG.J Studio',
          requiredIsBlank: false,
        ),
        LrcLine(
          const Duration(seconds: 2),
          '混音师：赵靖',
          requiredIsBlank: false,
        ),
        LrcLine(
          const Duration(seconds: 3),
          '混音母带棚：BIG.J Studio',
          requiredIsBlank: false,
        ),
      ];
      final dialogueLabel = LrcLine(
        const Duration(seconds: 7),
        '女：',
        requiredIsBlank: false,
      );
      final lyricLine = LrcLine(
        const Duration(seconds: 8),
        '有些东西',
        requiredIsBlank: false,
      );
      final lines = <LyricLine>[
        ...metadataLines,
        dialogueLabel,
        lyricLine,
      ];

      blankMetadataLines(lines);

      expect(metadataLines.every((line) => line.isBlank), isTrue);
      expect(dialogueLabel.content, '女：');
      expect(dialogueLabel.isBlank, isFalse);
      expect(lyricLine.content, '有些东西');
    });

    test('extends one filtered metadata placeholder to the first lyric', () {
      final metadataLine = LrcLine(
        Duration.zero,
        '混音师：赵靖',
        requiredIsBlank: false,
        length: const Duration(seconds: 3),
      );
      final lyricLine = LrcLine(
        const Duration(seconds: 20),
        "I said I've had enough",
        requiredIsBlank: false,
        length: const Duration(seconds: 4),
      );
      final lines = <LyricLine>[metadataLine, lyricLine];

      blankMetadataLines(lines);

      expect(lines, hasLength(2));
      expect(lines.first, isA<LrcLine>());
      expect((lines.first as LrcLine).isBlank, isTrue);
      expect(lines.first.start, Duration.zero);
      expect(lines.first.length, const Duration(seconds: 20));
      expect(lines.last, same(lyricLine));
    });
  });
}
