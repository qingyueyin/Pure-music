import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/native/rust/api/utils.dart' as rust_utils;
import 'package:pure_music/services/lastfm/lastfm_api.dart';
import 'package:pure_music/services/lastfm/lastfm_models.dart';
import 'package:sqlite3/sqlite3.dart';

class LastFmService extends ChangeNotifier {
  LastFmService._({LastFmApi? api}) : _api = api ?? LastFmApi();

  static LastFmService? _instance;
  static LastFmService get instance {
    _instance ??= LastFmService._();
    return _instance!;
  }

  @visibleForTesting
  static LastFmService createForTest({required LastFmApi api}) {
    return LastFmService._(api: api);
  }

  final LastFmApi _api;
  LastFmCredentials _credentials = const LastFmCredentials();
  List<LastFmPendingScrobble> _pending = const [];
  bool _loaded = false;
  Future<void>? _loading;
  Future<void> _queue = Future<void>.value();

  LastFmCredentials get credentials => _credentials;
  List<LastFmPendingScrobble> get pendingScrobbles => _pending;
  bool get isAuthorized => _credentials.isAuthorized;

  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> updateAppCredentials(String apiKey, String sharedSecret) {
    return _enqueue(() async {
      await ensureLoaded();
      final nextKey = apiKey.trim();
      final nextSecret = sharedSecret.trim();
      if (nextKey == _credentials.apiKey &&
          nextSecret == _credentials.sharedSecret) {
        return;
      }
      _credentials = LastFmCredentials(
        apiKey: nextKey,
        sharedSecret: nextSecret,
      );
      _pending = const [];
      notifyListeners();
      await _persist();
    });
  }

  Future<void> beginAuthorization() {
    return _enqueue(() async {
      await ensureLoaded();
      final token = await _api.requestAuthorizationToken(_credentials);
      _credentials = _credentials.copyWith(pendingToken: token);
      notifyListeners();
      await _persistCredentials();
      final opened = await rust_utils.launchInBrowser(
        uri: lastFmAuthorizationUrl(
          apiKey: _credentials.apiKey,
          token: token,
        ),
      );
      if (!opened) {
        throw const LastFmApiException(code: -1, message: '打开授权页失败');
      }
    });
  }

  Future<void> completeAuthorization() {
    return _enqueue(() async {
      await ensureLoaded();
      if (!_credentials.hasAppCredentials) {
        throw const LastFmApiException(
          code: -1,
          message: '请先填写 Last.fm API Key 和 Shared Secret',
        );
      }
      final token = _credentials.pendingToken;
      if (token.isEmpty) {
        throw const LastFmApiException(code: -1, message: '没有待完成的 Last.fm 授权');
      }
      final session = await _api.finishAuthorization(_credentials, token);
      _credentials = _credentials.copyWith(
        username: session.username,
        sessionKey: session.sessionKey,
        pendingToken: '',
      );
      notifyListeners();
      await _persistCredentials();
      await _flushPendingLocked();
    });
  }

  Future<void> clearAuthorization() {
    return _enqueue(() async {
      await ensureLoaded();
      _credentials = _credentials.copyWith(
        username: '',
        sessionKey: '',
        pendingToken: '',
      );
      _pending = const [];
      notifyListeners();
      await _persist();
    });
  }

  Future<void> updateNowPlaying({
    required String title,
    required String artist,
    required String album,
    required int durationSec,
  }) {
    return _enqueue(() async {
      await ensureLoaded();
      if (!AppSettings.instance.lastFmEnabled || !_credentials.isAuthorized) {
        return;
      }
      final track = pendingScrobbleFrom(
        title: title,
        artist: artist,
        album: album,
        durationSec: durationSec,
        startedAt: DateTime.now().millisecondsSinceEpoch,
      );
      if (track == null) return;
      try {
        await _api.updateNowPlaying(_credentials, track);
      } catch (error, trace) {
        logger.w('Last.fm now playing 失败: $title', error: error, stackTrace: trace);
      }
      await _flushPendingLocked();
    });
  }

  Future<void> enqueueScrobble({
    required String title,
    required String artist,
    required String album,
    required int durationSec,
    required int startedAt,
  }) {
    return _enqueue(() async {
      await ensureLoaded();
      if (!AppSettings.instance.lastFmEnabled || !_credentials.isAuthorized) {
        return;
      }
      if (lastFmScrobbleThresholdMs(durationSec) < 0) return;
      final scrobble = pendingScrobbleFrom(
        title: title,
        artist: artist,
        album: album,
        durationSec: durationSec,
        startedAt: startedAt,
      );
      if (scrobble == null) return;
      if (_pending.any((item) => item.id == scrobble.id)) {
        await _flushPendingLocked();
        return;
      }
      final updated = [..._pending, scrobble]
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
      _pending = updated;
      notifyListeners();
      await _persistOutbox();
      await _flushPendingLocked();
    });
  }

  Future<void> flushPendingScrobbles() {
    return _enqueue(() async {
      await ensureLoaded();
      await _flushPendingLocked();
    });
  }

  Future<void> _flushPendingLocked() async {
    if (!AppSettings.instance.lastFmEnabled ||
        !_credentials.isAuthorized ||
        _pending.isEmpty) {
      return;
    }
    var remaining = List<LastFmPendingScrobble>.from(_pending);
    while (remaining.isNotEmpty) {
      final next = remaining.first;
      try {
        final accepted = await _api.scrobble(_credentials, next);
        remaining = remaining.sublist(1);
        _pending = remaining;
        notifyListeners();
        await _persistOutbox();
        if (!accepted) {
          logger.w('Last.fm 忽略了这条记录: ${next.track}');
        }
      } on LastFmApiException catch (error, trace) {
        if (error.requiresReauthentication) {
          _credentials = _credentials.copyWith(
            username: '',
            sessionKey: '',
            pendingToken: '',
          );
          notifyListeners();
          await _persistCredentials();
        }
        logger.w('Last.fm scrobble 仍在队列: ${next.track}', error: error, stackTrace: trace);
        return;
      } catch (error, trace) {
        logger.w('Last.fm scrobble 仍在队列: ${next.track}', error: error, stackTrace: trace);
        return;
      }
    }
  }

  Future<void> _load() async {
    try {
      final db = await AppDb.instance.db();
      _ensureSchema(db);
      _credentials = LastFmCredentials.fromMap(_readMetaMap(db, 'lastfm_credentials'));
      _pending = _readOutbox(db);
      _loaded = true;
      notifyListeners();
      if (AppSettings.instance.lastFmEnabled &&
          _credentials.isAuthorized &&
          _pending.isNotEmpty) {
        unawaited(flushPendingScrobbles());
      }
    } catch (error, trace) {
      logger.e('读取 Last.fm 状态失败', error: error, stackTrace: trace);
      _loaded = true;
    }
  }

  Future<void> _persist() async {
    await _persistCredentials();
    await _persistOutbox();
  }

  Future<void> _persistCredentials() async {
    try {
      final db = await AppDb.instance.db();
      _ensureSchema(db);
      _writeMeta(db, 'lastfm_credentials', json.encode(_credentials.toMap()));
    } catch (error, trace) {
      logger.e('保存 Last.fm 凭据失败', error: error, stackTrace: trace);
    }
  }

  Future<void> _persistOutbox() async {
    try {
      final db = await AppDb.instance.db();
      _ensureSchema(db);
      _writeMeta(
        db,
        'lastfm_outbox',
        json.encode(_pending.map((item) => item.toMap()).toList()),
      );
    } catch (error, trace) {
      logger.e('保存 Last.fm 队列失败', error: error, stackTrace: trace);
    }
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final previous = _queue;
    late final Future<void> current;
    current = previous.catchError((_) {}).then((_) => action());
    _queue = current;
    return current;
  }

  static void _ensureSchema(Database db) {
    db.execute('''
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''');
  }

  static Map? _readMetaMap(Database db, String key) {
    final rows = db.select('SELECT value FROM meta WHERE key = ?', [key]);
    if (rows.isEmpty) return null;
    final raw = rows.first['value'];
    if (raw is! String || raw.isEmpty) return null;
    final decoded = json.decode(raw);
    return decoded is Map ? decoded : null;
  }

  static List<LastFmPendingScrobble> _readOutbox(Database db) {
    final rows = db.select('SELECT value FROM meta WHERE key = ?', ['lastfm_outbox']);
    if (rows.isEmpty) return const [];
    final raw = rows.first['value'];
    if (raw is! String || raw.isEmpty) return const [];
    final decoded = json.decode(raw);
    if (decoded is! List) return const [];
    final result = <LastFmPendingScrobble>[];
    final seen = <String>{};
    for (final item in decoded) {
      if (item is! Map) continue;
      final scrobble = LastFmPendingScrobble.fromMap(item);
      if (!scrobble.isValid || !seen.add(scrobble.id)) continue;
      result.add(scrobble);
    }
    result.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return result;
  }

  static void _writeMeta(Database db, String key, String value) {
    db.execute(
      'INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }
}
