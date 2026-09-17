import 'dart:io';

import 'package:flutter/services.dart';

const kHangulFallbackFontFamily = 'Pretendard Variable';

final _loadedFontFamilies = <String>{};

List<String> appFontFamilyFallback([String? primary]) {
  if (primary == kHangulFallbackFontFamily) return const [];
  return const [kHangulFallbackFontFamily];
}

String? resolvedLyricFontFamily({
  required bool followsUi,
  String? lyricFontFamily,
  String? uiFontFamily,
}) => followsUi ? uiFontFamily : lyricFontFamily;

bool isAppFontLoaded(String family) => _loadedFontFamilies.contains(family);

Future<void> loadAppFontFile({
  required String family,
  required String path,
}) async {
  if (!_loadedFontFamilies.add(family)) return;
  try {
    final fontLoader = FontLoader(family);
    fontLoader.addFont(
      File(path).readAsBytes().then((value) {
        return ByteData.sublistView(value);
      }),
    );
    await fontLoader.load();
  } catch (_) {
    _loadedFontFamilies.remove(family);
    rethrow;
  }
}
