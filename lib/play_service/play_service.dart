import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/matcher.dart' hide logger;
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/system_volume_service.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/play_service/desktop_lyric_service.dart';
import 'package:pure_music/play_service/lyric_service.dart';
import 'package:pure_music/play_service/playback_service.dart';

class PlayService {
  late final playbackService = PlaybackService(this);
  late final lyricService = LyricService(this);
  late final desktopLyricService = DesktopLyricService(this);

  PlayService._();

  static PlayService? _instance;
  static PlayService get instance {
    _instance ??= PlayService._();
    return _instance!;
  }

  Future<void> close() async {
    // 按顺序关闭服务，每个操作带超时保护
    try {
      await desktopLyricService.killDesktopLyric().timeout(
        const Duration(seconds: 1),
        onTimeout: () {
          logger.w('desktopLyricService.close timeout');
        },
      );
    } catch (e) {
      logger.w('desktopLyricService.close error: $e');
    }
    
    // 先关闭播放服务（可能触发回调）
    try {
      await playbackService.close().timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          logger.w('playbackService.close timeout');
        },
      );
    } catch (e) {
      logger.w('playbackService.close error: $e');
    }
    
    // 停止音频回波日志记录
    try {
      await AudioEchoLogRecorder.instance.stop().timeout(
        const Duration(seconds: 1),
        onTimeout: () {
          logger.w('AudioEchoLogRecorder.stop timeout');
        },
      );
    } catch (e) {
      logger.w('AudioEchoLogRecorder.stop error: $e');
    }

    ThemeProvider.instance.dispose();
    SystemVolumeService.instance.dispose();
    AlbumColorCache.instance.dispose();
    CoverImageCache.instance.dispose();
    LyricViewController.instance.dispose();
    AudioLibrary.instance.dispose();
    AppDb.instance.dispose();
    AppSettings.closeGithub();
    clearLyricCaches();

    // 歌词服务最后释放，避免 UI 组件仍在监听时访问已销毁的 service
    try {
      lyricService.dispose();
    } catch (e) {
      logger.w('lyricService.dispose error: $e');
    }

    _instance = null;
  }
}
