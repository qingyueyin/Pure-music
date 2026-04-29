import 'dart:async';
import 'dart:math' as math;

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/utils.dart';
import 'package:flutter/foundation.dart';

/// 只通知 now playing 变更
class PlaybackService extends ChangeNotifier {
  final PlayService playService;

  late StreamSubscription _playerStateStreamSub;
  late StreamSubscription _smtcEventStreamSub;
  int _lastNowPlayingChangedMs = 0;

  PlaybackService(this.playService) {
    _player.onExclusiveModeChanged = (exclusive) {
      _wasapiExclusive.value = exclusive;
    };

    _playerStateStreamSub = playerStateStream.listen((event) {
      _playerState.value = event;
      if (event == PlayerState.completed) {
        _autoNextAudio();
      }
    });

    _smtcEventStreamSub = _smtc.subscribeToControlEvents().listen((event) {
      switch (event) {
        case SMTCControlEvent.play:
          start();
          break;
        case SMTCControlEvent.pause:
          pause();
          break;
        case SMTCControlEvent.previous:
          lastAudio();
          break;
        case SMTCControlEvent.next:
          nextAudio();
          break;
        case SMTCControlEvent.unknown:
      }
    });

    positionStream.listen((progress) {
      _smtc.updateTimeProperties(progress: (progress * 1000).floor());
    });

    final savedGains = _pref.eqGains;
    for (int i = 0; i < 10; i++) {
      if (i < savedGains.length) {
        _player.setEQ(i, savedGains[i]);
      }
    }
    _applyOutputGain();

    Future(() async {
      await _restoreLastSession();
    });
  }

  final _player = BassPlayer();
  final _smtc = SmtcFlutter();
  final _pref = AppPreference.instance.playbackPref;

  bool get isBassFxLoaded => _player.isBassFxLoaded;
  String get bassDebugStateLine => _player.debugStateLine;

  List<double> get eqGains => _player.eqGains;
  List<EqPreset> get eqPresets => _pref.eqPresets;

  double get eqPreampDb => _pref.eqPreampDb;
  bool get eqAutoGainEnabled => _pref.eqAutoGainEnabled;
  double get eqAutoHeadroomDb => _pref.eqAutoHeadroomDb;

  double get eqAutoGainDb => eqAutoGainEnabled ? _computeEqAutoGainDb() : 0.0;

  double _dbToLinear(double db) {
    return math.pow(10.0, db / 20.0).toDouble();
  }

  double _computeEqAutoGainDb() {
    final gains = _player.eqGains;
    if (gains.isEmpty) return 0.0;
    if (gains.every((g) => g.abs() < 1e-6)) return 0.0;

    double maxGain = gains.first;
    double sum = 0.0;
    for (final g in gains) {
      if (g > maxGain) maxGain = g;
      sum += g;
    }
    final meanGain = sum / gains.length;

    final desired = -meanGain;
    final safeUpper = math.max(0.0, (-maxGain - eqAutoHeadroomDb).toDouble());
    final clampedDesired = desired.clamp(-24.0, safeUpper).toDouble();
    return clampedDesired;
  }

  void _applyOutputGain() {
    final totalDb = eqPreampDb + (eqAutoGainEnabled ? eqAutoGainDb : 0.0);
    final volume = (_pref.volumeDsp * _dbToLinear(totalDb)).clamp(0.0, 8.0);
    _player.setVolumeDsp(volume.toDouble());
  }

  void refreshEQ() {
    _player.refreshEQ();
    _applyOutputGain();
  }

  void setEQ(int band, double gain) {
    logger.i("[action] setEQ band=$band gain=$gain");
    AudioEchoLogRecorder.instance
        .mark('setEQ', extra: {'band': band, 'gain': gain});
    _player.setEQ(band, gain);
    if (band < _pref.eqGains.length) {
      _pref.eqGains[band] = gain;
    }
    _applyOutputGain();
  }

  void setEqPreampDb(double value) {
    final next = value.clamp(-24.0, 24.0).toDouble();
    if (_pref.eqPreampDb == next) return;
    _pref.eqPreampDb = next;
    _applyOutputGain();
  }

  void setEqAutoGainEnabled(bool enabled) {
    if (_pref.eqAutoGainEnabled == enabled) return;
    _pref.eqAutoGainEnabled = enabled;
    _applyOutputGain();
  }

  void saveEqPreset(String name) {
    final gains = List<double>.from(_player.eqGains);
    final existingIndex = _pref.eqPresets.indexWhere((e) => e.name == name);
    if (existingIndex >= 0) {
      _pref.eqPresets[existingIndex] = EqPreset(name, gains);
    } else {
      _pref.eqPresets.add(EqPreset(name, gains));
    }
    AppPreference.instance.save();
  }

  void removeEqPreset(String name) {
    _pref.eqPresets.removeWhere((e) => e.name == name);
    AppPreference.instance.save();
  }

  void applyEqPreset(EqPreset preset) {
    for (int i = 0; i < 10; i++) {
      if (i < preset.gains.length) {
        setEQ(i, preset.gains[i]);
      }
    }
    AppPreference.instance.save();
  }

  void savePreference() {
    AppPreference.instance.save();
  }

  void _savePlaybackOnly() {
    AppPreference.instance.savePlaybackOnly();
  }

  late final _wasapiExclusive = ValueNotifier(_player.wasapiExclusive);
  ValueNotifier<bool> get wasapiExclusive => _wasapiExclusive;

  /// 独占模式
  void useExclusiveMode(bool exclusive) {
    logger.i("[action] useExclusiveMode=$exclusive");
    AudioEchoLogRecorder.instance
        .mark('useExclusiveMode', extra: {'exclusive': exclusive});
    if (_player.useExclusiveMode(exclusive)) {
      _wasapiExclusive.value = exclusive;
    }
  }

  late final _nowPlaying = ValueNotifier<Audio?>(null);
  ValueNotifier<Audio?> get nowPlayingNotifier => _nowPlaying;
  Audio? get nowPlaying => _nowPlaying.value;

  int? _playlistIndex;
  int get playlistIndex => _playlistIndex ?? 0;

  late final _playlist = ValueNotifier<List<Audio>>([]);
  ValueNotifier<List<Audio>> get playlistNotifier => _playlist;
  ValueNotifier<List<Audio>> get playlist => _playlist;
  List<Audio> _playlistBackup = [];

  late final _playMode = ValueNotifier(_pref.playMode);
  ValueNotifier<PlayMode> get playMode => _playMode;

  void setPlayMode(PlayMode playMode) {
    this.playMode.value = playMode;
    _pref.playMode = playMode;
  }

  late final _pitch = ValueNotifier(0.0);
  ValueNotifier<double> get pitch => _pitch;

  void setPitch(double value) {
    logger.i("[action] setPitch=$value");
    AudioEchoLogRecorder.instance.mark('setPitch', extra: {'value': value});
    _pitch.value = value;
    _player.setPitch(value);
  }

  late final _rate = ValueNotifier(1.0);
  ValueNotifier<double> get rate => _rate;

  void setRate(double value) {
    logger.i("[action] setRate=$value");
    AudioEchoLogRecorder.instance.mark('setRate', extra: {'value': value});
    _rate.value = value;
    _player.setRate(value);
  }

  late final _shuffle = ValueNotifier(false);
  ValueNotifier<bool> get shuffle => _shuffle;

  late final _playerState = ValueNotifier(PlayerState.stopped);
  ValueNotifier<PlayerState> get playerStateNotifier => _playerState;
  PlayerState get playerState => _playerState.value;

  double get length => _player.length;

  double get position => _player.position;

  double get volumeDsp => _player.volumeDsp;

  /// 修改解码时的音量（不影响 Windows 系统音量）
  void setVolumeDsp(double volume) {
    logger.i("[action] setVolumeDsp=$volume");
    AudioEchoLogRecorder.instance
        .mark('setVolumeDsp', extra: {'value': volume});
    _pref.volumeDsp = volume;
    _applyOutputGain();
    _savePlaybackOnly();
  }

  Stream<double> get positionStream => _player.positionStream;

  Stream<Float32List> get spectrumStream => _player.spectrumStream;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  SpectrumUpdateMode get spectrumUpdateMode => _player.spectrumUpdateMode;

  void setSpectrumUpdateMode(SpectrumUpdateMode mode) {
    _player.setSpectrumUpdateMode(mode);
  }

  Duration get nowPlayingChangeAge {
    final t = _lastNowPlayingChangedMs;
    if (t <= 0) return const Duration(days: 999);
    final now = DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: (now - t).clamp(0, 1 << 31));
  }

  bool get nowPlayingChangedRecently =>
      nowPlayingChangeAge.inMilliseconds < 220;

  /// 1. 更新 [_playlistIndex] 为 [audioIndex]
  /// 2. 更新 [_nowPlaying] 为 playlist[_nowPlayingIndex]
  /// 3. _bassPlayer.setSource
  /// 4. 设置解码音量
  /// 4. 获取歌词 **将 [_nextLyricLine] 置为0**
  /// 5. 播放
  /// 6. 通知并更新主题色
  void _loadAndPlay(int audioIndex, List<Audio> playlist) {
    try {
      _playlistIndex = audioIndex;
      _nowPlaying.value = playlist[audioIndex];
      _lastNowPlayingChangedMs = DateTime.now().millisecondsSinceEpoch;
      _player.setSource(nowPlaying!.path);
      setVolumeDsp(AppPreference.instance.playbackPref.volumeDsp);

      playService.lyricService.updateLyric();

      _player.start();
      _playerState.value = PlayerState.playing;
      ThemeProvider.instance.applyThemeFromAudio(nowPlaying!);

      if (audioIndex < playlist.length - 1) {
        CoverCache.instance.preloadNext(playlist[audioIndex + 1].path);
        playService.lyricService.prefetchLyric(playlist[audioIndex + 1]);
        if (audioIndex < playlist.length - 2) {
          playService.lyricService.prefetchLyric(playlist[audioIndex + 2]);
        }
      }

      _persistLastSession(
        playlist: playlist,
        playlistIndex: audioIndex,
        nowPlaying: nowPlaying!,
      );

      _smtc.updateState(state: SMTCState.playing);
      _smtc.updateDisplay(
        title: nowPlaying!.title,
        artist: nowPlaying!.artist,
        album: nowPlaying!.album,
        duration: (length * 1000).floor(),
        path: nowPlaying!.path,
      );

      playService.desktopLyricService.canSendMessage.then((canSend) {
        if (!canSend) return;

        playService.desktopLyricService.sendPlayerStateMessage(
          playerState == PlayerState.playing,
        );
        playService.desktopLyricService.sendNowPlayingMessage(nowPlaying!);
      });
    } catch (err) {
      logger.e("[load and play] $err");
      showTextOnSnackBar(err.toString());
    }
  }

  /// 播放当前播放列表的第几项，只能用在播放列表界面
  void playIndexOfPlaylist(int audioIndex) {
    logger.i("[action] playIndexOfPlaylist=$audioIndex");
    AudioEchoLogRecorder.instance
        .mark('playIndexOfPlaylist', extra: {'index': audioIndex});
    _loadAndPlay(audioIndex, playlist.value);
  }

  /// 播放 playlist[audioIndex] 并设置播放列表为 playlist
  void play(int audioIndex, List<Audio> playlist) {
    logger.i("[action] play index=$audioIndex playlistLen=${playlist.length}");
    AudioEchoLogRecorder.instance.mark('play',
        extra: {'index': audioIndex, 'playlistLen': playlist.length});
    if (shuffle.value) {
      final shuffled = List<Audio>.from(playlist);
      final willPlay = shuffled.removeAt(audioIndex);
      shuffled.shuffle();
      shuffled.insert(0, willPlay);
      _playlistBackup = playlist;
      _playlist.value = shuffled;
      _loadAndPlay(0, shuffled);
    } else {
      _playlistBackup = playlist;
      _playlist.value = playlist;
      _loadAndPlay(audioIndex, playlist);
    }
  }

  void shuffleAndPlay(List<Audio> audios) {
    logger.i("[action] shuffleAndPlay len=${audios.length}");
    AudioEchoLogRecorder.instance
        .mark('shuffleAndPlay', extra: {'len': audios.length});
    final shuffled = List<Audio>.from(audios);
    shuffled.shuffle();
    _playlist.value = shuffled;
    _playlistBackup = audios;

    shuffle.value = true;

    _loadAndPlay(0, shuffled);
  }

  /// 下一首播放
  void addToNext(Audio audio) {
    logger.i("[action] addToNext path=${audio.path}");
    AudioEchoLogRecorder.instance
        .mark('addToNext', extra: {'path': audio.path});
    if (_playlistIndex != null) {
      _playlist.value = [..._playlist.value]..insert(_playlistIndex! + 1, audio);
      _playlistBackup = _playlist.value;
      if (nowPlaying != null) {
        _persistLastSession(
          playlist: _playlist.value,
          playlistIndex: _playlistIndex!,
          nowPlaying: nowPlaying!,
        );
      }
    }
  }

  void useShuffle(bool flag) {
    if (nowPlaying == null) return;
    if (flag == shuffle.value) return;
    logger.i("[action] useShuffle=$flag");
    AudioEchoLogRecorder.instance.mark('useShuffle', extra: {'flag': flag});

    if (flag) {
      final shuffled = [..._playlist.value]
        ..remove(nowPlaying!)
        ..shuffle()
        ..insert(0, nowPlaying!);
      _playlist.value = shuffled;
      _playlistIndex = 0;
      shuffle.value = true;
    } else {
      _playlist.value = _playlistBackup;
      _playlistIndex = _playlist.value.indexOf(nowPlaying!);
      shuffle.value = false;
    }

    if (_playlistIndex != null) {
      _persistLastSession(
        playlist: _playlist.value,
        playlistIndex: _playlistIndex!,
        nowPlaying: nowPlaying!,
      );
    }
  }

  void _persistLastSession({
    required List<Audio> playlist,
    required int playlistIndex,
    required Audio nowPlaying,
  }) {
    _pref.lastAudioPath = nowPlaying.path;
    _pref.lastPlaylistPaths = playlist.map((e) => e.path).toList();
    _pref.lastPlaylistIndex = playlistIndex;
    _savePlaybackOnly();
  }

  Future<void> _restoreLastSession() async {
    final lastPath = _pref.lastAudioPath;
    if (lastPath.isEmpty) return;

    for (int i = 0; i < 10; i++) {
      if (AudioLibrary.instance.audioCollection.isNotEmpty) break;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (AudioLibrary.instance.audioCollection.isEmpty) return;

    final pathToAudio = <String, Audio>{};
    for (final audio in AudioLibrary.instance.audioCollection) {
      pathToAudio[audio.path] = audio;
    }

    final restoredPlaylist = <Audio>[];
    for (final p in _pref.lastPlaylistPaths) {
      final a = pathToAudio[p];
      if (a != null) {
        restoredPlaylist.add(a);
      }
    }

    if (restoredPlaylist.isEmpty) {
      final single = pathToAudio[lastPath];
      if (single == null) return;
      restoredPlaylist.add(single);
    }

    var restoredIndex = _pref.lastPlaylistIndex;
    restoredIndex = restoredIndex.clamp(0, restoredPlaylist.length - 1);
    final idxByPath = restoredPlaylist.indexWhere((e) => e.path == lastPath);
    if (idxByPath >= 0) {
      restoredIndex = idxByPath;
    }

    _playlist.value = restoredPlaylist;
    _playlistBackup = restoredPlaylist;
    _playlistIndex = restoredIndex;
    _nowPlaying.value = restoredPlaylist[restoredIndex];
    _lastNowPlayingChangedMs = DateTime.now().millisecondsSinceEpoch;

    try {
      _player.setSource(nowPlaying!.path);
      setVolumeDsp(_pref.volumeDsp);
      playService.lyricService.updateLyric();
      ThemeProvider.instance.applyThemeFromAudio(nowPlaying!);

      _smtc.updateState(state: SMTCState.paused);
      _smtc.updateDisplay(
        title: nowPlaying!.title,
        artist: nowPlaying!.artist,
        album: nowPlaying!.album,
        duration: (length * 1000).floor(),
        path: nowPlaying!.path,
      );
    } catch (err) {
      logger.e("[restore last session] $err");
    }
  }

  void _nextAudioForward() {
    if (_playlistIndex == null) return;

    if (_playlistIndex! < _playlist.value.length - 1) {
      _loadAndPlay(_playlistIndex! + 1, _playlist.value);
    }
  }

  void _nextAudioLoop() {
    if (_playlistIndex == null) return;

    int newIndex = _playlistIndex! + 1;
    if (newIndex >= _playlist.value.length) {
      newIndex = 0;
    }

    _loadAndPlay(newIndex, _playlist.value);
  }

  void _nextAudioSingleLoop() {
    if (_playlistIndex == null) return;

    _loadAndPlay(_playlistIndex!, _playlist.value);
  }

  void _autoNextAudio() {
    switch (playMode.value) {
      case PlayMode.forward:
        _nextAudioForward();
        break;
      case PlayMode.loop:
        _nextAudioLoop();
        break;
      case PlayMode.singleLoop:
        _nextAudioSingleLoop();
        break;
    }
  }

  /// 手动下一曲时默认循环播放列表
  void nextAudio() {
    logger.i("[action] nextAudio");
    AudioEchoLogRecorder.instance.mark('nextAudio');
    _nextAudioLoop();
  }

  /// 手动上一曲时默认循环播放列表
  void lastAudio() {
    logger.i("[action] lastAudio");
    AudioEchoLogRecorder.instance.mark('lastAudio');
    if (_playlistIndex == null) return;

    int newIndex = _playlistIndex! - 1;
    if (newIndex < 0) {
      newIndex = _playlist.value.length - 1;
    }

    _loadAndPlay(newIndex, _playlist.value);
  }

  /// 暂停
  void pause() {
    try {
      logger.i("[action] pause");
      AudioEchoLogRecorder.instance.mark('pause');
      _player.pause();
      _smtc.updateState(state: SMTCState.paused);
      playService.desktopLyricService.canSendMessage.then((canSend) {
        if (!canSend) return;

        playService.desktopLyricService.sendPlayerStateMessage(false);
      });
    } catch (err) {
      logger.e("[pause] $err");
      showTextOnSnackBar(err.toString());
    }
  }

  /// 恢复播放
  void start() {
    try {
      logger.i("[action] start");
      AudioEchoLogRecorder.instance.mark('start');
      _player.start();
      _smtc.updateState(state: SMTCState.playing);
      playService.desktopLyricService.canSendMessage.then((canSend) {
        if (!canSend) return;

        playService.desktopLyricService.sendPlayerStateMessage(true);
      });
    } catch (err) {
      logger.e("[start]: $err");
      showTextOnSnackBar(err.toString());
    }
  }

  /// 再次播放。在顺序播放完最后一曲时再次按播放时使用。
  /// 与 [start] 的差别在于它会通知重绘组件
  void playAgain() => _nextAudioSingleLoop();

  void seek(double position) {
    logger.i("[action] seek=$position");
    AudioEchoLogRecorder.instance.mark('seek', extra: {'pos': position});
    _player.seek(position);
    playService.lyricService.findCurrLyricLineAt(position);
  }

  Future<void> close() async {
    try {
      _playerStateStreamSub.cancel();
    } catch (_) {}
    try {
      _smtcEventStreamSub.cancel();
    } catch (_) {}
    
    // 释放播放器资源（可能耗时）
    try {
      _player.free();
    } catch (e) {
      logger.w("_player.free error: $e");
    }
    
    // 关闭 SMTC
    try {
      await _smtc.close().timeout(const Duration(milliseconds: 500)).catchError((_) {});
    } catch (_) {}
  }
}
