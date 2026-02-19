import 'dart:async';
import 'dart:math' as math;

import 'package:pure_music/core/preference.dart';
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
    // 注册独占模式状态变化回调
    _player.onExclusiveModeChanged = (exclusive) {
      _wasapiExclusive.value = exclusive;
    };

    _playerStateStreamSub = playerStateStream.listen((event) {
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

    // Restore EQ settings
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
    LOGGER.i("[action] setEQ band=$band gain=$gain");
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

  late final _wasapiExclusive = ValueNotifier(_player.wasapiExclusive);
  ValueNotifier<bool> get wasapiExclusive => _wasapiExclusive;

  /// 独占模式
  void useExclusiveMode(bool exclusive) {
    LOGGER.i("[action] useExclusiveMode=$exclusive");
    AudioEchoLogRecorder.instance
        .mark('useExclusiveMode', extra: {'exclusive': exclusive});
    if (_player.useExclusiveMode(exclusive)) {
      _wasapiExclusive.value = exclusive;
    }
  }

  Audio? nowPlaying;

  int? _playlistIndex;
  int get playlistIndex => _playlistIndex ?? 0;

  final ValueNotifier<List<Audio>> playlist = ValueNotifier([]);
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
    LOGGER.i("[action] setPitch=$value");
    AudioEchoLogRecorder.instance.mark('setPitch', extra: {'value': value});
    _pitch.value = value;
    _player.setPitch(value);
  }

  late final _rate = ValueNotifier(1.0);
  ValueNotifier<double> get rate => _rate;

  void setRate(double value) {
    LOGGER.i("[action] setRate=$value");
    AudioEchoLogRecorder.instance.mark('setRate', extra: {'value': value});
    _rate.value = value;
    _player.setRate(value);
  }

  late final _shuffle = ValueNotifier(false);
  ValueNotifier<bool> get shuffle => _shuffle;

  double get length => _player.length;

  double get position => _player.position;

  PlayerState get playerState => _player.playerState;

  double get volumeDsp => _player.volumeDsp;

  /// 修改解码时的音量（不影响 Windows 系统音量）
  void setVolumeDsp(double volume) {
    LOGGER.i("[action] setVolumeDsp=$volume");
    AudioEchoLogRecorder.instance
        .mark('setVolumeDsp', extra: {'value': volume});
    _pref.volumeDsp = volume;
    _applyOutputGain();
    notifyListeners();
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
  /// 2. 更新 [nowPlaying] 为 playlist[_nowPlayingIndex]
  /// 3. _bassPlayer.setSource
  /// 4. 设置解码音量
  /// 4. 获取歌词 **将 [_nextLyricLine] 置为0**
  /// 5. 播放
  /// 6. 通知并更新主题色
  void _loadAndPlay(int audioIndex, List<Audio> playlist) {
    try {
      _playlistIndex = audioIndex;
      nowPlaying = playlist[audioIndex];
      _lastNowPlayingChangedMs = DateTime.now().millisecondsSinceEpoch;
      _player.setSource(nowPlaying!.path);
      setVolumeDsp(AppPreference.instance.playbackPref.volumeDsp);

      playService.lyricService.updateLyric();

      _player.start();
      notifyListeners();
      ThemeProvider.instance.applyThemeFromAudio(nowPlaying!);

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
      LOGGER.e("[load and play] $err");
      showTextOnSnackBar(err.toString());
    }
  }

  /// 播放当前播放列表的第几项，只能用在播放列表界面
  void playIndexOfPlaylist(int audioIndex) {
    LOGGER.i("[action] playIndexOfPlaylist=$audioIndex");
    AudioEchoLogRecorder.instance
        .mark('playIndexOfPlaylist', extra: {'index': audioIndex});
    _loadAndPlay(audioIndex, playlist.value);
  }

  /// 播放playlist[audioIndex]并设置播放列表为playlist
  void play(int audioIndex, List<Audio> playlist) {
    LOGGER.i("[action] play index=$audioIndex playlistLen=${playlist.length}");
    AudioEchoLogRecorder.instance.mark('play',
        extra: {'index': audioIndex, 'playlistLen': playlist.length});
    if (shuffle.value) {
      this.playlist.value = List.from(playlist);
      final willPlay = this.playlist.value.removeAt(audioIndex);
      this.playlist.value.shuffle();
      this.playlist.value.insert(0, willPlay);
      _playlistBackup = List.from(playlist);
      _loadAndPlay(0, this.playlist.value);
    } else {
      _loadAndPlay(audioIndex, playlist);
      this.playlist.value = List.from(playlist);
      _playlistBackup = List.from(playlist);
    }
  }

  void shuffleAndPlay(List<Audio> audios) {
    LOGGER.i("[action] shuffleAndPlay len=${audios.length}");
    AudioEchoLogRecorder.instance
        .mark('shuffleAndPlay', extra: {'len': audios.length});
    playlist.value = List.from(audios);
    playlist.value.shuffle();
    _playlistBackup = List.from(audios);

    shuffle.value = true;

    _loadAndPlay(0, playlist.value);
  }

  /// 下一首播放
  void addToNext(Audio audio) {
    LOGGER.i("[action] addToNext path=${audio.path}");
    AudioEchoLogRecorder.instance
        .mark('addToNext', extra: {'path': audio.path});
    if (_playlistIndex != null) {
      playlist.value.insert(_playlistIndex! + 1, audio);
      _playlistBackup = List.from(playlist.value);
      if (nowPlaying != null) {
        _persistLastSession(
          playlist: playlist.value,
          playlistIndex: _playlistIndex!,
          nowPlaying: nowPlaying!,
        );
      }
    }
  }

  void useShuffle(bool flag) {
    if (nowPlaying == null) return;
    if (flag == shuffle.value) return;
    LOGGER.i("[action] useShuffle=$flag");
    AudioEchoLogRecorder.instance.mark('useShuffle', extra: {'flag': flag});

    if (flag) {
      playlist.value.shuffle();
      playlist.value.remove(nowPlaying!);
      playlist.value.insert(0, nowPlaying!);
      _playlistIndex = 0;
      shuffle.value = true;
    } else {
      playlist.value = List.from(_playlistBackup);
      _playlistIndex = playlist.value.indexOf(nowPlaying!);
      shuffle.value = false;
    }

    if (_playlistIndex != null) {
      _persistLastSession(
        playlist: playlist.value,
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
    AppPreference.instance.save();
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

    this.playlist.value = List.from(restoredPlaylist);
    _playlistBackup = List.from(restoredPlaylist);
    _playlistIndex = restoredIndex;
    nowPlaying = restoredPlaylist[restoredIndex];
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
      notifyListeners();
    } catch (err) {
      LOGGER.e("[restore last session] $err");
    }
  }

  void _nextAudio_forward() {
    if (_playlistIndex == null) return;

    if (_playlistIndex! < playlist.value.length - 1) {
      _loadAndPlay(_playlistIndex! + 1, playlist.value);
    }
  }

  void _nextAudio_loop() {
    if (_playlistIndex == null) return;

    int newIndex = _playlistIndex! + 1;
    if (newIndex >= playlist.value.length) {
      newIndex = 0;
    }

    _loadAndPlay(newIndex, playlist.value);
  }

  void _nextAudio_singleLoop() {
    if (_playlistIndex == null) return;

    _loadAndPlay(_playlistIndex!, playlist.value);
  }

  void _autoNextAudio() {
    switch (playMode.value) {
      case PlayMode.forward:
        _nextAudio_forward();
        break;
      case PlayMode.loop:
        _nextAudio_loop();
        break;
      case PlayMode.singleLoop:
        _nextAudio_singleLoop();
        break;
    }
  }

  /// 手动下一曲时默认循环播放列表
  void nextAudio() {
    LOGGER.i("[action] nextAudio");
    AudioEchoLogRecorder.instance.mark('nextAudio');
    _nextAudio_loop();
  }

  /// 手动上一曲时默认循环播放列表
  void lastAudio() {
    LOGGER.i("[action] lastAudio");
    AudioEchoLogRecorder.instance.mark('lastAudio');
    if (_playlistIndex == null) return;

    int newIndex = _playlistIndex! - 1;
    if (newIndex < 0) {
      newIndex = playlist.value.length - 1;
    }

    _loadAndPlay(newIndex, playlist.value);
  }

  /// 暂停
  void pause() {
    try {
      LOGGER.i("[action] pause");
      AudioEchoLogRecorder.instance.mark('pause');
      _player.pause();
      _smtc.updateState(state: SMTCState.paused);
      playService.desktopLyricService.canSendMessage.then((canSend) {
        if (!canSend) return;

        playService.desktopLyricService.sendPlayerStateMessage(false);
      });
    } catch (err) {
      LOGGER.e("[pause] $err");
      showTextOnSnackBar(err.toString());
    }
  }

  /// 恢复播放
  void start() {
    try {
      LOGGER.i("[action] start");
      AudioEchoLogRecorder.instance.mark('start');
      _player.start();
      _smtc.updateState(state: SMTCState.playing);
      playService.desktopLyricService.canSendMessage.then((canSend) {
        if (!canSend) return;

        playService.desktopLyricService.sendPlayerStateMessage(true);
      });
    } catch (err) {
      LOGGER.e("[start]: $err");
      showTextOnSnackBar(err.toString());
    }
  }

  /// 再次播放。在顺序播放完最后一曲时再次按播放时使用。
  /// 与 [start] 的差别在于它会通知重绘组件
  void playAgain() => _nextAudio_singleLoop();

  void seek(double position) {
    LOGGER.i("[action] seek=$position");
    AudioEchoLogRecorder.instance.mark('seek', extra: {'pos': position});
    _player.seek(position);
    playService.lyricService.findCurrLyricLineAt(position);
  }

  void close() {
    _playerStateStreamSub.cancel();
    _smtcEventStreamSub.cancel();
    _player.free();
    _smtc.close();
  }
}
