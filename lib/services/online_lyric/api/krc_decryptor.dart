import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:isolate';

final List<int> _krcKey = [
  64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105,
];

Future<String?> krcDecryptSingle(String content) async {
  return Isolate.run(() => _krcDecryptSync(content))
      .timeout(const Duration(seconds: 5), onTimeout: () => null);
}

String? _krcDecryptSync(String content) {
  final List<int> bytes = base64Decode(content);

  if (bytes.length <= 4) {
    return null;
  }
  final List<int> contentBytes = bytes.sublist(4);

  try {
    final Uint8List krcCompress = Uint8List(contentBytes.length);
    for (int k = 0; k < contentBytes.length; k++) {
      krcCompress[k] = contentBytes[k] ^ _krcKey[k % 16];
    }

    return utf8.decode(ZLibDecoder().convert(krcCompress));
  } catch (_) {
    return null;
  }
}

String? krcDecrypt(String content) => _krcDecryptSync(content);
