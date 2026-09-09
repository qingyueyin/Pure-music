import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/services/lastfm/lastfm_api.dart';
import 'package:pure_music/services/lastfm/lastfm_models.dart';

void main() {
  group('lastFmScrobbleThresholdMs', () {
    test('skips tracks of 30 seconds or shorter', () {
      expect(lastFmScrobbleThresholdMs(0), 240000);
      expect(lastFmScrobbleThresholdMs(1), -1);
      expect(lastFmScrobbleThresholdMs(30), -1);
    });

    test('uses half duration until the four-minute cap', () {
      expect(lastFmScrobbleThresholdMs(120), 60000);
      expect(lastFmScrobbleThresholdMs(480), 240000);
      expect(lastFmScrobbleThresholdMs(600), 240000);
    });
  });

  test('api signature concatenates sorted fields and the shared secret', () {
    expect(
      lastFmApiSignature(
        {'method': 'auth.getToken', 'api_key': 'abc'},
        'secret',
      ),
      lastFmMd5('api_keyabcmethodauth.getTokensecret'),
    );
  });

  test('authorization url includes api key and token', () {
    expect(
      lastFmAuthorizationUrl(apiKey: 'k', token: 't'),
      'https://www.last.fm/api/auth/?api_key=k&token=t',
    );
  });

  test('pending scrobble skips blank title or artist', () {
    expect(
      pendingScrobbleFrom(
        title: '  ',
        artist: 'A',
        album: 'B',
        durationSec: 180,
        startedAt: 1,
      ),
      isNull,
    );
    final scrobble = pendingScrobbleFrom(
      title: ' Song ',
      artist: ' Artist ',
      album: ' Album ',
      durationSec: 180,
      startedAt: 42,
    )!;
    expect(scrobble.track, 'Song');
    expect(scrobble.artist, 'Artist');
    expect(scrobble.album, 'Album');
    expect(scrobble.durationSeconds, 180);
    expect(scrobble.id, lastFmMd5('Song|Artist|Album|42'));
  });

  test('session json requires both username and session key', () {
    expect(
      () => sessionFromLastFmJson({'session': {'name': 'u'}}),
      throwsA(isA<LastFmApiException>()),
    );
    final session = sessionFromLastFmJson({
      'session': {'name': 'u', 'key': 'sk'},
    });
    expect(session.username, 'u');
    expect(session.sessionKey, 'sk');
  });

  test('scrobble json treats missing accepted as success and zero as ignored', () {
    expect(scrobbleAcceptedFromLastFmJson({}), isTrue);
    expect(
      scrobbleAcceptedFromLastFmJson({
        'scrobbles': {
          '@attr': {'accepted': 1, 'ignored': 0},
        },
      }),
      isTrue,
    );
    expect(
      scrobbleAcceptedFromLastFmJson({
        'scrobbles': {
          '@attr': {'accepted': 0, 'ignored': 1},
        },
      }),
      isFalse,
    );
  });

  test('error payload becomes LastFmApiException', () {
    expect(
      () => parseLastFmResponse({'error': 9, 'message': 'Invalid session key'}),
      throwsA(
        isA<LastFmApiException>()
            .having((error) => error.code, 'code', 9)
            .having((error) => error.requiresReauthentication, 'reauth', isTrue),
      ),
    );
  });

  test('credentials round-trip and drop authorization when app keys change', () {
    const original = LastFmCredentials(
      apiKey: 'k',
      sharedSecret: 's',
      username: 'u',
      sessionKey: 'sk',
      pendingToken: 'tok',
    );
    expect(original.isAuthorized, isTrue);
    final restored = LastFmCredentials.fromMap(original.toMap());
    expect(restored.apiKey, 'k');
    expect(restored.sessionKey, 'sk');
    expect(restored.pendingToken, 'tok');
  });

  test('signed scrobble request signs fields then appends json format', () async {
    late Map<String, String> captured;
    final api = LastFmApi(
      send: ({required post, required fields}) async {
        expect(post, isTrue);
        captured = fields;
        return {
          'scrobbles': {
            '@attr': {'accepted': 1, 'ignored': 0},
          },
        };
      },
    );
    const credentials = LastFmCredentials(
      apiKey: 'k',
      sharedSecret: 's',
      username: 'u',
      sessionKey: 'sk',
    );
    final accepted = await api.scrobble(
      credentials,
      const LastFmPendingScrobble(
        id: '1',
        artist: 'A',
        track: 'T',
        album: 'B',
        durationSeconds: 180,
        startedAt: 42000,
      ),
    );
    expect(accepted, isTrue);
    expect(captured['method'], 'track.scrobble');
    expect(captured['timestamp'], '42');
    expect(captured['format'], 'json');
    final signed = Map<String, String>.from(captured)
      ..remove('api_sig')
      ..remove('format');
    expect(captured['api_sig'], lastFmApiSignature(signed, 's'));
  });

  test('LastFmEnabled is restored from settings', () async {
    addTearDown(() async {
      await AppSettings.readFromSettingsMapForTest({
        'Version': 'test',
        'LastFmEnabled': false,
      });
    });

    await AppSettings.readFromSettingsMapForTest({'Version': 'test'});
    expect(AppSettings.instance.lastFmEnabled, isFalse);

    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'LastFmEnabled': true,
    });
    expect(AppSettings.instance.lastFmEnabled, isTrue);
  });
}
