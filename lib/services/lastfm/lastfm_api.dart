import 'package:dio/dio.dart';
import 'package:pure_music/services/lastfm/lastfm_models.dart';

const lastFmApiUrl = 'https://ws.audioscrobbler.com/2.0/';

typedef LastFmHttpSend =
    Future<Map<String, dynamic>> Function({
      required bool post,
      required Map<String, String> fields,
    });

class LastFmApi {
  LastFmApi({LastFmHttpSend? send}) : _send = send ?? _dioSend;

  final LastFmHttpSend _send;

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 30),
      validateStatus: (_) => true,
    ),
  );

  Future<String> requestAuthorizationToken(LastFmCredentials credentials) async {
    _requireAppCredentials(credentials);
    final root = await _signedGet(credentials, 'auth.getToken', const {});
    final token = (root['token'] as String?)?.trim() ?? '';
    if (token.isEmpty) {
      throw const LastFmApiException(
        code: -1,
        message: 'Last.fm 未返回授权令牌',
      );
    }
    return token;
  }

  Future<LastFmSession> finishAuthorization(
    LastFmCredentials credentials,
    String token,
  ) async {
    _requireAppCredentials(credentials);
    final root = await _signedGet(credentials, 'auth.getSession', {
      'token': token,
    });
    return sessionFromLastFmJson(root);
  }

  Future<void> updateNowPlaying(
    LastFmCredentials credentials,
    LastFmPendingScrobble track,
  ) async {
    if (!credentials.isAuthorized) return;
    await _signedPost(credentials, 'track.updateNowPlaying', {
      'artist': track.artist,
      'track': track.track,
      if (track.album.isNotEmpty) 'album': track.album,
      if (track.durationSeconds > 0) 'duration': '${track.durationSeconds}',
    });
  }

  /// 返回 false 表示请求成功但这条播放被过滤。
  Future<bool> scrobble(
    LastFmCredentials credentials,
    LastFmPendingScrobble track,
  ) async {
    if (!credentials.isAuthorized) {
      throw const LastFmApiException(code: 9, message: 'Last.fm 未授权');
    }
    final root = await _signedPost(credentials, 'track.scrobble', {
      'artist': track.artist,
      'track': track.track,
      'timestamp': '${(track.startedAt / 1000).floor().clamp(0, 1 << 31)}',
      if (track.album.isNotEmpty) 'album': track.album,
      if (track.durationSeconds > 0) 'duration': '${track.durationSeconds}',
    });
    return scrobbleAcceptedFromLastFmJson(root);
  }

  Future<Map<String, dynamic>> _signedGet(
    LastFmCredentials credentials,
    String method,
    Map<String, String> parameters,
  ) {
    return _send(
      post: false,
      fields: _signedFields(credentials, method, parameters),
    );
  }

  Future<Map<String, dynamic>> _signedPost(
    LastFmCredentials credentials,
    String method,
    Map<String, String> parameters,
  ) {
    return _send(
      post: true,
      fields: _signedFields(credentials, method, parameters),
    );
  }

  Map<String, String> _signedFields(
    LastFmCredentials credentials,
    String method,
    Map<String, String> parameters,
  ) {
    final fields = <String, String>{
      for (final entry in parameters.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value,
      'api_key': credentials.apiKey,
      'method': method,
    };
    if (credentials.sessionKey.isNotEmpty) {
      fields['sk'] = credentials.sessionKey;
    }
    fields['api_sig'] = lastFmApiSignature(fields, credentials.sharedSecret);
    fields['format'] = 'json';
    return fields;
  }

  static void _requireAppCredentials(LastFmCredentials credentials) {
    if (!credentials.hasAppCredentials) {
      throw const LastFmApiException(
        code: -1,
        message: '请先填写 Last.fm API Key 和 Shared Secret',
      );
    }
  }

  static Future<Map<String, dynamic>> _dioSend({
    required bool post,
    required Map<String, String> fields,
  }) async {
    final Response<dynamic> response;
    if (post) {
      response = await _dio.post<dynamic>(
        lastFmApiUrl,
        data: fields,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } else {
      response = await _dio.get<dynamic>(
        lastFmApiUrl,
        queryParameters: fields,
      );
    }
    return parseLastFmResponse(response.data, httpCode: response.statusCode);
  }
}

LastFmSession sessionFromLastFmJson(Map<String, dynamic> root) {
  final session = root['session'];
  if (session is! Map) {
    throw const LastFmApiException(code: -1, message: 'Last.fm 未返回会话');
  }
  final username = (session['name'] as String?)?.trim() ?? '';
  final sessionKey = (session['key'] as String?)?.trim() ?? '';
  if (username.isEmpty) {
    throw const LastFmApiException(code: -1, message: 'Last.fm 未返回用户名');
  }
  if (sessionKey.isEmpty) {
    throw const LastFmApiException(code: -1, message: 'Last.fm 未返回会话密钥');
  }
  return LastFmSession(username: username, sessionKey: sessionKey);
}

bool scrobbleAcceptedFromLastFmJson(Map<String, dynamic> root) {
  final scrobbles = root['scrobbles'];
  if (scrobbles is! Map) return true;
  final attr = scrobbles['@attr'];
  final accepted = _intOf(
    attr is Map ? attr['accepted'] : scrobbles['accepted'],
    fallback: 1,
  );
  return accepted > 0;
}

Map<String, dynamic> parseLastFmResponse(
  Object? data, {
  int? httpCode,
}) {
  final root = _asJsonMap(data);
  if (root == null) {
    throw LastFmApiException(
      code: -1,
      message: 'Last.fm 请求失败${httpCode == null ? '' : '：HTTP $httpCode'}',
    );
  }
  if (root.containsKey('error')) {
    throw LastFmApiException(
      code: _intOf(root['error'], fallback: -1),
      message: ((root['message'] as String?) ?? '').trim().isEmpty
          ? 'Last.fm 请求失败'
          : (root['message'] as String).trim(),
    );
  }
  if (httpCode != null && (httpCode < 200 || httpCode >= 300)) {
    throw LastFmApiException(
      code: -1,
      message: 'Last.fm 请求失败：HTTP $httpCode',
    );
  }
  return root;
}

Map<String, dynamic>? _asJsonMap(Object? data) {
  if (data is Map<String, dynamic>) return data;
  if (data is Map) {
    return data.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

int _intOf(Object? value, {required int fallback}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString().trim() ?? '') ?? fallback;
}
