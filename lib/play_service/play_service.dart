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
  PlaybackService? _playbackService;
  LyricService? _lyricService;
  DesktopLyricService? _desktopLyricService;

  PlaybackService get playbackService =>
      _playbackService ??= PlaybackService(this);
  LyricService get lyricService => _lyricService ??= LyricService(this);
  DesktopLyricService get desktopLyricService =>
      _desktopLyricService ??= DesktopLyricService(this);

  PlayService._();

  static PlayService? _instance;
  static PlayService get instance {
    _instance ??= PlayService._();
    return _instance!;
  }

  Future<void> close() async {
    // 按顺序关闭服务，每个操作带超时保护
    final desktopLyric = _desktopLyricService;
    if (desktopLyric != null) {
      try {
        await desktopLyric.killDesktopLyric().timeout(
          const Duration(seconds: 1),
          onTimeout: () {
            logger.w('desktopLyricService.close timeout');
          },
        );
      } catch (e) {
        logger.w('desktopLyricService.close error: $e');
      }
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

    LyricViewController.disposeIfInitialized();
    final lyric = _lyricService;
    if (lyric != null) {
      try {
        lyric.dispose();
      } catch (e) {
        logger.w('lyricService.dispose error: $e');
      }
    }

    final playback = _playbackService;
    if (playback != null) {
      try {
        await playback.close().timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            logger.w('playbackService.close timeout');
          },
        );
      } catch (e) {
        logger.w('playbackService.close error: $e');
      }
    }

    ThemeProvider.instance.dispose();
    SystemVolumeService.instance.dispose();
    AlbumColorCache.instance.dispose();
    CoverImageCache.instance.dispose();
    AudioLibrary.instance.dispose();
    AppDb.instance.dispose();
    AppSettings.closeGithub();
    clearLyricCaches();

    _instance = null;
  }
}
