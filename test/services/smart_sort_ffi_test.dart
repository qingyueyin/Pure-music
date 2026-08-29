import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:pure_music/native/rust/api/smart_sort.dart';
import 'package:pure_music/native/rust/api/smart_transition.dart';
import 'package:pure_music/native/rust/frb_generated.dart';

void main() {
  setUpAll(() async {
    final library = await _buildRustLibrary();
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.path));
  });
  tearDownAll(RustLib.dispose);

  test(
    'PCM WAV analysis reaches smart sort through Dart FFI',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pure_music_smart_sort_ffi_',
      );
      try {
        final first = File(path.join(directory.path, 'first.wav'));
        final second = File(path.join(directory.path, 'second.wav'));
        await first.writeAsBytes(_wavBytes(frequency: 220, gain: 0.12));
        await second.writeAsBytes(_wavBytes(frequency: 440, gain: 0.32));

        final profiles = <Map<String, dynamic>>[];
        for (final (index, file) in [first, second].indexed) {
          final profileJson = await analyzeSmartTransitionTrack(
            jobId: BigInt.from(20_000 + index),
            path: file.path,
            mediaId: 'ffi-fixture-$index',
            libraryRoot: directory.path,
          );
          profiles.add(jsonDecode(profileJson) as Map<String, dynamic>);
        }

        final outputJson = await planSmartSortJson(
          payloadJson: jsonEncode({
            'features': profiles.map(_sortFeature).toList(),
            'playCounts': [2, 8],
          }),
          climaxPosition: 0.82,
          contrast: 0.85,
          takeCount: BigInt.zero,
          smoothness: 0.5,
          outroStyle: 0,
          taste: 0,
        );
        final output = jsonDecode(outputJson) as Map<String, dynamic>;
        final order = (output['order'] as List).cast<int>()..sort();

        expect(order, [0, 1]);
        expect(output['idealCurve'], hasLength(2));
        expect(output['actualCurve'], hasLength(2));
        expect(
          profiles.every(
            (profile) =>
                (profile['duration_ms'] as num).toInt() == 6000 &&
                (profile['integrated_rms_dbfs'] as num).isFinite,
          ),
          isTrue,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

Future<File> _buildRustLibrary() async {
  if (!Platform.isWindows) {
    throw UnsupportedError('The Rust FFI runtime test requires Windows.');
  }
  final root = Directory.current.path;
  final rustDirectory = path.join(root, 'rust');
  final library = File(
    path.join(rustDirectory, 'target', 'debug', 'rust_lib_pure_music.dll'),
  );
  final build = await Process.run('cargo', [
    'build',
  ], workingDirectory: rustDirectory);
  if (build.exitCode != 0 || !await library.exists()) {
    throw StateError('Rust debug library build failed: ${build.stderr}');
  }
  return library;
}

Map<String, dynamic> _sortFeature(Map<String, dynamic> profile) {
  final tempo = profile['tempo'];
  final entrance = profile['entrance'] as Map<String, dynamic>;
  final exit = profile['exit'] as Map<String, dynamic>;
  return {
    'integratedRmsDbfs': profile['integrated_rms_dbfs'],
    'bpm': tempo is Map<String, dynamic> ? tempo['bpm'] : 0.0,
    'entranceOnsetDensity': entrance['onset_density'],
    'entranceEnergyDbfs': entrance['average_energy_dbfs'],
    'exitOnsetDensity': exit['onset_density'],
    'exitEnergyDbfs': exit['average_energy_dbfs'],
  };
}

Uint8List _wavBytes({required double frequency, required double gain}) {
  const sampleRate = 16000;
  const durationSeconds = 6;
  const sampleCount = sampleRate * durationSeconds;
  const dataLength = sampleCount * 2;
  final bytes = ByteData(44 + dataLength);
  void writeAscii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  writeAscii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataLength, Endian.little);
  writeAscii(8, 'WAVEfmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  bytes.setUint32(40, dataLength, Endian.little);
  const beatSamples = sampleRate ~/ 2;
  const clickSamples = sampleRate ~/ 100;
  for (var index = 0; index < sampleCount; index++) {
    final time = index / sampleRate;
    final tone = gain * math.sin(2 * math.pi * frequency * time);
    final beatOffset = index % beatSamples;
    final click = beatOffset < clickSamples
        ? 0.55 * (1 - beatOffset / clickSamples)
        : 0.0;
    final sample = ((tone + click).clamp(-1.0, 1.0) * 32767).round();
    bytes.setInt16(44 + index * 2, sample, Endian.little);
  }
  return bytes.buffer.asUint8List();
}
