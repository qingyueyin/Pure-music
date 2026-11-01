import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pure_music/core/cover_palette.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart' as rust_tag_reader;
import 'package:pure_music/remote/remote_library.dart';
import 'package:pure_music/remote/remote_source.dart';

class AudioExtraItem {
  const AudioExtraItem({required this.key, required this.value});

  factory AudioExtraItem.fromNative(rust_tag_reader.AudioExtraItem value) =>
      AudioExtraItem(key: value.key, value: value.value);

  final String key;
  final String value;
}

class AudioExtraMetadata {
  const AudioExtraMetadata({
    required this.extension,
    required this.fileSize,
    required this.channels,
    required this.bitDepth,
    required this.items,
    required this.replaygainTrackGain,
    required this.replaygainTrackPeak,
    required this.replaygainAlbumGain,
    required this.replaygainAlbumPeak,
  });

  factory AudioExtraMetadata.fromNative(
    rust_tag_reader.AudioExtraMetadata value,
  ) => AudioExtraMetadata(
    extension: value.extension_,
    fileSize: value.fileSize.toInt(),
    channels: value.channels,
    bitDepth: value.bitDepth,
    items: List<AudioExtraItem>.unmodifiable(
      value.items.map(AudioExtraItem.fromNative),
    ),
    replaygainTrackGain: value.replaygainTrackGain,
    replaygainTrackPeak: value.replaygainTrackPeak,
    replaygainAlbumGain: value.replaygainAlbumGain,
    replaygainAlbumPeak: value.replaygainAlbumPeak,
  );

  final String extension;
  final int fileSize;
  final int? channels;
  final int? bitDepth;
  final List<AudioExtraItem> items;
  final String? replaygainTrackGain;
  final String? replaygainTrackPeak;
  final String? replaygainAlbumGain;
  final String? replaygainAlbumPeak;
}

class AudioTagPayload {
  const AudioTagPayload({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.genre,
    this.year,
    this.track,
    this.trackTotal,
    this.disc,
    this.discTotal,
    this.composer,
    this.lyricist,
    this.label,
    this.comment,
    this.bpm,
    this.language,
    this.copyright,
    this.license,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? genre;
  final String? year;
  final String? track;
  final String? trackTotal;
  final String? disc;
  final String? discTotal;
  final String? composer;
  final String? lyricist;
  final String? label;
  final String? comment;
  final String? bpm;
  final String? language;
  final String? copyright;
  final String? license;

  rust_tag_reader.WriteTagPayload toNative() => rust_tag_reader.WriteTagPayload(
    title: title,
    artist: artist,
    album: album,
    albumArtist: albumArtist,
    genre: genre,
    year: year,
    track: track,
    trackTotal: trackTotal,
    disc: disc,
    discTotal: discTotal,
    composer: composer,
    lyricist: lyricist,
    label: label,
    comment: comment,
    bpm: bpm,
    language: language,
    copyright: copyright,
    license: license,
  );
}

class MediaMetadataService {
  MediaMetadataService._();

  static final MediaMetadataService instance = MediaMetadataService._();

  Future<AudioExtraMetadata> readExtraMetadata(String path) async {
    final value = await rust_tag_reader.readAudioExtraMetadata(path: path);
    return AudioExtraMetadata.fromNative(value);
  }

  Future<({Uint8List? bytes, List<int> colors})> getPictureAndColors({
    required String path,
    required int width,
    required int height,
    required int numColors,
  }) async {
    // remote:// 不是真实文件路径，送进 Rust 会报「路径过长」并刷屏。
    // 远程曲目改为：先拿到封面字节，再在 Dart 侧量化主色，
    // 否则播放页的背景渐变会整块消失（取不到色就没有渐变）。
    if (remoteSourceIdOf(path) != null) {
      final target = math.max(math.max(width, height), 160);
      final bytes = await RemoteLibrary.instance.coverBytes(path, target);
      if (bytes == null) return (bytes: null, colors: const <int>[]);
      final colors = await extractCoverPalette(bytes, numColors: numColors);
      return (bytes: bytes, colors: colors);
    }
    final value = await rust_tag_reader.getPictureAndColors(
      path: path,
      width: width,
      height: height,
      numColors: numColors,
    );
    return (bytes: value.$1, colors: List<int>.from(value.$2));
  }

  Future<String?> readEmbeddedLyric(String path) {
    if (remoteSourceIdOf(path) != null) return Future<String?>.value();
    return rust_tag_reader.getLyricFromPath(path: path);
  }

  Future<void> writeEmbeddedLyric({
    required String path,
    required String lyric,
  }) => rust_tag_reader.writeLyricToPath(path: path, lyric: lyric);

  Future<void> writeTags({
    required String path,
    required AudioTagPayload payload,
    required bool onlyChanged,
  }) => rust_tag_reader.writeAudioTags(
    path: path,
    payload: payload.toNative(),
    onlyChanged: onlyChanged,
  );

  Future<void> writeCover({required String path, required List<int> bytes}) =>
      rust_tag_reader.writeAudioCover(path: path, bytes: bytes);
}
