import 'dart:io';
import 'dart:typed_data';

import 'package:pure_music/app_preference.dart';
import 'package:pure_music/src/bass/bass_player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Uint8List _makeWavBytes({
  required int sampleRate,
  required int seconds,
}) {
  final numChannels = 1;
  final bitsPerSample = 16;
  final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
  final blockAlign = numChannels * bitsPerSample ~/ 8;
  final numSamples = sampleRate * seconds;
  final dataSize = numSamples * blockAlign;

  final bytes = BytesBuilder();
  void wStr(String s) => bytes.add(s.codeUnits);
  void w32(int v) {
    bytes.add([
      v & 0xff,
      (v >> 8) & 0xff,
      (v >> 16) & 0xff,
      (v >> 24) & 0xff,
    ]);
  }

  void w16(int v) {
    bytes.add([
      v & 0xff,
      (v >> 8) & 0xff,
    ]);
  }

  wStr('RIFF');
  w32(36 + dataSize);
  wStr('WAVE');

  wStr('fmt ');
  w32(16);
  w16(1);
  w16(numChannels);
  w32(sampleRate);
  w32(byteRate);
  w16(blockAlign);
  w16(bitsPerSample);

  wStr('data');
  w32(dataSize);
  bytes.add(Uint8List(dataSize));

  return bytes.takeBytes();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('EQ bypass removes EQ FX in shared mode', (tester) async {
    final pref = AppPreference.instance.playbackPref;

    final tmp = Directory.systemTemp.createTempSync('cp_eq_bypass_');
    final wavFile = File('${tmp.path}/silence.wav');
    await wavFile.writeAsBytes(
      _makeWavBytes(sampleRate: 44100, seconds: 1),
      flush: true,
    );

    final player = BassPlayer();
    player.setSource(wavFile.path);

    pref.eqBypass = false;
    player.setEQ(1, 6.0);
    expect(player.debugStateLine.contains('eq=0'), isFalse);

    pref.eqBypass = true;
    player.refreshEQ();
    expect(player.debugStateLine.contains('eq=0'), isTrue);

    pref.eqBypass = false;
    player.refreshEQ();
    expect(player.debugStateLine.contains('eq=0'), isFalse);

    await tmp.delete(recursive: true);
  });
}
