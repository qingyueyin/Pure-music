import 'dart:convert';

import 'package:crypto/crypto.dart';

class LastFmCredentials {
  const LastFmCredentials({
    this.apiKey = '',
    this.sharedSecret = '',
    this.username = '',
    this.sessionKey = '',
    this.pendingToken = '',
  });

  final String apiKey;
  final String sharedSecret;
  final String username;
  final String sessionKey;
  final String pendingToken;

  bool get hasAppCredentials => apiKey.isNotEmpty && sharedSecret.isNotEmpty;

  bool get isAuthorized =>
      hasAppCredentials && username.isNotEmpty && sessionKey.isNotEmpty;

  LastFmCredentials copyWith({
    String? apiKey,
    String? sharedSecret,
    String? username,
    String? sessionKey,
    String? pendingToken,
  }) {
    return LastFmCredentials(
      apiKey: apiKey ?? this.apiKey,
      sharedSecret: sharedSecret ?? this.sharedSecret,
      username: username ?? this.username,
      sessionKey: sessionKey ?? this.sessionKey,
      pendingToken: pendingToken ?? this.pendingToken,
    );
  }

  Map<String, String> toMap() => {
    'apiKey': apiKey,
    'sharedSecret': sharedSecret,
    'username': username,
    'sessionKey': sessionKey,
    'pendingToken': pendingToken,
  };

  factory LastFmCredentials.fromMap(Map? map) {
    if (map == null) return const LastFmCredentials();
    return LastFmCredentials(
      apiKey: _trimmed(map['apiKey']),
      sharedSecret: _trimmed(map['sharedSecret']),
      username: _trimmed(map['username']),
      sessionKey: _trimmed(map['sessionKey']),
      pendingToken: _trimmed(map['pendingToken']),
    );
  }

  bool get isEmpty =>
      apiKey.isEmpty &&
      sharedSecret.isEmpty &&
      username.isEmpty &&
      sessionKey.isEmpty &&
      pendingToken.isEmpty;
}

class LastFmSession {
  const LastFmSession({required this.username, required this.sessionKey});

  final String username;
  final String sessionKey;
}

class LastFmPendingScrobble {
  const LastFmPendingScrobble({
    required this.id,
    required this.artist,
    required this.track,
    required this.album,
    required this.durationSeconds,
    required this.startedAt,
  });

  final String id;
  final String artist;
  final String track;
  final String album;
  final int durationSeconds;
  final int startedAt;

  Map<String, Object> toMap() => {
    'id': id,
    'artist': artist,
    'track': track,
    'album': album,
    'durationSeconds': durationSeconds,
    'startedAt': startedAt,
  };

  factory LastFmPendingScrobble.fromMap(Map map) {
    return LastFmPendingScrobble(
      id: _trimmed(map['id']),
      artist: _trimmed(map['artist']),
      track: _trimmed(map['track']),
      album: _trimmed(map['album']),
      durationSeconds: _intOf(map['durationSeconds']),
      startedAt: _intOf(map['startedAt']),
    );
  }

  bool get isValid => artist.isNotEmpty && track.isNotEmpty && startedAt > 0;
}

class LastFmApiException implements Exception {
  const LastFmApiException({required this.code, required this.message});

  final int code;
  final String message;

  bool get isRetryable => code == 11 || code == 16 || code == 29;

  bool get requiresReauthentication => code == 9;

  @override
  String toString() => message;
}

/// 官方规则：不足 30 秒不提交；否则取一半时长和 4 分钟的较小值。
/// 返回 -1 表示跳过。时长未知时按 4 分钟。
int lastFmScrobbleThresholdMs(int durationSec) {
  if (durationSec <= 0) return 240000;
  if (durationSec <= 30) return -1;
  final halfMs = durationSec * 500;
  return halfMs < 240000 ? halfMs : 240000;
}

LastFmPendingScrobble? pendingScrobbleFrom({
  required String title,
  required String artist,
  required String album,
  required int durationSec,
  required int startedAt,
}) {
  final safeTitle = title.trim();
  final safeArtist = artist.trim();
  if (safeTitle.isEmpty || safeArtist.isEmpty) return null;
  final safeDuration = durationSec < 0 ? 0 : durationSec;
  final id = lastFmMd5(
    '$safeTitle|$safeArtist|${album.trim()}|$startedAt',
  );
  return LastFmPendingScrobble(
    id: id,
    artist: safeArtist,
    track: safeTitle,
    album: album.trim(),
    durationSeconds: safeDuration,
    startedAt: startedAt,
  );
}

String lastFmMd5(String value) =>
    md5.convert(utf8.encode(value)).toString();

String lastFmApiSignature(
  Map<String, String> fields,
  String sharedSecret,
) {
  final keys = fields.keys.toList()..sort();
  final buffer = StringBuffer();
  for (final key in keys) {
    buffer
      ..write(key)
      ..write(fields[key]);
  }
  buffer.write(sharedSecret);
  return lastFmMd5(buffer.toString());
}

String lastFmAuthorizationUrl({
  required String apiKey,
  required String token,
}) {
  return Uri.https('www.last.fm', '/api/auth/', {
    'api_key': apiKey,
    'token': token,
  }).toString();
}

String _trimmed(Object? value) {
  if (value is! String) return '';
  return value.trim();
}

int _intOf(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString().trim() ?? '') ?? 0;
}
