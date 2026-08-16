import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/matcher.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_source_view.dart';

void main() {
  final audio = Audio(
    'Test Song',
    'Test Artist',
    'Test Album',
    null,
    1,
    240,
    240,
    44100,
    'C:/music/lyric-source-selection-test.mp3',
    0,
    0,
    null,
  );
  final result = SongSearchResult(
    ResultSource.amll,
    'Test Song',
    'Test Artist',
    'Test Album',
    100,
    amllTtmlFile: 'test.ttml',
  );

  tearDown(() {
    lyricSources.remove(audio.path);
  });

  test('does not save an online source when validation fails', () async {
    var persisted = false;
    var activated = false;

    final applied = await applyValidatedOnlineLyricResult(
      audio,
      result,
      loadLyric: (_, _) async => null,
      persist: () async {
        persisted = true;
      },
      activate: () => activated = true,
    );

    expect(applied, isFalse);
    expect(lyricSources.containsKey(audio.path), isFalse);
    expect(persisted, isFalse);
    expect(activated, isFalse);
  });

  test('saves and activates a validated online source', () async {
    var persisted = false;
    var activated = false;
    final lyric = Lyric([LyricLine(Duration.zero, const Duration(seconds: 1))]);

    final applied = await applyValidatedOnlineLyricResult(
      audio,
      result,
      loadLyric: (_, _) async => lyric,
      persist: () async {
        persisted = true;
      },
      activate: () => activated = true,
    );

    expect(applied, isTrue);
    expect(lyricSources[audio.path]?.source, LyricSourceType.amll);
    expect(lyricSources[audio.path]?.amllTtmlFile, 'test.ttml');
    expect(persisted, isTrue);
    expect(activated, isTrue);
  });

  test('saves and activates a validated local lyric file', () async {
    var activated = false;
    final lyric = Lyric([LyricLine(Duration.zero, const Duration(seconds: 1))]);

    final applied = await applyValidatedLocalLyricFile(
      audio,
      r'C:\lyrics\selected.lrc',
      loadLyric: (_) async => lyric,
      persist: () async {},
      activate: (value) => activated = identical(value, lyric),
      canActivate: () => true,
    );

    expect(applied, isTrue);
    expect(lyricSources[audio.path]?.source, LyricSourceType.local);
    expect(lyricSources[audio.path]?.localLyricPath, r'C:\lyrics\selected.lrc');
    expect(activated, isTrue);
  });

  test(
    'keeps the previous source when local source persistence fails',
    () async {
      lyricSources[audio.path] = result.toLyricSource();
      final lyric = Lyric([
        LyricLine(Duration.zero, const Duration(seconds: 1)),
      ]);

      await expectLater(
        applyValidatedLocalLyricFile(
          audio,
          r'C:\lyrics\selected.lrc',
          loadLyric: (_) async => lyric,
          persist: () async => throw StateError('save failed'),
          canActivate: () => true,
        ),
        throwsStateError,
      );

      expect(lyricSources[audio.path]?.source, LyricSourceType.amll);
      expect(lyricSources[audio.path]?.amllTtmlFile, 'test.ttml');
    },
  );

  test('restores automatic local lyric matching', () async {
    lyricSources[audio.path] = LyricSource(
      LyricSourceType.local,
      localLyricPath: r'C:\lyrics\selected.lrc',
    );
    var activated = false;

    await restoreAutomaticLocalLyric(
      audio,
      persist: () async {},
      activate: () => activated = true,
      canActivate: () => true,
    );

    expect(lyricSources[audio.path]?.source, LyricSourceType.local);
    expect(lyricSources[audio.path]?.localLyricPath, isNull);
    expect(activated, isTrue);
  });

  test('does not activate a selected file after the song changes', () async {
    final lyric = Lyric([LyricLine(Duration.zero, const Duration(seconds: 1))]);
    var activated = false;

    final applied = await applyValidatedLocalLyricFile(
      audio,
      r'C:\lyrics\selected.lrc',
      loadLyric: (_) async => lyric,
      persist: () async {},
      activate: (_) => activated = true,
      canActivate: () => false,
    );

    expect(applied, isTrue);
    expect(lyricSources[audio.path]?.localLyricPath, isNotNull);
    expect(activated, isFalse);
  });
}
