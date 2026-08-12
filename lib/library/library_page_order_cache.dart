import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _cacheMagic = <int>[0x50, 0x4d, 0x50, 0x4f, 0x52, 0x44, 0x30, 0x31];
const _cacheFormatVersion = 1;

class LibraryPageSourceSignature {
  const LibraryPageSourceSignature({
    required this.modifiedMicroseconds,
    required this.size,
  });

  final int modifiedMicroseconds;
  final int size;

  @override
  int get hashCode => Object.hash(modifiedMicroseconds, size);

  @override
  bool operator ==(Object other) =>
      other is LibraryPageSourceSignature &&
      modifiedMicroseconds == other.modifiedMicroseconds &&
      size == other.size;
}

class PageOrderSnapshot {
  const PageOrderSnapshot({
    required this.sortMethod,
    required this.sortOrderIndex,
    required this.indexes,
  });

  final int sortMethod;
  final int sortOrderIndex;
  final Uint32List indexes;
}

class LibraryPageOrders {
  const LibraryPageOrders({
    required this.sourceSignature,
    required this.context,
    required this.audios,
    required this.artists,
    required this.albums,
  });

  final LibraryPageSourceSignature sourceSignature;
  final String context;
  final PageOrderSnapshot audios;
  final PageOrderSnapshot artists;
  final PageOrderSnapshot albums;
}

class LibraryPageOrderCache {
  static Future<LibraryPageSourceSignature?> sourceSignature(
    String sourcePath,
  ) async {
    final stat = await File(sourcePath).stat();
    if (stat.type != FileSystemEntityType.file) return null;
    return LibraryPageSourceSignature(
      modifiedMicroseconds: stat.modified.microsecondsSinceEpoch,
      size: stat.size,
    );
  }

  static Future<LibraryPageOrders?> read({
    required String cachePath,
    required LibraryPageSourceSignature sourceSignature,
    required String context,
    required int audioCount,
    required int artistCount,
    required int albumCount,
  }) async {
    try {
      final bytes = await File(cachePath).readAsBytes();
      final reader = _CacheReader(bytes);
      for (final expected in _cacheMagic) {
        if (reader.readUint8() != expected) return null;
      }
      if (reader.readUint32() != _cacheFormatVersion) return null;
      final storedSignature = LibraryPageSourceSignature(
        modifiedMicroseconds: reader.readInt64(),
        size: reader.readInt64(),
      );
      if (storedSignature != sourceSignature) return null;
      final contextLength = reader.readUint32();
      final storedContext = utf8.decode(reader.readBytes(contextLength));
      if (storedContext != context) return null;

      final audios = reader.readPage(audioCount);
      final artists = reader.readPage(artistCount);
      final albums = reader.readPage(albumCount);
      if (!reader.isAtEnd) return null;
      return LibraryPageOrders(
        sourceSignature: storedSignature,
        context: storedContext,
        audios: audios,
        artists: artists,
        albums: albums,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> write({
    required String cachePath,
    required LibraryPageOrders orders,
  }) async {
    _validatePage(orders.audios);
    _validatePage(orders.artists);
    _validatePage(orders.albums);
    final contextBytes = utf8.encode(orders.context);
    final byteLength =
        _cacheMagic.length +
        4 +
        8 +
        8 +
        4 +
        contextBytes.length +
        _pageByteLength(orders.audios) +
        _pageByteLength(orders.artists) +
        _pageByteLength(orders.albums);
    final writer = _CacheWriter(Uint8List(byteLength));
    writer.writeBytes(_cacheMagic);
    writer.writeUint32(_cacheFormatVersion);
    writer.writeInt64(orders.sourceSignature.modifiedMicroseconds);
    writer.writeInt64(orders.sourceSignature.size);
    writer.writeUint32(contextBytes.length);
    writer.writeBytes(contextBytes);
    writer.writePage(orders.audios);
    writer.writePage(orders.artists);
    writer.writePage(orders.albums);

    final target = File(cachePath);
    await target.parent.create(recursive: true);
    final temporary = File(
      '$cachePath.tmp.${DateTime.now().microsecondsSinceEpoch}.$pid',
    );
    try {
      await temporary.writeAsBytes(writer.bytes, flush: true);
      await temporary.rename(cachePath);
    } catch (_) {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {}
      rethrow;
    }
  }

  static int _pageByteLength(PageOrderSnapshot page) =>
      12 + page.indexes.length * 4;

  static void _validatePage(PageOrderSnapshot page) {
    final seen = Uint8List(page.indexes.length);
    for (final index in page.indexes) {
      if (index >= seen.length || seen[index] != 0) {
        throw const FormatException('Invalid library page order');
      }
      seen[index] = 1;
    }
  }
}

class _CacheReader {
  _CacheReader(this.bytes) : _data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _data;
  int _offset = 0;

  bool get isAtEnd => _offset == bytes.length;

  int readUint8() {
    _ensureAvailable(1);
    return _data.getUint8(_offset++);
  }

  int readUint32() {
    _ensureAvailable(4);
    final value = _data.getUint32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  int readInt64() {
    _ensureAvailable(8);
    final value = _data.getInt64(_offset, Endian.little);
    _offset += 8;
    return value;
  }

  Uint8List readBytes(int length) {
    _ensureAvailable(length);
    final result = Uint8List.sublistView(bytes, _offset, _offset + length);
    _offset += length;
    return result;
  }

  PageOrderSnapshot readPage(int expectedLength) {
    final sortMethod = readUint32();
    final sortOrderIndex = readUint32();
    final length = readUint32();
    if (length != expectedLength) {
      throw const FormatException('Library page count changed');
    }
    final indexes = Uint32List(length);
    final seen = Uint8List(length);
    for (var position = 0; position < length; position++) {
      final index = readUint32();
      if (index >= length || seen[index] != 0) {
        throw const FormatException('Invalid library page order');
      }
      seen[index] = 1;
      indexes[position] = index;
    }
    return PageOrderSnapshot(
      sortMethod: sortMethod,
      sortOrderIndex: sortOrderIndex,
      indexes: indexes,
    );
  }

  void _ensureAvailable(int length) {
    if (length < 0 || _offset + length > bytes.length) {
      throw const FormatException('Truncated library page order cache');
    }
  }
}

class _CacheWriter {
  _CacheWriter(this.bytes) : _data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _data;
  int _offset = 0;

  void writeUint32(int value) {
    _data.setUint32(_offset, value, Endian.little);
    _offset += 4;
  }

  void writeInt64(int value) {
    _data.setInt64(_offset, value, Endian.little);
    _offset += 8;
  }

  void writeBytes(List<int> value) {
    bytes.setRange(_offset, _offset + value.length, value);
    _offset += value.length;
  }

  void writeUint32List(Uint32List value) {
    if (Endian.host == Endian.little) {
      writeBytes(
        Uint8List.view(value.buffer, value.offsetInBytes, value.lengthInBytes),
      );
      return;
    }
    for (final item in value) {
      writeUint32(item);
    }
  }

  void writePage(PageOrderSnapshot page) {
    writeUint32(page.sortMethod);
    writeUint32(page.sortOrderIndex);
    writeUint32(page.indexes.length);
    writeUint32List(page.indexes);
  }
}
