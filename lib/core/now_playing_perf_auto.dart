import 'dart:async';
import 'dart:io';

import 'package:pure_music/native/bass/bass_player.dart' show PlayerState;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/core/immersive.dart';
import 'package:pure_music/core/now_playing_perf_probe.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/perf_probe.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_lifecycle.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:window_manager/window_manager.dart';

/// 探针专用自动化：进播放页、开始播放、快速切歌、在窗口状态间轮转，
/// 用来在真实使用路径上压内存和帧率。只有编译进 PERF_PROBE 才会触发。
class NowPlayingPerfAuto {
  static bool get enabled => PerfProbe.enabled;

  /// `PURE_MUSIC_PERF_SCRIPT`：逗号分隔的动作，按顺序执行。
  static void schedule() {
    if (!enabled) return;
    final script = Platform.environment['PURE_MUSIC_PERF_SCRIPT'] ?? '';
    if (script.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runScript(script));
    });
  }

  /// 兼容旧参数：只进播放页，不开播。
  static void scheduleNavigation() {
    if (!enabled) return;
    if ((Platform.environment['PURE_MUSIC_PERF_SCRIPT'] ?? '').isNotEmpty) {
      return;
    }
    final nav = Platform.environment['PURE_MUSIC_PERF_NAV'] ?? '';
    if (nav != 'nowplaying') return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runScript('nowplaying:0'));
    });
  }

  static Future<void> _runScript(String script) async {
    final actions = script
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final playback = PlayService.instance.playbackService;
    try {
      for (final action in actions) {
        final parts = action.split(':');
        switch (parts.first) {
          // nowplaying:<play 1/0>
          case 'nowplaying':
            final play = parts.length > 1 && parts[1] == '1';
            await _startNowPlaying(play);
          // switches:<n>:<gapMs>
          case 'switches':
            await _switchSongs(
              int.parse(parts[1]),
              parts.length > 2 ? int.parse(parts[2]) : 500,
            );
          // hidden:<minimize|tray|covered>:<n>:<gapMs>
          case 'hidden':
            await _switchHidden(
              parts[1],
              int.parse(parts[2]),
              parts.length > 3 ? int.parse(parts[3]) : 300,
            );
          // states:<holdSeconds>:<cycles>
          case 'states':
            await _cycleStates(
              int.parse(parts[1]),
              parts.length > 2 ? int.parse(parts[2]) : 1,
            );
          // idle:<seconds>
          case 'idle':
            await _hold(int.parse(parts[1]));
          // fs:<seconds>：进全屏停一会儿再退出
          case 'fs':
            await windowManager.setFullScreen(true);
            await _hold(int.parse(parts[1]));
            await windowManager.setFullScreen(false);
            await _hold(1);
          case 'report':
            NowPlayingPerfProbe.instance.writeReportIfRequested();
            PerfProbe.writeReportIfRequested(full: true);
          case 'exit':
            log.app.info('legacy', '[perf] script exit');
            await Future<void>.delayed(const Duration(milliseconds: 300));
            exit(0);
          default:
            log.app.warn('legacy', '[perf] unknown action: $action');
        }
      }
    } catch (error, trace) {
      log.app.error('legacy', '[perf] script failed: $error', stackTrace: trace);
    }
    NowPlayingPerfProbe.instance.writeReportIfRequested();
    PerfProbe.writeReportIfRequested(full: true);
    log.app.info('legacy', '[perf] script done state=${playback.playerState}');
  }

  /// 进播放页并真的开始放：暂停状态下播放页根本不渲染，数据没有意义。
  static Future<void> _startNowPlaying(bool play) async {
    await _waitForRouter();
    final playback = PlayService.instance.playbackService;
    if (play) {
      final playlist = await _waitForPlaylist();
      if (playlist.isNotEmpty) playback.play(0, playlist);
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await _focusWindow();
    await _ensureNowPlaying();
    for (var i = 0; i < 10 && play && playback.playerState != PlayerState.playing; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    log.app.info('legacy', '[perf] nowplaying state=${playback.playerState}');
  }

  static Future<void> _switchSongs(int count, int gapMs) async {
    final playback = PlayService.instance.playbackService;
    final gap = Duration(milliseconds: gapMs);
    for (var i = 0; i < count; i++) {
      await Future<void>.delayed(gap);
      if (i.isEven) {
        playback.nextAudio();
      } else {
        playback.lastAudio();
      }
      // 每 10 次把进度甩到曲尾，触发收尾、记忆位置、切歌计划等真实路径。
      if (i % 10 == 9) {
        final length = playback.nowPlaying?.duration.toDouble() ?? 0;
        if (length > 12) playback.seek(length - 3);
      }
    }
  }

  /// 隐藏状态下切歌：最小化 / 托盘 / 被挡住时解码新封面、重建歌词，
  /// 是后台瘦身最容易漏掉的真实路径。
  static Future<void> _switchHidden(String mode, int count, int gapMs) async {
    Process? cover;
    switch (mode) {
      case 'minimize':
        await windowManager.minimize();
      case 'tray':
        await _hideToTray();
      case 'covered':
        cover = await Process.start('notepad', []);
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      default:
        log.app.warn('legacy', '[perf] unknown hidden mode: $mode');
        return;
    }
    await _hold(3);
    await _switchSongs(count, gapMs);
    await _hold(3);
    if (cover != null) {
      cover.kill();
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    // 用应用自己的恢复路径：show/restore 顺序和渲染门闩都在里面。
    await WindowLifecycleService.instance.showWindow();
  }

  static Future<void> _cycleStates(int holdSeconds, int cycles) async {
    for (var cycle = 0; cycle < cycles; cycle++) {
      await _hold(2);
      await windowManager.maximize();
      await _hold(holdSeconds);
      await windowManager.setFullScreen(true);
      await _hold(holdSeconds);
      await windowManager.setFullScreen(false);
      await _hold(1);
      await ImmersiveModeController.instance.toggle();
      await _hold(holdSeconds);
      await ImmersiveModeController.instance.toggle();
      await _hold(1);
      await windowManager.minimize();
      await _hold(holdSeconds);
      await WindowLifecycleService.instance.showWindow();
      await _hold(1);
      await _hideToTray();
      await _hold(holdSeconds);
      await WindowLifecycleService.instance.showWindow();
      await _hold(1);
      // 被挡住：新开记事本盖住播放器
      final cover = await Process.start('notepad', []);
      await _hold(holdSeconds);
      cover.kill();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await WindowLifecycleService.instance.showWindow();
      await _hold(1);
      log.app.info('legacy', '[perf] state cycle ${cycle + 1} done');
    }
  }

  static Future<void> _hideToTray() async {
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
  }

  static Future<void> _hold(int seconds) =>
      Future<void>.delayed(Duration(seconds: seconds));

  static void _openNowPlaying() {
    final ctx = routerKey.currentContext;
    if (ctx == null) return;
    GoRouter.of(ctx).go(app_paths.NOW_PLAYING_PAGE);
  }

  static Future<void> _focusWindow() async {
    try {
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.restore();
      await windowManager.focus();
    } catch (_) {
      // 窗口不在前台时探针数据不可信；失败也继续，至少采集能跑完。
    }
  }

  static Future<void> _ensureNowPlaying({int attempts = 6}) async {
    for (var i = 0; i < attempts; i++) {
      final ctx = routerKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      final path = GoRouter.of(ctx).routeInformationProvider.value.uri.path;
      if (path == app_paths.NOW_PLAYING_PAGE) return;
      _openNowPlaying();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  static Future<void> _waitForRouter() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (routerKey.currentContext != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('窗口还没起来');
  }

  static Future<List<Audio>> _waitForPlaylist() async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline)) {
      final audios = AudioLibrary.instance.audioCollection;
      if (audios.length >= 4) return List<Audio>.of(audios);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return List<Audio>.of(AudioLibrary.instance.audioCollection);
  }
}
