import 'dart:convert';
import 'dart:math';

enum RemoteSourceKind {
  navidrome('Navidrome'),
  webdav('WebDAV'),
  smb('SMB / 共享文件夹'),
  jellyfin('Jellyfin');

  const RemoteSourceKind(this.label);

  final String label;

  static RemoteSourceKind parse(String value) {
    return RemoteSourceKind.values.firstWhere(
      (kind) => kind.name == value,
      orElse: () => RemoteSourceKind.navidrome,
    );
  }
}

class RemoteSource {
  const RemoteSource({
    required this.id,
    required this.kind,
    required this.name,
    required this.baseUrl,
    required this.username,
    required this.secret,
    required this.root,
    required this.createdAt,
    required this.lastSyncAt,
    required this.sortOrder,
  });

  final String id;
  final RemoteSourceKind kind;
  final String name;
  final String baseUrl;
  final String username;

  /// DPAPI 加密后的密码，空字符串表示没有密码。
  final String secret;
  final String root;
  final int createdAt;
  final int lastSyncAt;
  final int sortOrder;

  RemoteSource copyWith({
    String? name,
    String? baseUrl,
    String? username,
    String? secret,
    String? root,
    int? lastSyncAt,
    int? sortOrder,
  }) {
    return RemoteSource(
      id: id,
      kind: kind,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      secret: secret ?? this.secret,
      root: root ?? this.root,
      createdAt: createdAt,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}

class RemoteTrack {
  const RemoteTrack({
    required this.sourceId,
    required this.trackId,
    required this.title,
    required this.artist,
    required this.album,
    this.albumArtist,
    required this.track,
    this.disc,
    required this.duration,
    this.bitrate,
    this.sampleRate,
    required this.modified,
    required this.created,
    this.by,
    this.coverId,
  });

  final String sourceId;
  final String trackId;
  final String title;
  final String artist;
  final String album;
  final String? albumArtist;
  final int track;
  final int? disc;
  final int duration;
  final int? bitrate;
  final int? sampleRate;
  final int modified;
  final int created;
  final String? by;
  final String? coverId;

  /// 同步结束后会用 ID3 里的真实标签覆盖按文件名猜出来的值。
  RemoteTrack copyWith({
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    int? track,
    int? duration,
    int? bitrate,
    int? sampleRate,
    String? by,
    String? coverId,
  }) {
    return RemoteTrack(
      sourceId: sourceId,
      trackId: trackId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      albumArtist: albumArtist ?? this.albumArtist,
      track: track ?? this.track,
      disc: disc,
      duration: duration ?? this.duration,
      bitrate: bitrate ?? this.bitrate,
      sampleRate: sampleRate ?? this.sampleRate,
      modified: modified,
      created: created,
      by: by ?? this.by,
      coverId: coverId ?? this.coverId,
    );
  }
}

const remotePathPrefix = 'remote://';

String remotePathFor(String sourceId, String trackId) {
  final encoded = base64Url.encode(utf8.encode(trackId)).replaceAll('=', '');
  return '$remotePathPrefix$sourceId/$encoded';
}

String? remoteSourceIdOf(String path) {
  if (!path.startsWith(remotePathPrefix)) return null;
  final rest = path.substring(remotePathPrefix.length);
  final slash = rest.indexOf('/');
  if (slash <= 0) return null;
  return rest.substring(0, slash);
}

String? remoteTrackIdOf(String path) {
  if (!path.startsWith(remotePathPrefix)) return null;
  final rest = path.substring(remotePathPrefix.length);
  final slash = rest.indexOf('/');
  if (slash <= 0 || slash == rest.length - 1) return null;
  var encoded = rest.substring(slash + 1);
  encoded = encoded.padRight((encoded.length + 3) & ~3, '=');
  try {
    return utf8.decode(base64Url.decode(encoded));
  } catch (_) {
    return null;
  }
}

String newRemoteId() {
  final random = Random.secure();
  final suffix = List.generate(8, (_) => random.nextInt(16).toRadixString(16))
      .join();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}$suffix';
}

/// 名称为空时给一个人类可读的默认名，例如「家中的 Navidrome」。
///
/// 不再拿主机名或末级文件夹名当名字（`music.stillrain.xyz`、`Music` 这种），
/// 那些信息在「编辑」和「文件信息」里都看得到，名字只需要说明这是什么。
String defaultRemoteSourceName(RemoteSourceKind kind, String address) {
  // 名称留空时统一用协议名，不再拼主机/目录名——那些信息在「编辑」和
  // 「文件信息」里都看得到，名字只需要说明这是哪一类源。
  return switch (kind) {
    RemoteSourceKind.navidrome => 'Navidrome',
    RemoteSourceKind.webdav => 'WebDAV',
    RemoteSourceKind.smb => 'SMB/共享路径',
    RemoteSourceKind.jellyfin => 'Jellyfin',
  };
}

String uniqueRemoteSourceName(String base, Iterable<String> existingNames) {
  final name = base.trim().isEmpty ? '远程音乐' : base.trim();
  final taken = existingNames
      .map((value) => value.trim().toLowerCase())
      .toSet();
  if (!taken.contains(name.toLowerCase())) return name;
  for (var index = 2; index < 1000; index++) {
    final candidate = '$name ($index)';
    if (!taken.contains(candidate.toLowerCase())) return candidate;
  }
  return name;
}
