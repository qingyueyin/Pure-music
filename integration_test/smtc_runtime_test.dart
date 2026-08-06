import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pure_music/native/rust/api/logger.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/native/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(RustLib.init);
  tearDownAll(RustLib.dispose);

  testWidgets('Windows runtime: SMTC state and timeline remain consistent', (
    tester,
  ) async {
    final tempDir = await Directory.systemTemp.createTemp(
      'pure_music_smtc_test_',
    );
    final audioFile = File('${tempDir.path}\\silent.wav');
    await audioFile.writeAsBytes(_silentWavBytes(), flush: true);
    final rustLogs = <String>[];
    final rustLogSubscription = initRustLogger().listen(rustLogs.add);
    final smtc = SmtcFlutter();

    try {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await smtc.updateDisplay(
        title: 'Runtime title',
        artist: 'Runtime artist',
        album: 'Runtime album',
        duration: 180000,
        path: audioFile.path,
      );
      await smtc.updateState(state: SMTCState.playing);
      await smtc.updateTimeProperties(progress: 42000);
      for (var attempt = 0; attempt < 20; attempt++) {
        if (rustLogs.any(
          (line) => line.contains('SMTC: no embedded picture'),
        )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      expect(
        rustLogs.any((line) => line.contains('SMTC: no embedded picture')),
        isTrue,
        reason: rustLogs.join('\n'),
      );
      expect(
        rustLogs.any((line) => line.contains('thumbnail worker init failed')),
        isFalse,
      );

      var snapshot = await smtc.debugSnapshot();
      expect(snapshot.enabled, isTrue);
      expect(snapshot.playEnabled, isTrue);
      expect(snapshot.pauseEnabled, isTrue);
      expect(snapshot.previousEnabled, isTrue);
      expect(snapshot.nextEnabled, isTrue);
      expect(snapshot.stopEnabled, isTrue);
      expect(snapshot.playbackStatus, 'playing');
      expect(snapshot.title, 'Runtime title');
      expect(snapshot.artist, 'Runtime artist');
      expect(snapshot.album, 'Runtime album');
      expect(snapshot.durationMs, 180000);
      expect(snapshot.progressMs, BigInt.from(42000));

      await smtc.updateTimeProperties(progress: 200000);
      snapshot = await smtc.debugSnapshot();
      expect(snapshot.progressMs, BigInt.from(180000));

      await smtc.updateState(state: SMTCState.paused);
      snapshot = await smtc.debugSnapshot();
      expect(snapshot.playbackStatus, 'paused');

      await smtc.clearDisplay();
      snapshot = await smtc.debugSnapshot();
      expect(snapshot.enabled, isFalse);
      expect(snapshot.playbackStatus, 'stopped');
      expect(snapshot.title, isEmpty);
      expect(snapshot.artist, isEmpty);
      expect(snapshot.album, isEmpty);
      expect(snapshot.durationMs, 0);
      expect(snapshot.progressMs, BigInt.zero);
    } finally {
      await smtc.close().timeout(const Duration(seconds: 2));
      unawaited(rustLogSubscription.cancel());
      await tempDir.delete(recursive: true).timeout(const Duration(seconds: 2));
    }
  }, timeout: const Timeout(Duration(seconds: 20)));
}

Uint8List _silentWavBytes() {
  const sampleRate = 8000;
  const dataLength = sampleRate * 2;
  final bytes = ByteData(44 + dataLength);
  void writeAscii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  writeAscii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataLength, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  bytes.setUint32(40, dataLength, Endian.little);
  return bytes.buffer.asUint8List();
}
