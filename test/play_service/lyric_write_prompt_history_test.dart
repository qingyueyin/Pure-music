import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/lyric_write_prompt_history.dart';

void main() {
  test('a prompt is recorded when it is displayed', () {
    final history = LyricWritePromptHistory();

    expect(history.shouldPrompt('song.flac'), isTrue);
    history.markPromptShown('song.flac');

    expect(history.shouldPrompt('song.flac'), isFalse);
  });

  test('failed writes allow the song to be prompted again', () {
    final history = LyricWritePromptHistory();
    history.markPromptShown('song.flac');

    history.markWriteFailed('song.flac');

    expect(history.shouldPrompt('song.flac'), isTrue);
  });

  test('songs with embedded lyrics are suppressed', () {
    final history = LyricWritePromptHistory();

    history.markEmbeddedLyricFound('song.flac');

    expect(history.shouldPrompt('song.flac'), isFalse);
  });
}
