import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:pure_music/core/application_log.dart';

void main() {
  test('warning flushes stay ordered with concurrent log output', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pure_music_log_test_',
    );
    final output = ApplicationLogOutput(directoryPaths: [directory.path]);
    try {
      await output.init();
      for (var index = 0; index < 100; index++) {
        output.output(
          OutputEvent(
            LogEvent(index.isEven ? Level.info : Level.warning, 'entry'),
            ['entry=$index'],
          ),
        );
      }

      await output.flush();
      final content = await File(output.currentLogPath!).readAsString();
      for (var index = 0; index < 100; index++) {
        expect(content, contains('entry=$index'));
      }
    } finally {
      await output.destroy();
      await directory.delete(recursive: true);
    }
  });
}
