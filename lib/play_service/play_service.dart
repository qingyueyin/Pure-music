import 'package:pure_music/core/utils.dart';
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
          logger.w("desktopLyricService.close timeout");
        },
      );
    } catch (e) {
      logger.w("desktopLyricService.close error: $e");
    }
    
    // 释放歌词服务资源
    try {
      lyricService.dispose();
    } catch (e) {
      logger.w("lyricService.dispose error: $e");
    }
    
    // 关闭播放服务
    try {
      playbackService.close().timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          logger.w("playbackService.close timeout");
        },
      );
    } catch (e) {
      logger.w("playbackService.close error: $e");
    }
    
    // 停止音频回波日志记录
    try {
      await AudioEchoLogRecorder.instance.stop().timeout(
        const Duration(seconds: 1),
        onTimeout: () {
          logger.w("AudioEchoLogRecorder.stop timeout");
        },
      );
    } catch (e) {
      logger.w("AudioEchoLogRecorder.stop error: $e");
    }
  }
}
