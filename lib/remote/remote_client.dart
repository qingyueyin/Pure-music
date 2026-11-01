import 'dart:typed_data';

import 'package:pure_music/remote/remote_source.dart';

typedef RemoteSyncProgress = void Function(double progress, String message);

/// 同步过程中该源被删除，用来让后台任务尽快退出。
class RemoteSyncCancelled implements Exception {
  const RemoteSyncCancelled();

  @override
  String toString() => '同步已取消';
}

abstract class RemoteClient {
  /// [existingTracks] 是上次同步的结果（按 trackId 索引），用于增量跳过
  /// 未变化的文件。按参数传递而不是存在客户端字段里：同一协议的多个源
  /// 并发同步时不会互相覆盖。
  ///
  /// [checkCancelled] 在抓取期间的每个检查点被调用，源被删除时应尽快
  /// 抛出 [RemoteSyncCancelled] 退出。
  Future<List<RemoteTrack>> fetchTracks(
    RemoteSource source,
    String password, {
    RemoteSyncProgress? onProgress,
    Map<String, RemoteTrack> existingTracks = const {},
    void Function()? checkCancelled,
  });

  String playbackUrl(RemoteSource source, String password, String trackId);

  Future<Uint8List?> cover(
    RemoteSource source,
    String password,
    String? coverId,
    int size,
  ) async {
    return null;
  }
}
