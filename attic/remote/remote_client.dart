import 'dart:typed_data';

import 'package:pure_music/remote/remote_source.dart';

typedef RemoteSyncProgress = void Function(double progress, String message);

abstract class RemoteClient {
  Future<List<RemoteTrack>> fetchTracks(
    RemoteSource source,
    String password, {
    RemoteSyncProgress? onProgress,
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
