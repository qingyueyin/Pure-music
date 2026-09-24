import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_lifecycle.dart';

enum UpdateInstallOutcome { installerStarted, portableStarted }

class UpdateInstallException implements Exception {
  UpdateInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef UpdateProgressCallback = void Function(int received, int total);

typedef UpdatePhaseCallback = void Function(String phase);

class UpdateInstaller {
  UpdateInstaller._();

  static const _portableSupportDirectory = '.update';

  static Future<UpdateInstallOutcome> run({
    required UpdateInfo info,
    required UpdateChannel channel,
    required CancelToken cancelToken,
    required UpdateProgressCallback onProgress,
    required UpdatePhaseCallback onPhase,
  }) async {
    final url = info.downloadUrl(
      channel: channel,
      portableBuild: portableBuild,
    );
    if (url == null || url.isEmpty) {
      throw UpdateInstallException('缺少下载地址');
    }

    final fileName = _fileNameFromUrl(url);
    final savePath = await _prepareSavePath(fileName);

    onPhase('正在下载');
    try {
      await Dio().download(
        url,
        savePath,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
        options: Options(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(minutes: 5),
          followRedirects: true,
        ),
      );
    } on DioException {
      await _deleteQuietly(savePath);
      rethrow;
    } catch (error) {
      await _deleteQuietly(savePath);
      if (error is UpdateInstallException) rethrow;
      throw UpdateInstallException('下载失败');
    }

    final downloaded = File(savePath);
    if (!await downloaded.exists() || await downloaded.length() == 0) {
      await _deleteQuietly(savePath);
      throw UpdateInstallException('下载文件为空');
    }

    onPhase('正在校验');
    final expected = await _resolveExpectedSha256(
      info: info,
      channel: channel,
      portableBuild: portableBuild,
      cancelToken: cancelToken,
    );
    if (expected == null) {
      logger.w(
        '[UpdateInstaller] release has no sha256 metadata; skip verification',
      );
    } else {
      try {
        final ok = await _verifySha256(savePath, expected);
        if (!ok) {
          throw UpdateInstallException('校验失败，文件已删除');
        }
      } catch (_) {
        await _deleteQuietly(savePath);
        rethrow;
      }
    }

    if (portableBuild) {
      return _startPortableUpdate(archivePath: savePath, onPhase: onPhase);
    }

    onPhase('正在启动安装程序');
    final process = await Process.start(
      savePath,
      const [],
      workingDirectory: p.dirname(savePath),
      mode: ProcessStartMode.detached,
    );
    if (process.pid <= 0) {
      throw UpdateInstallException('启动安装程序失败');
    }
    await WindowLifecycleService.instance.exitApp();
    return UpdateInstallOutcome.installerStarted;
  }

  static Future<UpdateInstallOutcome> _startPortableUpdate({
    required String archivePath,
    required UpdatePhaseCallback onPhase,
  }) async {
    final executablePath = Platform.resolvedExecutable;
    if (!Platform.isWindows ||
        p.basename(executablePath).toLowerCase() != 'pure_music.exe') {
      throw UpdateInstallException('当前运行环境不支持便携版应用内更新');
    }

    final previousAppDir = p.dirname(executablePath);
    final newAppDir = await _createPortableUpdateDirectory(previousAppDir);
    var helperStarted = false;
    String? helperPath;
    try {
      onPhase('正在解压更新');
      await extractFileToDisk(archivePath, newAppDir.path);

      final newExecutable = File(p.join(newAppDir.path, 'pure_music.exe'));
      final migrationScript = File(
        p.join(
          newAppDir.path,
          _portableSupportDirectory,
          'upgrade_from_previous.ps1',
        ),
      );
      final applyScript = File(
        p.join(
          newAppDir.path,
          _portableSupportDirectory,
          'apply_portable_update.ps1',
        ),
      );
      if (!await newExecutable.exists() ||
          !await migrationScript.exists() ||
          !await applyScript.exists()) {
        throw UpdateInstallException('便携版更新包不完整');
      }

      helperPath = p.join(
        Directory.systemTemp.path,
        'pure_music_apply_update_${DateTime.now().microsecondsSinceEpoch}.ps1',
      );
      await applyScript.copy(helperPath);

      onPhase('正在切换版本');
      final process = await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          helperPath,
          '-PreviousPath',
          previousAppDir,
          '-NewPath',
          newAppDir.path,
          '-ProcessId',
          '$pid',
        ],
        workingDirectory: Directory.systemTemp.path,
        mode: ProcessStartMode.detached,
      );
      if (process.pid <= 0) {
        throw UpdateInstallException('启动便携版更新程序失败');
      }
      helperStarted = true;
      await _deleteQuietly(archivePath);
      await WindowLifecycleService.instance.exitApp();
      return UpdateInstallOutcome.portableStarted;
    } catch (error) {
      if (!helperStarted) {
        await _deleteDirectoryQuietly(newAppDir.path);
        if (helperPath != null) await _deleteQuietly(helperPath);
      }
      if (error is UpdateInstallException) rethrow;
      throw UpdateInstallException('准备便携版更新失败');
    }
  }

  static Future<Directory> _createPortableUpdateDirectory(
    String previousAppDir,
  ) async {
    final parent = Directory(p.dirname(previousAppDir));
    await parent.create(recursive: true);
    for (var attempt = 0; attempt < 5; attempt++) {
      final candidate = Directory(
        p.join(
          parent.path,
          '.pure_music_update_${DateTime.now().microsecondsSinceEpoch}_$attempt',
        ),
      );
      if (await candidate.exists()) continue;
      await candidate.create(recursive: true);
      return candidate;
    }
    throw UpdateInstallException('无法创建便携版更新目录');
  }

  static Future<String?> _resolveExpectedSha256({
    required UpdateInfo info,
    required UpdateChannel channel,
    required bool portableBuild,
    required CancelToken cancelToken,
  }) async {
    if (!info.hasChecksum(channel: channel, portableBuild: portableBuild)) {
      return null;
    }

    final direct = info.sha256(portableBuild: portableBuild)?.trim();
    if (direct != null && direct.isNotEmpty) {
      if (!_isSha256(direct)) {
        throw UpdateInstallException('更新校验值无效');
      }
      return direct.toLowerCase();
    }

    final checksumUrl = info.checksumUrl(
      channel: channel,
      portableBuild: portableBuild,
    );
    if (checksumUrl == null) {
      return null;
    }

    try {
      final response = await Dio().get<String>(
        checksumUrl,
        cancelToken: cancelToken,
        options: Options(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          responseType: ResponseType.plain,
        ),
      );
      final match = RegExp(
        r'\b([0-9a-fA-F]{64})\b',
      ).firstMatch(response.data ?? '');
      final hash = match?.group(1);
      if (hash == null) {
        throw UpdateInstallException('更新校验值无效');
      }
      return hash.toLowerCase();
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        logger.w(
          '[UpdateInstaller] checksum asset is missing; skip verification',
        );
        return null;
      }
      rethrow;
    } on UpdateInstallException {
      rethrow;
    } catch (_) {
      throw UpdateInstallException('获取更新校验值失败');
    }
  }

  static bool _isSha256(String value) =>
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);

  static Future<bool> _verifySha256(String path, String expected) async {
    final file = File(path);
    if (!await file.exists()) return false;
    final digest = await sha256.bind(file.openRead()).first;
    final actual = digest.toString().toLowerCase();
    final target = expected.trim().toLowerCase();
    logger.i('[UpdateInstaller] sha256 match=${actual == target}');
    return actual == target;
  }

  static Future<String> _prepareSavePath(String fileName) async {
    final dir = Directory(
      p.join(Directory.systemTemp.path, 'pure_music_update'),
    );
    await dir.create(recursive: true);
    final path = p.join(dir.path, fileName);
    await _deleteQuietly(path);
    return path;
  }

  static String _fileNameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    final segment = uri?.pathSegments.isNotEmpty == true
        ? uri!.pathSegments.last
        : '';
    if (segment.isEmpty) return 'pure_music_update.bin';
    return segment;
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static Future<void> _deleteDirectoryQuietly(String path) async {
    try {
      final directory = Directory(path);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {}
  }
}
