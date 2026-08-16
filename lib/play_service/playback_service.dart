import 'dart:async';
import 'dart:math' as math;

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/play_service/equalizer_service.dart';
import 'package:pure_music/play_service/smart_transition_coordinator.dart';
import 'package:pure_music/play_service/smtc_bridge.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart' as rust_tag_reader;
import 'package:pure_music/native/rust/api/library_db.dart' as rust_library_db;
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/settings.dart';
import 'package:flutter/foundation.dart';

final class _PendingGaplessTransition {
  const _PendingGaplessTransition({
    required this.id,
    required this.playlistRevision,
    required this.fromIndex,
    required this.targetIndex,
    required this.audio,
  });

  final int id;
  final int playlistRevision;
  final int fromIndex;
  final int targetIndex;
  final Audio audio;
}

/// 只通知 now playing 变更
class PlaybackService extends ChangeNotifier {
  final PlayService playService;

  late StreamSubscription _playerStateStreamSub;
  late StreamSubscription<GaplessTransition> _gaplessTransitionStreamSub;
  late StreamSubscription _smtcEventStreamSub;
  late StreamSubscription _smtcPositionChangeStreamSub;
  int _lastNowPlayingChangedMs = 0;
  Timer? _smtcPositionTimer;
  Timer? _smtcKeepAliveTimer;
  final Set<Timer> _positionSyncBurstTimers = {};
  int _songChangeTaskToken = 0;
  Timer? _songChangeMetadataTimer;
  Timer? _songChangePrefetchTimer;
  Timer? _songChangePersistTimer;
  Timer? _songChangeCleanupTimer;
  double _listenAccumulatedSec = 0;
  double _listenLastPositionSec = 0;
  double _thresholdSec = 0;
  bool _listenRecorded = false;
  int _listenSessionToken = 0;
  int? _listenRecordingToken;
  String? _supportPath;
  bool _closed = false;
  int _playlistRevision = 0;
  int _nextGaplessTransitionId = 1;
  _PendingGaplessTransition? _pendingGaplessTransition;
  int _replayGainRequestToken = 0;
  late final SmartTransitionCoordinator _smartTransitions;

  final _playCountRevision = ValueNotifier<int>(0);
  int _smtcDisplayRevision = 0;

  ValueListenable<int> get playCountRevision => _playCountRevision;

  PlaybackService(this.playService) {
    _player.onExclusiveModeChanged = (exclusive) {
      _wasapiExclusive.value = exclusive;
      _rebuildGaplessPreparation();
    };

    _playerStateStreamSub = playerStateStream.listen((event) {
      var shouldAutoAdvance = false;
      if (event == PlayerState.completed) {
        _updateSmtcPosition();
        shouldAutoAdvance = !_smartTransitions.handlePlayerCompleted();
      }
      _playerState.value = event;
      _notifyPositionSync();
      _syncSmtcPositionTimer();
      if (event == PlayerState.completed && shouldAutoAdvance) {
        _autoNextAudio();
      }
    });
    _gaplessTransitionStreamSub = _player.gaplessTransitionStream.listen(
      _onGaplessTransition,
    );

    _smtcEventStreamSub = _smtc.controlEvents.listen((event) {
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
          seek(0);
          break;
        case SMTCControlEvent.unknown:
      }
    });
    _smtcPositionChangeStreamSub = _smtc.positionChangeEvents.listen((
      position,
    ) {
      final audio = nowPlaying;
      if (_closed || audio == null) return;
      final positionSeconds = (position / 1000).clamp(
        0.0,
        audio.duration.toDouble(),
      );
      seek(positionSeconds);
    });

    _eq = EqualizerService(_player, _pref);
    _smartTransitions = SmartTransitionCoordinator(
      player: _player,
      readLibraryRoot: () async =>
          _supportPath ??= (await getAppDataDir()).path,
      readTarget: _currentSmartTarget,
      validateTarget: _isCurrentSmartTarget,
      nextTransitionId: () => _nextGaplessTransitionId++,
      readReplayGain: (audio) => _readReplayGain(audio.path),
      commitTransition: _onSmartTransitionCommit,
      prepareFallback: _prepareSmartFallback,
      prepareAfterCompletion: _rebuildGaplessPreparation,
    );

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
  final _smtc = SmtcBridge.create();
  final _pref = AppPreference.instance.playbackPref;
  late final EqualizerService _eq;

  bool get isBassFxLoaded => _player.isBassFxLoaded;
  String get bassDebugStateLine => _player.debugStateLine;
  Map<String, Object?> get smartTransitionDiagnostics =>
      _smartTransitions.diagnostics;

  // EQ 相关方法委托给 EqualizerService
  List<double> get eqGains => _eq.eqGains;
  List<EqPreset> get eqPresets => _eq.eqPresets;
  double get eqPreampDb => _eq.eqPreampDb;
  bool get eqAutoGainEnabled => _eq.eqAutoGainEnabled;
  double get eqAutoHeadroomDb => _eq.eqAutoHeadroomDb;
  double get eqAutoGainDb => _eq.eqAutoGainDb;

  void refreshEQ() => _eq.refreshEQ();

  void setEQ(int band, double gain) {
    _synchronizeGaplessTransition();
    _eq.setEQ(band, gain);
    _rebuildGaplessPreparation();
  }

  void setEqPreampDb(double value) {
    _synchronizeGaplessTransition();
    _eq.setEqPreampDb(value);
    _rebuildGaplessPreparation();
  }

  void setEqAutoGainEnabled(bool enabled) {
    _synchronizeGaplessTransition();
    _eq.setEqAutoGainEnabled(enabled);
    _rebuildGaplessPreparation();
  }

  ValueNotifier<bool> get replayGainEnabled => _replayGainEnabled;
  late final _replayGainEnabled = ValueNotifier(_pref.replayGainEnabled);

  void setReplayGainEnabled(bool enabled) {
    _synchronizeGaplessTransition();
    _pref.replayGainEnabled = enabled;
    _replayGainEnabled.value = enabled;
    if (enabled) {
      final curr = nowPlaying;
      if (curr != null) _loadCurrentReplayGain(curr);
    } else {
      _replayGainRequestToken++;
      _player.replayGainDb = null;
      _eq.reapplyOutputGain();
    }
    _rebuildGaplessPreparation();
  }

  Future<bool> saveEqPreset(String name) => _eq.saveEqPreset(name);
  Future<bool> removeEqPreset(String name) => _eq.removeEqPreset(name);
  Future<bool> applyEqPreset(EqPreset preset) async {
    _synchronizeGaplessTransition();
    final applied = await _eq.applyEqPreset(preset);
    _rebuildGaplessPreparation();
    return applied;
  }

  void reapplyOutputGain() => _eq.reapplyOutputGain();

  Future<double?> _readReplayGain(String path) async {
    if (!_pref.replayGainEnabled) return null;
    try {
      final meta = await rust_tag_reader.readAudioExtraMetadata(path: path);
      final raw = meta.replaygainTrackGain;
      if (raw == null || raw.isEmpty) return null;
      return double.tryParse(raw.replaceAll('dB', '').trim());
    } catch (_) {
      return null;
    }
  }

  void _loadCurrentReplayGain(Audio audio) {
    final requestToken = ++_replayGainRequestToken;
    _player.replayGainDb = null;
    if (!_pref.replayGainEnabled) return;
    unawaited(
      _readReplayGain(audio.path).then((gainDb) {
        if (_closed || requestToken != _replayGainRequestToken) return;
        if (nowPlaying != audio) return;
        if (_pref.transitionMode == TransitionMode.smart) {
          _synchronizeGaplessTransition();
        }
        _player.replayGainDb = gainDb;
        if (_pref.transitionMode == TransitionMode.smart) {
          _rebuildGaplessPreparation();
        }
      }),
    );
  }

  void savePreference() {
    AppPreference.instance.save();
  }

  void refreshTransitionPreparation() {
    _rebuildGaplessPreparation();
  }

  void _savePlaybackOnly() {
    AppPreference.instance.savePlaybackOnly();
  }

  late final _wasapiExclusive = ValueNotifier(_player.wasapiExclusive);
  ValueNotifier<bool> get wasapiExclusive => _wasapiExclusive;

  /// 独占模式
  void useExclusiveMode(bool exclusive) {
    logger.i('[action] useExclusiveMode=$exclusive');
    AudioEchoLogRecorder.instance.mark(
      'useExclusiveMode',
      extra: {'exclusive': exclusive},
    );
    _synchronizeGaplessTransition();
    if (_player.useExclusiveMode(exclusive)) {
      _wasapiExclusive.value = exclusive;
    }
  }

  late final _nowPlaying = ValueNotifier<Audio?>(null);
  ValueNotifier<Audio?> get nowPlayingNotifier => _nowPlaying;
  Audio? get nowPlaying => _nowPlaying.value;

  int? _playlistIndex;
  int get playlistIndex => _playlistIndex ?? 0;

  late final _playlist = ValueNotifier<List<Audio>>(const []);
  ValueNotifier<List<Audio>> get playlistNotifier => _playlist;
  ValueNotifier<List<Audio>> get playlist => _playlist;
  List<Audio> _playlistBackup = const [];

  late final _playMode = ValueNotifier(_pref.playMode);
  ValueNotifier<PlayMode> get playMode => _playMode;

  void setPlayMode(PlayMode playMode) {
    this.playMode.value = playMode;
    _pref.playMode = playMode;
    _savePlaybackOnly();
    _rebuildGaplessPreparation();
  }

  late final _pitch = ValueNotifier(0.0);
  ValueNotifier<double> get pitch => _pitch;

  void setPitch(double value) {
    logger.i('[action] setPitch=$value');
    AudioEchoLogRecorder.instance.mark('setPitch', extra: {'value': value});
    _synchronizeGaplessTransition();
    _pitch.value = value;
    _player.setPitch(value);
    _rebuildGaplessPreparation();
  }

  late final _rate = ValueNotifier(1.0);
  ValueNotifier<double> get rate => _rate;

  void setRate(double value) {
    logger.i('[action] setRate=$value');
    AudioEchoLogRecorder.instance.mark('setRate', extra: {'value': value});
    _synchronizeGaplessTransition();
    _rate.value = value;
    _player.setRate(value);
    _rebuildGaplessPreparation();
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

  int get sourceGeneration => _player.sourceGeneration;

  double get position => _player.position;

  double get volumeDsp => _player.volumeDsp;

  /// 修改解码时的音量（不影响 Windows 系统音量）
  void setVolumeDsp(double volume) {
    logger.i('[action] setVolumeDsp=$volume');
    AudioEchoLogRecorder.instance.mark(
      'setVolumeDsp',
      extra: {'value': volume},
    );
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

  void _schedulePositionSyncBurst({int? token, String? path}) {
    _cancelPositionSyncBurst();
    _notifyPositionSync();
    const delays = [
      Duration(milliseconds: 16),
      Duration(milliseconds: 80),
      Duration(milliseconds: 180),
      Duration(milliseconds: 360),
    ];
    for (final delay in delays) {
      late final Timer timer;
      timer = Timer(delay, () {
        _positionSyncBurstTimers.remove(timer);
        if (_closed) return;
        if (token != null && token != _songChangeTaskToken) return;
        if (path != null && nowPlaying?.path != path) return;
        _notifyPositionSync();
      });
      _positionSyncBurstTimers.add(timer);
    }
  }

  void _cancelPositionSyncBurst() {
    for (final timer in _positionSyncBurstTimers) {
      timer.cancel();
    }
    _positionSyncBurstTimers.clear();
  }

  SpectrumUpdateMode get spectrumUpdateMode => _player.spectrumUpdateMode;

  void setSpectrumUpdateMode(SpectrumUpdateMode mode) {
    _player.setSpectrumUpdateMode(mode);
  }

  void _updateSmtcPosition() {
    if (_closed) return;
    final currentPosition = position;
    _onPositionUpdate(currentPosition);
    _smartTransitions.onPositionTick(currentPosition, length);
    final progress = (currentPosition * 1000).round();
    unawaited(_smtc.updateTimeProperties(progress));
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

  /// 窗口最小化期间系统会冻结媒体会话的显示更新（普通 Update 被静默丢弃，
  /// 只有媒体栏按钮交互才强制刷新）。用周期心跳重推当前曲目，模拟会话活跃。
  void startSmtcKeepAlive() {
    if (_closed || _smtcKeepAliveTimer != null) return;
    _smtcKeepAliveTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _pushSmtcKeepAlive();
    });
  }

  void stopSmtcKeepAlive() {
    _smtcKeepAliveTimer?.cancel();
    _smtcKeepAliveTimer = null;
  }

  void _pushSmtcKeepAlive() {
    if (_closed) return;
    final audio = nowPlaying;
    if (audio == null) return;
    unawaited(_smtc.refreshDisplay());
    unawaited(
      _smtc.updateState(
        playerState == PlayerState.playing
            ? SMTCState.playing
            : SMTCState.paused,
      ),
    );
    _updateSmtcPosition();
  }

  Future<void> _clearSmtcDisplay() async {
    final revision = ++_smtcDisplayRevision;
    await _smtc.clearDisplay();
    if (_closed || revision != _smtcDisplayRevision) return;
    final audio = nowPlaying;
    if (audio == null) return;
    await _smtc.updateDisplay(
      title: audio.title,
      artist: audio.artist,
      album: audio.album,
      duration: audio.duration * 1000,
      path: audio.path,
    );
    await _smtc.updateState(
      playerState == PlayerState.playing ? SMTCState.playing : SMTCState.paused,
    );
    _updateSmtcPosition();
  }

  Duration get nowPlayingChangeAge {
    final t = _lastNowPlayingChangedMs;
    if (t <= 0) return const Duration(days: 999);
    final now = DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: (now - t).clamp(0, 1 << 31));
  }

  bool get nowPlayingChangedRecently =>
      nowPlayingChangeAge.inMilliseconds < 220;

  List<Audio> _setPlaylist(Iterable<Audio> value) {
    _synchronizeGaplessTransition();
    final snapshot = List<Audio>.unmodifiable(value);
    _playlist.value = snapshot;
    _playlistRevision++;
    _invalidateGaplessPreparation();
    return snapshot;
  }

  void _setPlaylistBackup(Iterable<Audio> value) {
    _playlistBackup = List<Audio>.unmodifiable(value);
  }

  bool _invalidateGaplessPreparation() {
    final transitioned = _synchronizeGaplessTransition();
    if (!transitioned) _pendingGaplessTransition = null;
    return transitioned;
  }

  bool _synchronizeGaplessTransition() {
    final smartTransitioned = _smartTransitions.cancel(
      'playback_state_changed',
    );
    final transition = _player.clearGaplessSource();
    if (transition != null) {
      _onGaplessTransition(transition);
    }
    return smartTransitioned || transition != null;
  }

  int? _automaticNextIndex() {
    final currentIndex = _playlistIndex;
    final items = _playlist.value;
    if (currentIndex == null || items.isEmpty) return null;
    return switch (playMode.value) {
      PlayMode.forward || PlayMode.loop => (currentIndex + 1) % items.length,
      PlayMode.singleLoop => currentIndex,
    };
  }

  SmartTransitionTarget? _currentSmartTarget() {
    if (_closed ||
        _pref.transitionMode != TransitionMode.smart ||
        _player.playerState != PlayerState.playing) {
      return null;
    }
    final outgoingIndex = _playlistIndex;
    final incomingIndex = _automaticNextIndex();
    final outgoing = nowPlaying;
    final items = _playlist.value;
    if (outgoingIndex == null ||
        incomingIndex == null ||
        outgoing == null ||
        outgoingIndex < 0 ||
        incomingIndex < 0 ||
        outgoingIndex >= items.length ||
        incomingIndex >= items.length ||
        !identical(items[outgoingIndex], outgoing)) {
      return null;
    }
    final incoming = items[incomingIndex];
    return SmartTransitionTarget(
      playlistRevision: _playlistRevision,
      outgoingIndex: outgoingIndex,
      incomingIndex: incomingIndex,
      outgoing: outgoing,
      incoming: incoming,
      isGaplessCandidate: false,
      userSpeed: _rate.value,
      pitch: _pitch.value,
      outgoingReplayGainDb: _player.replayGainDb,
    );
  }

  bool _isCurrentSmartTarget(SmartTransitionTarget target) {
    final items = _playlist.value;
    return !_closed &&
        _pref.transitionMode == TransitionMode.smart &&
        target.playlistRevision == _playlistRevision &&
        _playlistIndex == target.outgoingIndex &&
        target.outgoingIndex >= 0 &&
        target.incomingIndex >= 0 &&
        target.outgoingIndex < items.length &&
        target.incomingIndex < items.length &&
        identical(items[target.outgoingIndex], target.outgoing) &&
        identical(items[target.incomingIndex], target.incoming) &&
        identical(nowPlaying, target.outgoing) &&
        _rate.value == target.userSpeed &&
        _pitch.value == target.pitch;
  }

  bool _prepareSmartFallback(SmartTransitionTarget target, String reason) {
    if (!_isCurrentSmartTarget(target)) return false;
    final pending = _PendingGaplessTransition(
      id: _nextGaplessTransitionId++,
      playlistRevision: target.playlistRevision,
      fromIndex: target.outgoingIndex,
      targetIndex: target.incomingIndex,
      audio: target.incoming,
    );
    _pendingGaplessTransition = pending;
    final prepared = _player.prepareGaplessSource(
      target.incoming.path,
      transitionId: pending.id,
      transitionMode: TransitionMode.crossfade,
    );
    logger.i(
      '[smart transition] simple crossfade fallback '
      'prepared=$prepared reason=$reason',
    );
    if (!prepared) {
      _pendingGaplessTransition = null;
      return false;
    }
    if (_pref.replayGainEnabled) {
      unawaited(
        _readReplayGain(target.incoming.path).then((gainDb) {
          if (_closed || !_pref.replayGainEnabled) return;
          _player.updateGaplessReplayGain(pending.id, gainDb);
        }),
      );
    }
    return true;
  }

  void _onSmartTransitionCommit(SmartTransitionCommit commit) {
    if (_closed || !_isCurrentSmartTarget(commit.target)) return;
    final previousAudio = nowPlaying;
    if (previousAudio != null) {
      _onPositionUpdate(previousAudio.duration.toDouble());
    }
    _commitSongChange(
      audioIndex: commit.target.incomingIndex,
      playlist: _playlist.value,
      audio: commit.target.incoming,
      replayGainDb: commit.transition.replayGainDb,
      alreadyPlaying: true,
      state: _player.playerState,
      rebuildTransitionPreparation: false,
    );
  }

  void _rebuildGaplessPreparation() {
    if (_invalidateGaplessPreparation()) return;
    if (_pref.transitionMode == TransitionMode.smart) {
      if (!_closed) _smartTransitions.rebuild();
      return;
    }
    if (_closed || !_player.canUseGaplessPlayback) return;
    final fromIndex = _playlistIndex;
    final targetIndex = _automaticNextIndex();
    if (fromIndex == null || targetIndex == null) return;
    final items = _playlist.value;
    if (fromIndex < 0 ||
        targetIndex < 0 ||
        fromIndex >= items.length ||
        targetIndex >= items.length) {
      return;
    }

    final audio = items[targetIndex];
    final pending = _PendingGaplessTransition(
      id: _nextGaplessTransitionId++,
      playlistRevision: _playlistRevision,
      fromIndex: fromIndex,
      targetIndex: targetIndex,
      audio: audio,
    );
    _pendingGaplessTransition = pending;
    if (!_player.prepareGaplessSource(audio.path, transitionId: pending.id)) {
      _pendingGaplessTransition = null;
      return;
    }
    if (!_pref.replayGainEnabled) return;
    unawaited(
      _readReplayGain(audio.path).then((gainDb) {
        if (_closed || !_pref.replayGainEnabled) return;
        _player.updateGaplessReplayGain(pending.id, gainDb);
      }),
    );
  }

  void _onGaplessTransition(GaplessTransition event) {
    _player.acknowledgeGaplessTransition(event.id);
    if (_closed) return;
    final pending = _pendingGaplessTransition;
    if (pending == null || event.id != pending.id) return;
    final items = _playlist.value;
    if (pending.playlistRevision != _playlistRevision ||
        _playlistIndex != pending.fromIndex ||
        pending.targetIndex >= items.length ||
        !identical(items[pending.targetIndex], pending.audio)) {
      _pendingGaplessTransition = null;
      _loadAndPlayInDirection(
        startIndex: (_playlistIndex ?? -1) + 1,
        playlist: items,
        step: 1,
        wrap: true,
      );
      return;
    }

    _pendingGaplessTransition = null;
    final previousAudio = nowPlaying;
    if (previousAudio != null) {
      _onPositionUpdate(previousAudio.duration.toDouble());
    }
    _commitSongChange(
      audioIndex: pending.targetIndex,
      playlist: items,
      audio: pending.audio,
      replayGainDb: _player.replayGainDb,
      alreadyPlaying: true,
      state: _player.playerState,
    );
  }

  void _commitSongChange({
    required int audioIndex,
    required List<Audio> playlist,
    required Audio audio,
    double? replayGainDb,
    bool alreadyPlaying = false,
    PlayerState state = PlayerState.playing,
    bool rebuildTransitionPreparation = true,
  }) {
    _smtcDisplayRevision++;
    _songChangeTaskToken++;
    _replayGainRequestToken++;
    _cancelSongChangeTasks();
    ThemeProvider.instance.cancelPendingAudioTheme();
    final token = _songChangeTaskToken;

    _playlistIndex = audioIndex;
    _nowPlaying.value = audio;
    _lastNowPlayingChangedMs = DateTime.now().millisecondsSinceEpoch;
    _resetListenAccumulator(audio.duration.toDouble());
    unawaited(audio.loadSmallCoverBytes());
    playService.lyricService.updateLyric();

    _playerState.value = state;
    unawaited(
      _smtc.updateDisplay(
        title: audio.title,
        artist: audio.artist,
        album: audio.album,
        duration: audio.duration * 1000,
        path: audio.path,
      ),
    );
    unawaited(
      _smtc.updateState(
        state == PlayerState.playing ? SMTCState.playing : SMTCState.paused,
      ),
    );
    _syncSmtcPositionTimer();
    _schedulePositionSyncBurst(token: token, path: audio.path);
    notifyListeners();

    if (alreadyPlaying) {
      _player.replayGainDb = replayGainDb;
      if (replayGainDb == null) {
        _loadCurrentReplayGain(audio);
      }
    } else {
      _loadCurrentReplayGain(audio);
    }
    _schedulePostSongChangeTasks(
      token: token,
      audio: audio,
      audioIndex: audioIndex,
      playlist: playlist,
    );
    if (rebuildTransitionPreparation) {
      _rebuildGaplessPreparation();
    }
  }

  bool _loadAndPlay(
    int audioIndex,
    List<Audio> playlist, {
    bool reportFailure = true,
  }) {
    if (audioIndex < 0 || audioIndex >= playlist.length) return false;
    final audio = playlist[audioIndex];
    _invalidateGaplessPreparation();
    try {
      _player.setSource(audio.path);
      _eq.reapplyOutputGain();
      _player.start();
      _commitSongChange(
        audioIndex: audioIndex,
        playlist: playlist,
        audio: audio,
      );
      return true;
    } catch (err, trace) {
      logger.e(
        '加载并播放歌曲失败 index=$audioIndex title=${audio.title}',
        error: err,
        stackTrace: trace,
      );
      if (reportFailure) {
        _reportPlaybackLoadFailure('播放失败，请查看日志');
      }
      return false;
    }
  }

  bool _loadAndPlayInDirection({
    required int startIndex,
    required List<Audio> playlist,
    required int step,
    required bool wrap,
  }) {
    if (playlist.isEmpty || step == 0) return false;

    var index = startIndex;
    var attempts = 0;
    while (attempts < playlist.length) {
      if (index < 0 || index >= playlist.length) {
        if (!wrap) break;
        index = (index % playlist.length + playlist.length) % playlist.length;
      }
      if (_loadAndPlay(index, playlist, reportFailure: false)) return true;
      attempts++;
      index += step;
    }

    if (attempts > 0) {
      _reportPlaybackLoadFailure('播放列表中没有可播放的歌曲');
    }
    return false;
  }

  void _reportPlaybackLoadFailure(String message) {
    _playerState.value = PlayerState.stopped;
    _syncSmtcPositionTimer();
    _notifyPositionSync();
    unawaited(_smtc.updateState(SMTCState.paused));
    notifyListeners();
    showTextOnSnackBar(message, variant: ToastVariant.error);
  }

  bool _isCurrentSongChangeTask(int token, Audio audio) {
    return token == _songChangeTaskToken && identical(nowPlaying, audio);
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
    _listenSessionToken++;
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
      unawaited(_recordListen());
    }
  }

  Future<void> _recordListen() async {
    if (_listenRecorded) return;
    final audio = nowPlaying;
    if (audio == null) return;
    final audioPath = audio.path;

    final sessionToken = _listenSessionToken;
    if (_listenRecordingToken == sessionToken) return;
    _listenRecordingToken = sessionToken;

    try {
      final supportPath = _supportPath ??= (await getAppDataDir()).path;
      await rust_library_db.incrementPlayCount(
        indexPath: supportPath,
        path: audioPath,
      );
      audio.playCount++;
      if (sessionToken == _listenSessionToken) {
        _listenRecorded = true;
      }
      if (!_closed) _playCountRevision.value++;
    } catch (err, trace) {
      logger.w('记录播放次数失败', error: err, stackTrace: trace);
    } finally {
      if (_listenRecordingToken == sessionToken) {
        _listenRecordingToken = null;
      }
    }
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

      _syncSmtcPositionTimer();

      playService.desktopLyricService.canSendMessage.then((canSend) {
        if (!_isCurrentSongChangeTask(token, audio)) return;
        if (!canSend) return;

        playService.desktopLyricService.sendPlayerStateMessage(
          playerState == PlayerState.playing,
        );
        playService.desktopLyricService.sendNowPlayingMessage(audio);
      });
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
      AudioLibrary.instance.evictStaleCoverBytes();
    });
  }

  /// 播放当前播放列表的第几项，只能用在播放列表界面
  void playIndexOfPlaylist(int audioIndex) {
    logger.i('[action] playIndexOfPlaylist=$audioIndex');
    AudioEchoLogRecorder.instance.mark(
      'playIndexOfPlaylist',
      extra: {'index': audioIndex},
    );
    _loadAndPlay(audioIndex, playlist.value);
  }

  /// 仅更新播放列表索引，不触发重新播放。用于拖拽排序等场景
  void setPlaylistIndex(int newIndex) {
    logger.i('[action] setPlaylistIndex=$newIndex');
    if (newIndex < 0 || newIndex >= _playlist.value.length) return;
    _synchronizeGaplessTransition();
    _playlistIndex = newIndex;
    _persistCurrentSession();
    _rebuildGaplessPreparation();
  }

  void reorderPlaylist(int oldIndex, int newIndex) {
    logger.i('[action] reorderPlaylist old=$oldIndex new=$newIndex');
    AudioEchoLogRecorder.instance.mark(
      'reorderPlaylist',
      extra: {'oldIndex': oldIndex, 'newIndex': newIndex},
    );
    if (oldIndex < 0 || oldIndex >= _playlist.value.length) return;
    if (newIndex < 0 || newIndex >= _playlist.value.length) return;
    _synchronizeGaplessTransition();

    final currentList = List<Audio>.from(_playlist.value);
    final item = currentList.removeAt(oldIndex);
    currentList.insert(newIndex, item);
    _setPlaylist(currentList);
    if (!shuffle.value) {
      _setPlaylistBackup(currentList);
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
    _rebuildGaplessPreparation();
  }

  /// 播放 playlist[audioIndex] 并设置播放列表为 playlist
  void play(int audioIndex, List<Audio> playlist) {
    logger.i('[action] play index=$audioIndex playlistLen=${playlist.length}');
    AudioEchoLogRecorder.instance.mark(
      'play',
      extra: {'index': audioIndex, 'playlistLen': playlist.length},
    );
    if (audioIndex < 0 || audioIndex >= playlist.length) return;
    _synchronizeGaplessTransition();
    if (shuffle.value) {
      final shuffled = List<Audio>.from(playlist);
      final willPlay = shuffled.removeAt(audioIndex);
      shuffled.shuffle();
      shuffled.insert(0, willPlay);
      _setPlaylistBackup(playlist);
      final activePlaylist = _setPlaylist(shuffled);
      _loadAndPlay(0, activePlaylist);
    } else {
      _setPlaylistBackup(playlist);
      final activePlaylist = _setPlaylist(playlist);
      _loadAndPlay(audioIndex, activePlaylist);
    }
  }

  void shuffleAndPlay(List<Audio> audios) {
    logger.i('[action] shuffleAndPlay len=${audios.length}');
    AudioEchoLogRecorder.instance.mark(
      'shuffleAndPlay',
      extra: {'len': audios.length},
    );
    if (audios.isEmpty) return;
    _synchronizeGaplessTransition();
    final shuffled = List<Audio>.from(audios);
    shuffled.shuffle();
    final activePlaylist = _setPlaylist(shuffled);
    _setPlaylistBackup(audios);

    setPlayMode(PlayMode.forward);
    shuffle.value = true;

    _loadAndPlay(0, activePlaylist);
  }

  /// 下一首播放
  void addToNext(Audio audio) {
    logger.i('[action] addToNext');
    AudioEchoLogRecorder.instance.mark('addToNext');
    if (_playlistIndex == null) return;
    _synchronizeGaplessTransition();
    final nextList = [..._playlist.value]..insert(_playlistIndex! + 1, audio);
    _setPlaylist(nextList);
    if (shuffle.value) {
      final backup = List<Audio>.from(_playlistBackup);
      final current = nowPlaying;
      final insertIndex = current == null
          ? backup.length
          : backup.indexWhere((item) => item.path == current.path) + 1;
      backup.insert(insertIndex <= 0 ? backup.length : insertIndex, audio);
      _setPlaylistBackup(backup);
    } else {
      _setPlaylistBackup(_playlist.value);
    }
    if (nowPlaying != null) {
      _persistLastSession(
        playlist: _playlist.value,
        playlistIndex: _playlistIndex!,
        nowPlaying: nowPlaying!,
      );
    }
    _rebuildGaplessPreparation();
  }

  /// 清空播放队列
  void clearQueue() {
    logger.i('[action] clearQueue');
    AudioEchoLogRecorder.instance.mark('clearQueue');
    _synchronizeGaplessTransition();
    _songChangeTaskToken++;
    _cancelSongChangeTasks();
    ThemeProvider.instance.cancelPendingAudioTheme();
    _player.pause();
    _setPlaylist([]);
    _playlistBackup = const [];
    _playlistIndex = null;
    _nowPlaying.value = null;
    unawaited(_clearSmtcDisplay());
    _clearPersistedLastSession();
  }

  /// 从播放队列中移除指定索引的曲目
  void removeFromQueue(int index) {
    logger.i('[action] removeFromQueue index=$index');
    AudioEchoLogRecorder.instance.mark(
      'removeFromQueue',
      extra: {'index': index},
    );
    if (index < 0 || index >= _playlist.value.length) return;
    _synchronizeGaplessTransition();
    final removedAudio = _playlist.value[index];
    final wasPlaying = _playlistIndex == index;
    _setPlaylist([..._playlist.value]..removeAt(index));
    if (shuffle.value) {
      final backup = List<Audio>.from(_playlistBackup);
      final backupIndex = backup.indexWhere(
        (audio) => audio.path == removedAudio.path,
      );
      if (backupIndex >= 0) {
        backup.removeAt(backupIndex);
      }
      _setPlaylistBackup(backup);
    } else {
      _setPlaylistBackup(_playlist.value);
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
          unawaited(_clearSmtcDisplay());
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
    _rebuildGaplessPreparation();
  }

  void useShuffle(bool flag) {
    if (nowPlaying == null) return;
    if (flag == shuffle.value) return;
    _synchronizeGaplessTransition();
    logger.i('[action] useShuffle=$flag');
    AudioEchoLogRecorder.instance.mark('useShuffle', extra: {'flag': flag});

    if (flag) {
      final shuffled = [..._playlist.value]
        ..remove(nowPlaying!)
        ..shuffle()
        ..insert(0, nowPlaying!);
      _setPlaylist(shuffled);
      _playlistIndex = 0;
      shuffle.value = true;
      setPlayMode(PlayMode.forward);
    } else {
      _setPlaylist(_playlistBackup);
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
    _rebuildGaplessPreparation();
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
    _pref.lastOriginalPlaylistPaths = shuffle.value
        ? _playlistBackup.map((e) => e.path).toList()
        : const [];
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

    _setPlaylist(restoredPlaylist);
    _setPlaylistBackup(
      restoredOriginalPlaylist.isNotEmpty
          ? restoredOriginalPlaylist
          : restoredPlaylist,
    );
    shuffle.value = _pref.lastShuffleActive;
    _playlistIndex = restoredIndex;
    _nowPlaying.value = restoredPlaylist[restoredIndex];
    _smtcDisplayRevision++;
    _lastNowPlayingChangedMs = DateTime.now().millisecondsSinceEpoch;
    nowPlaying!.loadSmallCoverBytes();

    try {
      _player.setSource(nowPlaying!.path);
      _eq.reapplyOutputGain();
      _loadCurrentReplayGain(nowPlaying!);
      playService.lyricService.updateLyric();
      ThemeProvider.instance.applyThemeFromAudio(nowPlaying!);

      final restoredAudio = nowPlaying!;
      await _smtc.updateDisplay(
        title: restoredAudio.title,
        artist: restoredAudio.artist,
        album: restoredAudio.album,
        duration: restoredAudio.duration * 1000,
        path: restoredAudio.path,
      );
      await _smtc.updateState(SMTCState.paused);
      _syncSmtcPositionTimer();
      _rebuildGaplessPreparation();
    } catch (err) {
      logger.e('[restore last session] $err');
    }
  }

  void _nextAudioLoop() {
    if (_playlistIndex == null) return;
    _synchronizeGaplessTransition();

    _loadAndPlayInDirection(
      startIndex: _playlistIndex! + 1,
      playlist: _playlist.value,
      step: 1,
      wrap: true,
    );
  }

  void _nextAudioSingleLoop() {
    if (_playlistIndex == null) return;
    _synchronizeGaplessTransition();

    _loadAndPlay(_playlistIndex!, _playlist.value);
  }

  void _autoNextAudio() {
    switch (playMode.value) {
      case PlayMode.forward:
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
    _synchronizeGaplessTransition();

    _loadAndPlayInDirection(
      startIndex: _playlistIndex! - 1,
      playlist: _playlist.value,
      step: -1,
      wrap: true,
    );
  }

  /// 暂停
  void pause() {
    try {
      logger.i('[action] pause');
      AudioEchoLogRecorder.instance.mark('pause');
      _synchronizeGaplessTransition();
      _player.pause();
      _rebuildGaplessPreparation();
      unawaited(_smtc.updateState(SMTCState.paused));
      playService.desktopLyricService.canSendMessage.then((canSend) {
        if (!canSend) return;

        playService.desktopLyricService.sendPlayerStateMessage(false);
      });
    } catch (err, trace) {
      logger.e('暂停播放失败', error: err, stackTrace: trace);
      showTextOnSnackBar('暂停播放失败，请查看日志', variant: ToastVariant.error);
    }
  }

  /// 恢复播放
  void start() {
    try {
      logger.i('[action] start');
      AudioEchoLogRecorder.instance.mark('start');
      _synchronizeGaplessTransition();
      _player.start();
      _rebuildGaplessPreparation();
      unawaited(_smtc.updateState(SMTCState.playing));
      _schedulePositionSyncBurst();
      playService.desktopLyricService.canSendMessage.then((canSend) {
        if (!canSend) return;

        playService.desktopLyricService.sendPlayerStateMessage(true);
      });
    } catch (err, trace) {
      logger.e('恢复播放失败', error: err, stackTrace: trace);
      showTextOnSnackBar('恢复播放失败，请查看日志', variant: ToastVariant.error);
    }
  }

  /// 再次播放。在顺序播放完最后一曲时再次按播放时使用。
  /// 与 [start] 的差别在于它会通知重绘组件
  void playAgain() => _nextAudioSingleLoop();

  void seek(double position) {
    logger.i('[action] seek=$position');
    AudioEchoLogRecorder.instance.mark(
      'seek',
      extra: {
        'pos': position,
        'length': _player.length,
        'sourceGeneration': _player.sourceGeneration,
        'smartState': _smartTransitions.diagnostics['state'],
      },
    );
    final transitioned = _synchronizeGaplessTransition();
    if (!transitioned) {
      _player.seek(position);
    }
    final effectivePosition = transitioned ? _player.position : position;
    final remaining = _player.length - effectivePosition;
    if (transitioned || remaining > 1.0) {
      _rebuildGaplessPreparation();
    }
    _updateSmtcPosition();
    playService.lyricService.findCurrLyricLineAt(effectivePosition);
    _schedulePositionSyncBurst();
  }

  Future<void> close() async {
    _closed = true;
    _songChangeTaskToken++;
    _cancelSongChangeTasks();
    _cancelPositionSyncBurst();

    try {
      await _smartTransitions.close();
    } catch (_) {}

    // 1. 先停止音频播放（防止释放资源时仍有音频回调）
    try {
      _player.pause();
    } catch (_) {}

    // 2. 取消所有 Stream 订阅（在关闭 Controllers 之前）
    try {
      await _playerStateStreamSub.cancel();
    } catch (_) {}
    try {
      await _gaplessTransitionStreamSub.cancel();
    } catch (_) {}
    var smtcEventCancellation = Future<void>.value();
    var smtcPositionCancellation = Future<void>.value();
    try {
      smtcEventCancellation = _smtcEventStreamSub.cancel();
    } catch (_) {}
    try {
      smtcPositionCancellation = _smtcPositionChangeStreamSub.cancel();
    } catch (_) {}
    _smtcPositionTimer?.cancel();
    _smtcPositionTimer = null;
    _smtcKeepAliveTimer?.cancel();
    _smtcKeepAliveTimer = null;

    // 4. 等待异步回调完全停止（避免 use-after-free）
    await Future.delayed(const Duration(milliseconds: 100));

    // 5. 关闭 SMTC（系统媒体传输控制）
    try {
      await _smtc.updateState(SMTCState.paused);
      await _smtc.close();
    } catch (_) {}
    try {
      await smtcEventCancellation;
    } catch (_) {}
    try {
      await smtcPositionCancellation;
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
    try {
      _playCountRevision.dispose();
    } catch (_) {}

    // 7. 最后释放 BASS 音频资源（此时所有回调和订阅已停止）
    try {
      _player.free();
    } catch (e) {
      logger.w('_player.free error: $e');
    }
  }
}
