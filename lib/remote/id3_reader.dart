import 'dart:convert';
import 'dart:typed_data';

/// 从文件头部字节解析出的音频标签。
///
/// WebDAV 协议本身不提供标签，但文件字节是完整可用的，所以用 HTTP Range
/// 只取头部若干字节，在本地解 ID3v2 / 帧头即可拿到标题、艺术家、专辑和时长，
/// 不必把整首歌下载下来。
class RemoteAudioTags {
  const RemoteAudioTags({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.duration = 0,
    this.bitrate,
    this.sampleRate,
    this.audioStart = 0,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;

  /// 秒。拿不到就是 0。
  final int duration;
  final int? bitrate;
  final int? sampleRate;

  /// 音频数据在文件里的偏移（ID3v2 之后）。
  /// 标签带大封面时会超过探测窗口，调用方可以据此再取一小段算时长。
  final int audioStart;

  bool get hasText =>
      (title?.isNotEmpty ?? false) || (artist?.isNotEmpty ?? false);
}

/// 只需要文件开头一小段：ID3v2 标签 + 第一帧（Xing/Info 头里有总帧数）。
const remoteTagProbeBytes = 128 * 1024;

/// 解析 MP3 的 ID3v2 标签，并尽量算出时长。
///
/// [fileSize] 可选：没有 Xing 头时用「文件大小 ÷ 码率」估算 CBR 时长。
RemoteAudioTags? parseMp3Tags(Uint8List bytes, {int? fileSize}) {
  if (bytes.length < 10) return null;
  String? title;
  String? artist;
  String? album;
  String? albumArtist;
  var duration = 0;
  var audioStart = 0;

  audioStart = _id3EndOffset(bytes);
  for (final frame in _id3Frames(bytes)) {
    // v2.2 的帧 ID 是 3 字符（TT2/TP1/…），v2.3/2.4 是 4 字符（TIT2/…），
    // 两种都要认——下面的 switch 里本来就备好了两套 case。
    if (frame.id.isEmpty || frame.id[0] != 'T') continue;
    final text = _decodeText(frame.data);
    if (text.isEmpty) continue;
    switch (frame.id) {
      case 'TIT2':
      case 'TT2':
        title ??= text;
      case 'TPE1':
      case 'TP1':
        artist ??= text;
      case 'TALB':
      case 'TAL':
        album ??= text;
      case 'TPE2':
      case 'TP2':
        albumArtist ??= text;
      case 'TLEN':
      case 'TLE':
        final ms = int.tryParse(text);
        if (ms != null && ms > 0) duration = (ms / 1000).round();
    }
  }

  final frame = _parseMp3Frame(bytes, audioStart, fileSize: fileSize);
  if (frame != null) {
    return RemoteAudioTags(
      title: title,
      artist: artist,
      album: album,
      albumArtist: albumArtist,
      duration: duration > 0 ? duration : frame.duration,
      bitrate: frame.bitrate,
      sampleRate: frame.sampleRate,
      audioStart: audioStart,
    );
  }
  if (title == null && artist == null && album == null) return null;
  return RemoteAudioTags(
    title: title,
    artist: artist,
    album: album,
    albumArtist: albumArtist,
    duration: duration,
    audioStart: audioStart,
  );
}

/// 标签里带大封面时，音频帧不在第一次探测的窗口内。
/// 用这个函数解析从 [audioStart] 处再取的一小段，只为了拿时长和码率。
RemoteAudioTags? parseMp3AudioInfo(Uint8List bytes, {int? fileSize}) {
  final frame = _parseMp3Frame(bytes, 0, fileSize: fileSize);
  if (frame == null) return null;
  return RemoteAudioTags(
    duration: frame.duration,
    bitrate: frame.bitrate,
    sampleRate: frame.sampleRate,
  );
}

/// ID3v2 标签之后的音频起始偏移。标签可能超出探测窗口，
/// 这个值按 ID3 头里的长度算，不能用截断后的缓冲长度。
int _id3EndOffset(Uint8List bytes) {
  if (bytes.length < 10) return 0;
  if (bytes[0] != 0x49 || bytes[1] != 0x44 || bytes[2] != 0x33) return 0;
  final flags = bytes[5];
  return 10 + _syncSafe(bytes, 6) + ((flags & 0x10) != 0 ? 10 : 0);
}

/// 逐帧遍历 ID3v2。缓冲被截断时会在最后一帧处停下。
/// v2.2 是 3 字符帧 ID + 6 字节帧头；v2.3/2.4 是 4 字符帧 ID + 10 字节帧头。
Iterable<({String id, Uint8List data})> _id3Frames(Uint8List bytes) sync* {
  if (bytes.length < 10) return;
  if (bytes[0] != 0x49 || bytes[1] != 0x44 || bytes[2] != 0x33) return;
  final major = bytes[3];
  final flags = bytes[5];
  // v2.2 的 0x40 表示整帧压缩，解不了，直接放弃。
  if (major <= 2 && (flags & 0x40) != 0) return;
  final trueEnd = _id3EndOffset(bytes);
  var offset = 10;
  // v2.3 的扩展头是 4 字节长度 + 长度本身；v2.4 是 syncsafe 长度且已含自身。
  // v2.2 没有扩展头。
  if (major > 2 && (flags & 0x40) != 0 && offset + 4 <= bytes.length) {
    offset += major >= 4 ? _syncSafe(bytes, offset) : 4 + _u32(bytes, offset);
  }
  final end = trueEnd < bytes.length ? trueEnd : bytes.length;
  if (major <= 2) {
    while (offset + 6 <= end) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 3));
      if (id.isEmpty || id.codeUnitAt(0) == 0) return;
      final size =
          (bytes[offset + 3] << 16) | (bytes[offset + 4] << 8) | bytes[offset + 5];
      if (size <= 0 || offset + 6 + size > end) return;
      yield (
        id: id,
        data: Uint8List.sublistView(bytes, offset + 6, offset + 6 + size),
      );
      offset += 6 + size;
    }
    return;
  }
  while (offset + 10 <= end) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    if (id.isEmpty || id.codeUnitAt(0) == 0) return;
    final size = major >= 4
        ? _syncSafe(bytes, offset + 4)
        : _u32(bytes, offset + 4);
    if (size <= 0 || offset + 10 + size > end) return;
    yield (
      id: id,
      data: Uint8List.sublistView(bytes, offset + 10, offset + 10 + size),
    );
    offset += 10 + size;
  }
}

class RemotePicture {
  const RemotePicture(this.mimeType, this.bytes);

  final String mimeType;
  final Uint8List bytes;
}

/// 取内嵌封面（APIC，ID3v2.2 里叫 PIC）。
RemotePicture? extractApic(Uint8List bytes) {
  for (final frame in _id3Frames(bytes)) {
    final data = frame.data;
    final String mime;
    var offset = 1;
    if (frame.id == 'APIC') {
      if (data.length < 4) continue;
      final mimeEnd = data.indexOf(0, 1);
      if (mimeEnd < 0) continue;
      mime = latin1.decode(data.sublist(1, mimeEnd), allowInvalid: true);
      offset = mimeEnd + 1;
    } else if (frame.id == 'PIC') {
      if (data.length < 5) continue;
      mime = _picFormatToMime(String.fromCharCodes(data.sublist(1, 4)));
      offset = 4;
    } else {
      continue;
    }
    if (offset >= data.length) continue;
    offset += 1; // 图片类型
    final descEnd = _terminatedEnd(data, offset, data[0]);
    if (descEnd < 0 || descEnd >= data.length) continue;
    final picture = Uint8List.sublistView(data, descEnd);
    if (picture.isEmpty) continue;
    return RemotePicture(
      mime.isEmpty ? 'image/jpeg' : mime,
      Uint8List.fromList(picture),
    );
  }
  return null;
}

/// 取内嵌的非同步歌词（USLT，ID3v2.2 里叫 ULT）。
String? extractUslt(Uint8List bytes) {
  for (final frame in _id3Frames(bytes)) {
    if (frame.id != 'USLT' && frame.id != 'ULT') continue;
    final data = frame.data;
    if (data.length < 5) continue;
    final encoding = data[0];
    final descEnd = _terminatedEnd(data, 4, encoding);
    if (descEnd < 0 || descEnd >= data.length) continue;
    final text = _decodeBody(data, descEnd, encoding).trim();
    if (text.isNotEmpty) return text;
  }
  return null;
}

String _picFormatToMime(String format) {
  switch (format.toUpperCase()) {
    case 'PNG':
      return 'image/png';
    case 'GIF':
      return 'image/gif';
    case 'BMP':
      return 'image/bmp';
    default:
      return 'image/jpeg';
  }
}

/// 找到以 0 结尾的描述文本之后的位置。UTF-16 编码的终止符是两个 0 字节，
/// 且必须落在偶数边界上，否则会把文字里的高位 0 当成结束。
int _terminatedEnd(Uint8List data, int start, int encoding) {
  if (encoding == 1 || encoding == 2) {
    for (var i = start; i + 1 < data.length; i += 2) {
      if (data[i] == 0 && data[i + 1] == 0) return i + 2;
    }
    return -1;
  }
  final index = data.indexOf(0, start);
  return index < 0 ? -1 : index + 1;
}

/// 按给定编码解析从 [start] 起的文本（不含编码字节本身）。
String _decodeBody(Uint8List data, int start, int encoding) {
  if (start >= data.length) return '';
  final body = Uint8List.sublistView(data, start);
  final String text;
  switch (encoding) {
    case 0:
      text = latin1.decode(body, allowInvalid: true);
    case 1:
      text = _decodeUtf16(body, defaultBigEndian: false);
    case 2:
      text = _decodeUtf16(body, defaultBigEndian: true);
    default:
      text = utf8.decode(body, allowMalformed: true);
  }
  // ID3v2.4 允许一个文本帧里存多个值，用 \u0000 分隔；
  // 直接删掉分隔符会把「李晓杰」「DJ小鱼儿」粘成一个词。
  return text
      .split('\u0000')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .join(', ');
}

class _Mp3Frame {
  const _Mp3Frame(this.duration, this.bitrate, this.sampleRate);
  final int duration;
  final int? bitrate;
  final int? sampleRate;
}

const _bitrateV1L3 = <int>[
  0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
];
const _bitrateV2L3 = <int>[
  0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
];
const _sampleRatesV1 = <int>[44100, 48000, 32000, 0];
const _sampleRatesV2 = <int>[22050, 24000, 16000, 0];

/// 找到第一个帧同步并读 Xing/Info 头。返回 null 表示头部不像 MP3 帧。
_Mp3Frame? _parseMp3Frame(Uint8List bytes, int start, {int? fileSize}) {
  var offset = start;
  // 跳过 ID3v2 之后的填充 0。
  while (offset + 4 < bytes.length && bytes[offset] != 0xFF) {
    offset++;
  }
  if (offset + 4 >= bytes.length) return null;
  if (bytes[offset] != 0xFF || (bytes[offset + 1] & 0xE0) != 0xE0) return null;

  final b1 = bytes[offset + 1];
  final b2 = bytes[offset + 2];
  final versionBits = (b1 >> 3) & 0x03; // 0=2.5 1=保留 2=2 3=1
  final layerBits = (b1 >> 1) & 0x03; // 1=Layer III
  if (layerBits != 1 || versionBits == 1) return null;

  final isV1 = versionBits == 3;
  final bitrateIndex = (b2 >> 4) & 0x0F;
  final sampleRateIndex = (b2 >> 2) & 0x03;
  final channelMode = (bytes[offset + 3] >> 6) & 0x03;
  final monaural = channelMode == 3;

  final bitrate =
      (isV1 ? _bitrateV1L3 : _bitrateV2L3)[bitrateIndex];
  final sampleRate =
      (isV1 ? _sampleRatesV1 : _sampleRatesV2)[sampleRateIndex];
  if (bitrate == 0 || sampleRate == 0) return null;

  final samplesPerFrame = isV1 ? 1152 : 576;
  final sideInfo = isV1 ? (monaural ? 17 : 32) : (monaural ? 9 : 17);
  final xingOffset = offset + 4 + sideInfo;
  if (xingOffset + 12 <= bytes.length) {
    final marker = String.fromCharCodes(
      bytes.sublist(xingOffset, xingOffset + 4),
    );
    if (marker == 'Xing' || marker == 'Info') {
      final flags = _u32(bytes, xingOffset + 4);
      if ((flags & 0x1) != 0) {
        final frames = _u32(bytes, xingOffset + 8);
        if (frames > 0) {
          return _Mp3Frame(
            (frames * samplesPerFrame / sampleRate).round(),
            bitrate,
            sampleRate,
          );
        }
      }
    }
  }
  if (fileSize != null && fileSize > offset) {
    final seconds = ((fileSize - offset) * 8 / (bitrate * 1000)).round();
    return _Mp3Frame(seconds, bitrate, sampleRate);
  }
  return _Mp3Frame(0, bitrate, sampleRate);
}

int _syncSafe(Uint8List bytes, int offset) {
  if (offset + 4 > bytes.length) return 0;
  return ((bytes[offset] & 0x7F) << 21) |
      ((bytes[offset + 1] & 0x7F) << 14) |
      ((bytes[offset + 2] & 0x7F) << 7) |
      (bytes[offset + 3] & 0x7F);
}

int _u32(Uint8List bytes, int offset) {
  if (offset + 4 > bytes.length) return 0;
  return (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}

/// 第一个字节是编码方式：0=Latin-1 1=UTF-16(带 BOM) 2=UTF-16BE 3=UTF-8。
String _decodeText(Uint8List data) {
  if (data.length < 2) return '';
  return _decodeBody(data, 1, data[0]);
}

String _decodeUtf16(Uint8List body, {required bool defaultBigEndian}) {
  var start = 0;
  var bigEndian = defaultBigEndian;
  if (body.length >= 2) {
    if (body[0] == 0xFF && body[1] == 0xFE) {
      bigEndian = false;
      start = 2;
    } else if (body[0] == 0xFE && body[1] == 0xFF) {
      bigEndian = true;
      start = 2;
    }
  }
  final units = <int>[];
  for (var i = start; i + 1 < body.length; i += 2) {
    units.add(
      bigEndian ? (body[i] << 8) | body[i + 1] : (body[i + 1] << 8) | body[i],
    );
  }
  return String.fromCharCodes(units);
}
