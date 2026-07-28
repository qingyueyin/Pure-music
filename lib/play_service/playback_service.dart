import 'dart:async';
import 'dart:math' as math;

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/play_service/equalizer_service.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart' as rust_tag_reader;
import 'package:pure_music/native/rust/api/library_db.dart' as rust_library_db;
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/settings.dart';
import 'package:flutter/foundation.dart';

/// 只通知 now playing 变更
class PlaybackService extends ChangeNotifier {
  final PlayService playService;

  late StreamSubscription _playerStateStreamSub;
  late StreamSubscription _smtcEventStreamSub;
  int _lastNowPlayingChangedMs = 0;
  Timer? _smtcPositionTimer;
  int _songChangeTaskToken = 0;
  Timer? _songChangeMetadataTimer;
  Timer? _songChangePrefetchTimer;
  Timer? _songChangePersistTimer;
  Timer? _songChangeCleanupTimer;
  double _listenAccumulatedSec = 0;
  double _listenLastPositionSec = 0;
  double _thresholdSec = 0;
  bool _listenRecorded = false;
  StreamSubscription<double>? _listenStreamSub;
  String? _supportPath;
  bool _closed = false;

  PlaybackService(this.playService) {
    _player.onExclusiveModeChanged = (exclusive) {
      _wasapiExclusive.value = exclusive;
    };

    _playerStateStreamSub = playerStateStream.listen((event) {
      _playerState.value = event;
      _notifyPositionSync();
      _syncSmtcPositionTimer();
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
        case SMTCControlEvent.stop:
          pause();
          break;
        case SMTCControlEvent.unknown:
      }
    });

    _eq = EqualizerService(_player, _pref);

    _listenStreamSub = _player.positionStream.listen(_onPositionUpdate);

    Future.microtask(() async {
      try {
        await _restoreLastSession();
        _supportPath = (await getAppDataDir()).path;
      } catch (err, trace) {
        logger.e('[restoreLastSession] $err\n$trace');
      }
    });
  }

  final _player = BassPlayer();
  final _smtc = SmtcFlutter();
  final _pref = AppPreference.instance.playbackPref;
  late final EqualizerService _eq;
  String? _replayGainForPath;

  bool get isBassFxLoaded => _player.isBassFxLoaded;
  String get bassDebugStateLine => _player.debugStateLine;

  // EQ 相关方法委托给 EqualizerService
  List<double> get eqGains => _eq.eqGains;
  List<EqPreset> get eqPresets => _eq.eqPresets;
  double get eqPreampDb => _eq.eqPreampDb;
  bool get eqAutoGainEnabled => _eq.eqAutoGainEnabled;
  double get eqAutoHeadroomDb => _eq.eqAutoHeadroomDb;
  double get eqAutoGainDb => _eq.eqAutoGainDb;

  void refreshEQ() => _eq.refreshEQ();
  void setEQ(int band, double gain) => _eq.setEQ(band, gain);
  void setEqPreampDb(double value) => _eq.setEqPreampDb(value);
  void setEqAutoGainEnabled(bool enabled) => _eq.setEqAutoGainEnabled(enabled);
  Future<bool> saveEqPreset(String name) => _eq.saveEqPreset(name);
  Future<bool> removeEqPreset(String name) => _eq.removeEqPreset(name);
  Future<bool> applyEqPreset(EqPreset preset) => _eq.applyEqPreset(preset);
  void reapplyOutputGain() => _eq.reapplyOutputGain();

  void _readReplayGainFor(String path) {
    _replayGainForPath = path;
    rust_tag_reader.readAudioExtraMetadata(path: path).then((meta) {
      if (_replayGainForPath != path) return;
      _replayGainForPath = null;
      final raw = meta.replaygainTrackGain;
      if (raw == null || raw.isEmpty) return;
      final gainDb = double.tryParse(raw.replaceAll('dB', '').trim());
      if (gainDb == null) return;
      _player.replayGainDb = gainDb;
      _eq.reapplyOutputGain();
    }).catchError((_) {
      if (_replayGainForPath != path) return;
      _replayGainForPath = null;
    });
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
    logger.i('[action] useExclusiveMode=$exclusive');
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
    _savePlaybackOnly();
  }

  late final _pitch = ValueNotifier(0.0);
  ValueNotifier<double> get pitch => _pitch;

  void setPitch(double value) {
    logger.i('[action] setPitch=$value');
    AudioEchoLogRecorder.instance.mark('setPitch', extra: {'value': value});
    _pitch.value = value;
    _player.setPitch(value);
  }

  late final _rate = ValueNotifier(1.0);
  ValueNotifier<double> get rate => _rate;

  void setRate(double value) {
    logger.i('[action] setRate=$value');
    AudioEchoLogRecorder.instance.mark('setRate', extra: {'value': value});
    _rate.value = value;
    _player.setRate(value);
  }

  late final _shuffle = ValueNotifier(false);
  ValueNotifier<bool> get shuffle => _shuffle;

  /// 替换 nowPlaying
  void setNowPlaying([Audio? newNowPlaying]) {
    _nowPlaying.value = newNowPlaying;
  }

  late final _playerState = ValueNotifier(PlayerState.stopped);
  ValueNotifier<PlayerState> get playerStateNotifier => _playerState;
  PlayerState get playerState => _playerState.value;
  late final _positionSyncRevision = ValueNotifier<int>(0);
  ValueListenable<int> get positionSyncNotifier => _positionSyncRevision;

  double get length => _player.length;

  double get position => _player.position;

  double get volumeDsp => _player.volumeDsp;

  /// 修改解码时的音量（不影响 Windows 系统音量）
  void setVolumeDsp(double volume) {
    logger.i('[action] setVolumeDsp=$volume');
    AudioEchoLogRecorder.instance
        .mark('setVolumeDsp', extra: {'value': volume});
    _pref.volumeDsp = volume;
    _eq.reapplyOutputGain();
    _savePlaybackOnly();
  }

  Stream<double> get positionStream => _player.positionStream;

  Stream<Float32List> get spectrumStream => _player.spectrumStream;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  void _notifyPositionSync() {
    if (_closed) return;
    _positionSyncRevision.value += 1;
  }

  void _schedulePositionSyncBurst({
    int? token,
    String? path,
  }) {
    _notifyPositionSync();
    const delays = [
      Duration(milliseconds: 16),
      Duration(milliseconds: 80),
      Duration(milliseconds: 180),
      Duration(milliseconds: 360),
    ];
    for (final delay in delays) {
      Timer(delay, () {
        if (_closed) return;
        if (token != null && token != _songChangeTaskToken) return;
        if (path != null && nowPlaying?.path != path) return;
        _notifyPositionSync();
      });
    }
  }

  SpectrumUpdateMode get spectrumUpdateMode => _player.spectrumUpdateMode;

  void setSpectrumUpdateMode(SpectrumUpdateMode mode) {
    _player.setSpectrumUpdateMode(mode);
  }

  void _updateSmtcPosition() {
    _smtc.updateTimeProperties(progress: (position * 1000).round());
  }

  void _syncSmtcPositionTimer() {
    _updateSmtcPosition();
    if (playerState != PlayerState.playing) {
      _smtcPositionTimer?.cancel();
      _smtcPositionTimer = null;
      return;
    }
    _smtcPositionTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _updateSmtcPosition();
    });
  }

  Duration get nowPlayingChangeAge {
    final t = _lastNowPlayingChangedMs;
    if (t <= 0) return const Duration(days: 999);
    final now = DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: (now - t).clamp(0, 1 << 31));
  }

  bool get nowPlayingChangedRecently =>
      nowPlayingChangeAge.inMilliseconds < 220;

  void _loadAndPlay(int audioIndex, List<Audio> playlist) {
    try {
      _songChangeTaskToken++;
      _cancelSongChangeTasks();
      ThemeProvider.instance.cancelPendingAudioTheme();
      final token = _songChangeTaskToken;
      final audio = playlist[audioIndex];
      _playlistIndex = audioIndex;
      _nowPlaying.value = audio;
      _lastNowPlayingChangedMs = DateTime.now().millisecondsSinceEpoch;
      _resetListenAccumulator(audio.duration.toDouble());
      unawaited(audio.loadSmallCoverBytes());

      _player.setSource(audio.path);
      _eq.reapplyOutputGain();

      playService.lyricService.updateLyric();

      _player.start();
      _playerState.value = PlayerState.playing;
      _syncSmtcPositionTimer();
      _schedulePositionSyncBurst(token: token, path: audio.path);
      notifyListeners();

      _schedulePostSongChangeTasks(
        token: token,
        audio: audio,
        audioIndex: audioIndex,
        playlist: playlist,
      );
    } catch (err) {
      logger.e('[load and play] $err');
      showTextOnSnackBar(err.toString(), variant: ToastVariant.error);
    }
  }

  bool _isCurrentSongChangeTask(int token, Audio audio) {
    return token == _songChangeTaskToken && nowPlaying?.path == audio.path;
  }

  void _cancelSongChangeTasks() {
    _songChangeMetadataTimer?.cancel();
    _songChangeMetadataTimer = null;
    _songChangePrefetchTimer?.cancel();
    _songChangePrefetchTimer = null;
    _songChangePersistTimer?.cancel();
    _songChangePersistTimer = null;
    _songChangeCleanupTimer?.cancel();
    _songChangeCleanupTimer = null;
  }

  void _resetListenAccumulator(double durationSec) {
    _listenAccumulatedSec = 0;
    _listenLastPositionSec = 0;
    _listenRecorded = false;
    _thresholdSec = durationSec > 0 ? math.min(60.0, 0.9 * durationSec) : 0;
  }

  void _onPositionUpdate(double positionSec) {
    if (_closed || _listenRecorded || playerState != PlayerState.playing) {
      _listenLastPositionSec = positionSec;
      return;
    }
    if (_thresholdSec <= 0) return;

    final delta = positionSec - _listenLastPositionSec;
    _listenLastPositionSec = positionSec;
    if (delta <= 0 || delta > 2.0) return;

    _listenAccumulatedSec += delta;
    if (_listenAccumulatedSec >= _thresholdSec) {
      _recordListen();
    }
  }

  void _recordListen() {
    if (_listenRecorded) return;
    _listenRecorded = true;
    final audioPath = nowPlaying?.path;
    if (_supportPath == null || audioPath == null) return;
    rust_library_db.incrementPlayCount(indexPath: _supportPath!, path: audioPath);
  }

  void _schedulePostSongChangeTasks({
    required int token,
    required Audio audio,
    required int audioIndex,
    required List<Audio> playlist,
  }) {
    _songChangeMetadataTimer = Timer(const Duration(milliseconds: 96), () {
      _songChangeMetadataTimer = null;
      if (!_isCurrentSongChangeTask(token, audio)) return;

      _smtc.updateDisplay(
        title: audio.title,
        artist: audio.artist,
        album: audio.album,
        duration: audio.duration * 1000,
        path: audio.path,
      );
      _smtc.updateState(state: SMTCState.playing);
      _syncSmtcPositionTimer();

      playService.desktopLyricService.canSendMessage.then((canSend) {
        if (!_isCurrentSongChangeTask(token, audio)) return;
        if (!canSend) return;

        playService.desktopLyricService.sendPlayerStateMessage(
          playerState == PlayerState.playing,
        );
        playService.desktopLyricService.sendNowPlayingMessage(audio);
      });

      _readReplayGainFor(audio.path);
    });

    _songChangePrefetchTimer = Timer(const Duration(milliseconds: 220), () {
      _songChangePrefetchTimer = null;
      if (!_isCurrentSongChangeTask(token, audio)) return;

      ThemeProvider.instance.applyThemeFromAudio(audio);

      if (audioIndex + 1 < playlist.length) {
        final next = playlist[audioIndex + 1];
        CoverImageCache.instance.preload(next.path);
        playService.lyricService.prefetchLyric(next);
        if (audioIndex + 2 < playlist.length) {
          playService.lyricService.prefetchLyric(playlist[audioIndex + 2]);
        }
      }
    });

    _songChangePersistTimer = Timer(const Duration(milliseconds: 650), () {
      _songChangePersistTimer = null;
      if (!_isCurrentSongChangeTask(token, audio)) return;
      final currentIndex = _playlistIndex;
      if (currentIndex == null || _playlist.value.isEmpty) return;
      _persistLastSession(
        playlist: _playlist.value,
        playlistIndex: currentIndex,
        nowPlaying: audio,
      );
    });

    _songChangeCleanupTimer = Timer(const Duration(milliseconds: 1800), () {
      _songChangeCleanupTimer = null;
      if (!_isCurrentSongChangeTask(token, audio)) return;
      AudioLibrary.instance.evictAllCoversExcept(audio.path);
    });
  }

  /// 播放当前播放列表的第几项，只能用在播放列表界面
  void playIndexOfPlaylist(int audioIndex) {
    logger.i('[action] playIndexOfPlaylist=$audioIndex');
    AudioEchoLogRecorder.instance
        .mark('playIndexOfPlaylist', extra: {'index': audioIndex});
    _loadAndPlay(audioIndex, playlist.value);
  }

  /// 仅更新播放列表索引，不触发重新播放。用于拖拽排序等场景
  void setPlaylistIndex(int newIndex) {
    logger.i('[action] setPlaylistIndex=$newIndex');
    _playlistIndex = newIndex;
    _persistCurrentSession();
  }

  void reorderPlaylist(int oldIndex, int newIndex) {
    logger.i('[action] reorderPlaylist old=$oldIndex new=$newIndex');
    AudioEchoLogRecorder.instance.mark(
      'reorderPlaylist',
      extra: {'oldIndex': oldIndex, 'newIndex': newIndex},
    );
    if (oldIndex < 0 || oldIndex >= _playlist.value.length) return;
    if (newIndex < 0 || newIndex >= _playlist.value.length) return;

    final currentList = List<Audio>.from(_playlist.value);
    final item = currentList.removeAt(oldIndex);
    currentList.insert(newIndex, item);
    _playlist.value = currentList;
    if (!shuffle.value) {
      _playlistBackup = currentList;
    }

    final currentIndex = _playlistIndex;
    if (currentIndex != null) {
      if (currentIndex == oldIndex) {
        _playlistIndex = newIndex;
      } else if (oldIndex < currentIndex && newIndex >= currentIndex) {
        _playlistIndex = currentIndex - 1;
      } else if (oldIndex > currentIndex && newIndex <= currentIndex) {
        _playlistIndex = currentIndex + 1;
      }
    }

    _persistCurrentSession();
  }

  /// 播放 playlist[audioIndex] 并设置播放列表为 playlist
  void play(int audioIndex, List<Audio> playlist) {
    logger.i('[action] play index=$audioIndex playlistLen=${playlist.length}');
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
    logger.i('[action] shuffleAndPlay len=${audios.length}');
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
    logger.i('[action] addToNext path=${audio.path}');
    AudioEchoLogRecorder.instance
        .mark('addToNext', extra: {'path': audio.path});
    if (_playlistIndex != null) {
      _playlist.value = [..._playlist.value]
        ..insert(_playlistIndex! + 1, audio);
      if (shuffle.value) {
        final backup = List<Audio>.from(_playlistBackup);
        final current = nowPlaying;
        final insertIndex = current == null
            ? backup.length
            : backup.indexWhere((item) => item.path == current.path) + 1;
        backup.insert(insertIndex <= 0 ? backup.length : insertIndex, audio);
        _playlistBackup = backup;
      } else {
        _playlistBackup = _playlist.value;
      }
      if (nowPlaying != null) {
        _persistLastSession(
          playlist: _playlist.value,
          playlistIndex: _playlistIndex!,
          nowPlaying: nowPlaying!,
        );
      }
    }
  }

  /// 清空播放队列
  void clearQueue() {
    logger.i('[action] clearQueue');
    AudioEchoLogRecorder.instance.mark('clearQueue');
    _songChangeTaskToken++;
    _cancelSongChangeTasks();
    ThemeProvider.instance.cancelPendingAudioTheme();
    _player.pause();
    _playlist.value = [];
    _playlistBackup = [];
    _playlistIndex = null;
    _nowPlaying.value = null;
    _smtc.updateState(state: SMTCState.paused);
    _clearPersistedLastSession();
  }

  /// 从播放队列中移除指定索引的曲目
  void removeFromQueue(int index) {
    logger.i('[action] removeFromQueue index=$index');
    AudioEchoLogRecorder.instance
        .mark('removeFromQueue', extra: {'index': index});
    if (index < 0 || index >= _playlist.value.length) return;
    final removedAudio = _playlist.value[index];
    final wasPlaying = _playlistIndex == index;
    _playlist.value = [..._playlist.value]..removeAt(index);
    if (shuffle.value) {
      final backup = List<Audio>.from(_playlistBackup);
      final backupIndex =
          backup.indexWhere((audio) => audio.path == removedAudio.path);
      if (backupIndex >= 0) {
        backup.removeAt(backupIndex);
      }
      _playlistBackup = backup;
    } else {
      _playlistBackup = _playlist.value;
    }
    if (_playlistIndex != null) {
      if (_playlistIndex! > index) {
        _playlistIndex = _playlistIndex! - 1;
      } else if (wasPlaying) {
        // 正在播放的曲目被移除，停在当前位置或播放下一首
        if (_playlist.value.isEmpty) {
          _player.pause();
          _playlistIndex = null;
          _nowPlaying.value = null;
          _clearPersistedLastSession();
        } else if (_playlistIndex! < _playlist.value.length) {
          _loadAndPlay(_playlistIndex!, _playlist.value);
        }
      } else {
        _persistCurrentSession();
      }
    } else {
      _persistCurrentSession();
    }
  }

  void useShuffle(bool flag) {
    if (nowPlaying == null) return;
    if (flag == shuffle.value) return;
    logger.i('[action] useShuffle=$flag');
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
    _pref.lastShuffleActive = shuffle.value;
    _pref.lastOriginalPlaylistPaths =
        shuffle.value ? _playlistBackup.map((e) => e.path).toList() : const [];
    _savePlaybackOnly();
  }

  void _persistCurrentSession() {
    final currentIndex = _playlistIndex;
    final currentAudio = nowPlaying;
    if (currentIndex == null ||
        currentAudio == null ||
        _playlist.value.isEmpty) {
      _clearPersistedLastSession();
      return;
    }
    _persistLastSession(
      playlist: _playlist.value,
      playlistIndex: currentIndex.clamp(0, _playlist.value.length - 1),
      nowPlaying: currentAudio,
    );
  }

  void _clearPersistedLastSession() {
    _pref.lastAudioPath = '';
    _pref.lastPlaylistPaths = const [];
    _pref.lastPlaylistIndex = 0;
    _pref.lastShuffleActive = false;
    _pref.lastOriginalPlaylistPaths = const [];
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

    final restoredOriginalPlaylist = <Audio>[];
    for (final p in _pref.lastOriginalPlaylistPaths) {
      final a = pathToAudio[p];
      if (a != null) {
        restoredOriginalPlaylist.add(a);
      }
    }

    var restoredIndex = _pref.lastPlaylistIndex;
    restoredIndex = restoredIndex.clamp(0, restoredPlaylist.length - 1);
    final idxByPath = restoredPlaylist.indexWhere((e) => e.path == lastPath);
    if (idxByPath >= 0) {
      restoredIndex = idxByPath;
    }

    _playlist.value = restoredPlaylist;
    _playlistBackup = restoredOriginalPlaylist.isNotEmpty
        ? restoredOriginalPlaylist
        : restoredPlaylist;
    shuffle.value = _pref.lastShuffleActive;
    _playlistIndex = restoredIndex;
    _nowPlaying.value = restoredPlaylist[restoredIndex];
    _lastNowPlayingChangedMs = DateTime.now().millisecondsSinceEpoch;
    nowPlaying!.loadSmallCoverBytes();

    try {
      _player.setSource(nowPlaying!.path);
      _eq.reapplyOutputGain();
      playService.lyricService.updateLyric();
      ThemeProvider.instance.applyThemeFromAudio(nowPlaying!);

      _smtc.updateDisplay(
        title: nowPlaying!.title,
        artist: nowPlaying!.artist,
        album: nowPlaying!.album,
        duration: nowPlaying!.duration * 1000,
        path: nowPlaying!.path,
      );
      _smtc.updateState(state: SMTCState.paused);
      _syncSmtcPositionTimer();
    } catch (err) {
      logger.e('[restore last session] $err');
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
    logger.i('[action] nextAudio');
    AudioEchoLogRecorder.instance.mark('nextAudio');
    _nextAudioLoop();
  }

  /// 手动上一曲时默认循环播放列表
  void lastAudio() {
    logger.i('[action] lastAudio');
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
      logger.i('[action] pause');
      AudioEchoLogRecorder.instance.mark('pause');
      _player.pause();
      _smtc.updateState(state: SMTCState.paused);
      playService.desktopLyricService.canSendMessage.then((canSend) {
        if (!canSend) return;

        playService.desktopLyricService.sendPlayerStateMessage(false);
      });
    } catch (err) {
      logger.e('[pause] $err');
      showTextOnSnackBar(err.toString(), variant: ToastVariant.error);
    }
  }

  /// 恢复播放
  void start() {
    try {
      logger.i('[action] start');
      AudioEchoLogRecorder.instance.mark('start');
      _player.start();
      _smtc.updateState(state: SMTCState.playing);
      _schedulePositionSyncBurst();
      playService.desktopLyricService.canSendMessage.then((canSend) {
        if (!canSend) return;

        playService.desktopLyricService.sendPlayerStateMessage(true);
      });
    } catch (err) {
      logger.e('[start]: $err');
      showTextOnSnackBar(err.toString(), variant: ToastVariant.error);
    }
  }

  /// 再次播放。在顺序播放完最后一曲时再次按播放时使用。
  /// 与 [start] 的差别在于它会通知重绘组件
  void playAgain() => _nextAudioSingleLoop();

  void seek(double position) {
    logger.i('[action] seek=$position');
    AudioEchoLogRecorder.instance.mark('seek', extra: {'pos': position});
    _player.seek(position);
    _updateSmtcPosition();
    playService.lyricService.findCurrLyricLineAt(position);
    _schedulePositionSyncBurst();
  }

  Future<void> close() async {
    _closed = true;
    _songChangeTaskToken++;
    _cancelSongChangeTasks();

    // 1. 先停止音频播放（防止释放资源时仍有音频回调）
    try {
      _player.pause();
    } catch (_) {}

    // 2. 取消所有 Stream 订阅（在关闭 Controllers 之前）
    try {
      await _playerStateStreamSub.cancel();
    } catch (_) {}
    try {
      await _smtcEventStreamSub.cancel();
    } catch (_) {}
    try {
      await _listenStreamSub?.cancel();
    } catch (_) {}
    _smtcPositionTimer?.cancel();
    _smtcPositionTimer = null;

    // 4. 等待异步回调完全停止（避免 use-after-free）
    await Future.delayed(const Duration(milliseconds: 100));

    // 5. 关闭 SMTC（系统媒体传输控制）
    try {
      _smtc.updateState(state: SMTCState.paused);
      await Future.delayed(const Duration(milliseconds: 50));
      await _smtc
          .close()
          .timeout(const Duration(milliseconds: 500))
          .catchError((_) {});
    } catch (_) {}

    // 6. dispose ValueNotifiers（释放 _playlist 引用的 Audio 列表）
    try {
      _wasapiExclusive.dispose();
    } catch (_) {}
    try {
      _nowPlaying.dispose();
    } catch (_) {}
    try {
      _playlist.value = [];
      _playlist.dispose();
    } catch (_) {}
    try {
      _playMode.dispose();
    } catch (_) {}
    try {
      _pitch.dispose();
    } catch (_) {}
    try {
      _rate.dispose();
    } catch (_) {}
    try {
      _shuffle.dispose();
    } catch (_) {}
    try {
      _playerState.dispose();
    } catch (_) {}
    try {
      _positionSyncRevision.dispose();
    } catch (_) {}

    // 7. 最后释放 BASS 音频资源（此时所有回调和订阅已停止）
    try {
      _player.free();
    } catch (e) {
      logger.w('_player.free error: $e');
    }
  }
}
