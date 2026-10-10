import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' as frb;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:pure_music/native/rust/api/library_db.dart' as library_db;
import 'package:pure_music/native/rust/frb_generated.dart';
import 'package:pure_music/services/backup_service.dart';

void main() {
  setUpAll(() async {
    final library = await _buildRustLibrary();
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.path));
  });
  tearDownAll(RustLib.dispose);

  test(
    'play history round-trips through backup zip',
    () async {
      final source = await Directory.systemTemp.createTemp(
        'pure_music_history_src_',
      );
      final target = await Directory.systemTemp.createTemp(
        'pure_music_history_dst_',
      );
      try {
        await library_db.importPlayHistory(
          indexPath: source.path,
          entries: [
            library_db.PlayHistoryEntry(
              path: 'C:/music/example.mp3',
              playedAt: frb.Int64List.fromList([1700000000, 1700000600]),
            ),
          ],
          overwrite: true,
        );

        final zipPath = path.join(source.path, 'backup.zip');
        await exportBackup(
          targetPath: zipPath,
          categories: {BackupCategory.playHistory},
          dataRoot: source,
        );
        final imported = await importBackup(
          sourcePath: zipPath,
          mode: BackupImportMode.overwrite,
          dataRoot: target,
        );
        expect(imported, contains(BackupCategory.playHistory));

        final entries = await library_db.exportPlayHistory(
          indexPath: target.path,
        );
        expect(entries, hasLength(1));
        expect(entries.single.path, 'C:/music/example.mp3');
        expect(entries.single.playedAt.map((t) => t.toInt()).toList(), [
          1700000000,
          1700000600,
        ]);
      } finally {
        await source.delete(recursive: true);
        await target.delete(recursive: true);
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
