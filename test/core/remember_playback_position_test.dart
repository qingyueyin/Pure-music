import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/play_service/playback_service.dart';

void main() {
  tearDown(() async {
    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'RememberPlaybackPosition': false,
    });
  });

  test('old settings keep remembering playback position off', () async {
    await AppSettings.readFromSettingsMapForTest({'Version': 'test'});

    expect(AppSettings.instance.rememberPlaybackPosition, isFalse);
  });

  test('remember playback position is restored from settings', () async {
    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'RememberPlaybackPosition': true,
    });

    expect(AppSettings.instance.rememberPlaybackPosition, isTrue);
  });

  test('last position round-trips through playback preferences', () {
    final preference = PlaybackPreference.fromMap({
      'lastPositionSeconds': 158.9,
    });

    expect(preference.lastPositionSeconds, closeTo(158.9, 0.001));
    expect(preference.toMap()['lastPositionSeconds'], closeTo(158.9, 0.001));
  });

  test('remembered position skips start and end of a track', () {
    expect(
      PlaybackService.rememberedPositionSeconds(
        enabled: true,
        position: 120,
        length: 209,
      ),
      120,
    );
    expect(
      PlaybackService.rememberedPositionSeconds(
        enabled: false,
        position: 120,
        length: 209,
      ),
      0,
    );
    expect(
      PlaybackService.rememberedPositionSeconds(
        enabled: true,
        position: 0.4,
        length: 209,
      ),
      0,
    );
    expect(
      PlaybackService.rememberedPositionSeconds(
        enabled: true,
        position: 208.5,
        length: 209,
      ),
      0,
    );
  });

  test('restored position is ignored near the end of a track', () {
    expect(
      PlaybackService.restoredPositionSeconds(
        savedAudioPath: 'song-a.flac',
        restoredAudioPath: 'song-a.flac',
        enabled: true,
        savedPosition: 158.9,
        length: 209,
      ),
      158.9,
    );
    expect(
      PlaybackService.restoredPositionSeconds(
        savedAudioPath: 'song-a.flac',
        restoredAudioPath: 'song-a.flac',
        enabled: false,
        savedPosition: 158.9,
        length: 209,
      ),
      0,
    );
    expect(
      PlaybackService.restoredPositionSeconds(
        savedAudioPath: 'song-a.flac',
        restoredAudioPath: 'song-a.flac',
        enabled: true,
        savedPosition: 208.5,
        length: 209,
      ),
      0,
    );
  });

  test('saved position is not applied to a replacement track', () {
    expect(
      PlaybackService.restoredPositionSeconds(
        enabled: true,
        savedPosition: 120,
        length: 240,
        savedAudioPath: 'removed.flac',
        restoredAudioPath: 'replacement.flac',
      ),
      0,
    );
  });

  test('restored position rejects non-finite values', () {
    for (final position in [double.nan, double.infinity, -double.infinity]) {
      expect(
        PlaybackService.restoredPositionSeconds(
          enabled: true,
          savedPosition: position,
          length: 240,
          savedAudioPath: 'song.flac',
          restoredAudioPath: 'song.flac',
        ),
        0,
      );
    }
  });
}
