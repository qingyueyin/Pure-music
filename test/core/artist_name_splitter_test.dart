import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/artist_name_splitter.dart';

void main() {
  const separators = ['/', '、'];

  test('splits ordinary multi-artist tags', () {
    expect(
      ArtistNameSplitter.split('张三/李四', separators: separators),
      ['张三', '李四'],
    );
    expect(
      ArtistNameSplitter.split('张三、李四', separators: separators),
      ['张三', '李四'],
    );
  });

  test('empty separators leave the name intact', () {
    expect(
      ArtistNameSplitter.split('张三/李四', separators: const []),
      ['张三/李四'],
    );
  });

  test('treats separators as literal text', () {
    expect(
      ArtistNameSplitter.split('ABCD', separators: const ['.']),
      ['ABCD'],
    );
    expect(
      ArtistNameSplitter.split('A.B', separators: const ['.']),
      ['A', 'B'],
    );
    expect(
      ArtistNameSplitter.split(
        'Artist featuring Guest',
        separators: const ['feat.'],
      ),
      ['Artist featuring Guest'],
    );
  });

  test('protects no-split names inside a longer tag', () {
    expect(
      ArtistNameSplitter.split(
        'AC/DC/张三',
        separators: separators,
        noSplitNames: const ['AC/DC'],
      ),
      ['AC/DC', '张三'],
    );
    expect(
      ArtistNameSplitter.split(
        'ac/dc',
        separators: separators,
        noSplitNames: const ['AC/DC'],
      ),
      ['ac/dc'],
    );
  });

  test('feat separators require surrounding spaces', () {
    expect(
      ArtistNameSplitter.split(
        '周杰伦 feat. 蔡依林',
        separators: ArtistNameSplitter.featSeparators,
      ),
      ['周杰伦', '蔡依林'],
    );
    expect(
      ArtistNameSplitter.split(
        '周杰伦feat.蔡依林',
        separators: ArtistNameSplitter.featSeparators,
      ),
      ['周杰伦feat.蔡依林'],
    );
    expect(
      ArtistNameSplitter.split(
        'Artist featuring Guest',
        separators: ArtistNameSplitter.featSeparators,
      ),
      ['Artist', 'Guest'],
    );
  });

  test('applies manual aliases after splitting', () {
    expect(
      ArtistNameSplitter.split(
        '夜遊/张三',
        separators: separators,
        aliases: const {'夜遊': 'YOASOBI'},
      ),
      ['YOASOBI', '张三'],
    );
    expect(
      ArtistNameSplitter.split(
        'Yoasobi',
        separators: separators,
        aliases: const {'夜遊': 'YOASOBI'},
      ),
      ['Yoasobi'],
    );
  });

  test('alias map keeps the first mapping and ignores identity rows', () {
    expect(
      normalizedArtistAliases({
        ' 夜遊 ': ' YOASOBI ',
        '夜遊': 'ignored',
        'YOASOBI': 'YOASOBI',
        '': 'x',
      }),
      {'夜遊': 'YOASOBI'},
    );
  });
}
