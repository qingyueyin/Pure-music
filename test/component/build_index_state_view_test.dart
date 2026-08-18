import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/build_index_state_view.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';

void main() {
  testWidgets('index errors do not invoke the success callback', (
    tester,
  ) async {
    final controller = StreamController<IndexActionState>();
    var successCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BuildIndexStateView(
            indexPath: Directory.systemTemp,
            folders: const [],
            buildIndex: ({required folders, required indexPath}) =>
                controller.stream,
            whenIndexBuilt: () => successCount++,
          ),
        ),
      ),
    );

    controller.addError(StateError('index failed'));
    await controller.close();
    await tester.pump();

    expect(successCount, 0);
    expect(find.text('曲库索引构建失败，请查看日志'), findsOneWidget);
  });

  testWidgets('load errors after indexing show an error state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BuildIndexStateView(
            indexPath: Directory.systemTemp,
            folders: const [],
            buildIndex: ({required folders, required indexPath}) =>
                const Stream<IndexActionState>.empty(),
            whenIndexBuilt: () => throw StateError('load failed'),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    expect(find.text('曲库加载失败，请查看日志'), findsOneWidget);
  });
}
