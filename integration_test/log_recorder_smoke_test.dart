import 'dart:io';

import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('log recorder creates a log file', (tester) async {
    final recorder = AudioEchoLogRecorder.instance;
    await recorder.start();
    await Future.delayed(const Duration(milliseconds: 300));
    final path = recorder.currentLogPath;
    await recorder.stop();

    expect(path, isNotNull);
    expect(File(path!).existsSync(), isTrue);
  });
}

