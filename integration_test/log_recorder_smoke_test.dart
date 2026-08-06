import 'dart:io';

import 'package:pure_music/core/utils.dart';
import 'package:pure_music/native/rust/frb_generated.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(RustLib.init);
  tearDownAll(() async {
    await PlayService.instance.close();
    RustLib.dispose();
  });

  testWidgets('log recorder persists useful and redacted diagnostics',
      (tester) async {
    final recorder = AudioEchoLogRecorder.instance;
    await recorder.start();
    final path = recorder.currentLogPath;
    recorder.mark(
      'diagnosticTest',
      extra: const {
        'path': r'C:\Users\Example\Music\private.flac',
        'url': 'https://example.test/lyrics?token=query-secret',
        'token': 'field-secret',
      },
    );
    recorder.snapshot(tag: 'test');
    logger.w(
      r'[bass] Plugin load failed: C:\Users\Example\bassflac.dll (error 14)',
    );
    await Future.delayed(const Duration(milliseconds: 1200));

    expect(path, isNotNull);
    final liveContent = await File(path!).readAsString();
    expect(liveContent, contains('RECORDER|startedAt='));
    expect(liveContent, contains('MARK|'));
    expect(liveContent, contains('name=diagnosticTest'));
    expect(liveContent, contains('SNAPSHOT|'));
    expect(liveContent, contains('tag=test'));

    await recorder.stop();
    final finalContent = await recorder.readLatestLog();

    expect(recorder.latestLogPath, path);
    expect(finalContent, contains('RECORDER|stoppedAt='));
    expect(finalContent, contains('[local path]'));
    expect(finalContent, contains('https://example.test/lyrics?[redacted]'));
    expect(finalContent, contains('token=[redacted]'));
    expect(finalContent, contains('[bass] Plugin load failed: [local path]'));
    expect(finalContent, contains('(error 14)'));
    expect(finalContent, isNot(contains('private.flac')));
    expect(finalContent, isNot(contains('query-secret')));
    expect(finalContent, isNot(contains('field-secret')));
  });
}
