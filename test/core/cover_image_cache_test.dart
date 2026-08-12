import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/cache.dart';

void main() {
  final cache = CoverImageCache.instance;

  setUp(() {
    cache.clear();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  testWidgets('recreated provider reuses a decoded cover after unmount', (
    tester,
  ) async {
    const path = r'C:\music\album\track.flac';
    final provider = cache.stableImageForTesting(
      path: path,
      width: 48,
      height: 48,
      bytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Image(image: provider, width: 48, height: 48),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    final restored = cache.getCached(path: path, width: 48, height: 48);

    expect(restored, isNotNull);
    expect(
      await restored!.obtainKey(ImageConfiguration.empty),
      await provider.obtainKey(ImageConfiguration.empty),
    );
  });

  test('stable key metadata does not grow with album count', () {
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    cache.stableImageForTesting(
      path: 'track-seed.flac',
      width: 48,
      height: 48,
      bytes: bytes,
    );
    final configurationCount = cache.stableImageConfigurationCountForTesting;
    for (var index = 0; index < 2000; index++) {
      cache.stableImageForTesting(
        path: 'track-$index.flac',
        width: 48,
        height: 48,
        bytes: bytes,
      );
    }

    expect(cache.stableImageConfigurationCountForTesting, configurationCount);
  });
}
