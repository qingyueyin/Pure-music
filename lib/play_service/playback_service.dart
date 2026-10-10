import 'dart:async';
import 'dart:developer' as developer;
import 'dart:convert';

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/play_service/equalizer_service.dart';
import 'package:pure_music/play_service/playback_listen_tracker.dart';
import 'package:pure_music/play_service/playback_session_store.dart';
import 'package:pure_music/play_service/playback_song_change_tasks.dart';
import 'package:pure_music/core/audio_dsp_settings.dart';
import 'package:pure_music/play_service/smart_transition_coordinator.dart';
import 'package:pure_music/play_service/smtc_bridge.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart' as rust_tag_reader;
import 'package:pure_music/native/rust/api/library_db.dart' as rust_library_db;
import 'package:pure_music/native/rust/api/smart_transition.dart' as rust_smart;
import 'package:pure_music/core/sleep_blocker.dart';
import 'package:pure_music/core/log/playback_log.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/services/concert_session.dart';
import 'package:pure_music/services/lastfm/lastfm_models.dart';
import 'package:pure_music/services/lastfm/lastfm_service.dart';
import 'package:pure_music/play_service/sleep_timer.dart';
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
  final PlaybackSongChangeTasks _songChangeTasks = PlaybackSongChangeTasks();
  int? _listenRecordingToken;
  String? _supportPath;
  bool _closed = false;
  int _playlistRevision = 0;
  int _nextGaplessTransitionId = 1;
  _PendingGaplessTransition? _pendingGaplessTransition;
  int _replayGainRequestToken = 0;
  int _skipLeadingSilenceToken = 0;
  bool _midiMissingFontWarned = false;
  double? _diagAt;
  double? _diagLength;
  late final SmartTransitionCoordinator _smartTransitions;

  final _playCountRevision = ValueNotifier<int>(0);
  int _smtcDisplayRevision = 0;

  ValueListenable<int> get playCountRevision => _playCountRevision;

  @visibleForTesting
  static bool shouldAutoAdvanceOnCompleted({
    required bool smartHandled,
    required bool transitionHandled,
    required PlayerState currentState,
  }) {
    if (smartHandled || transitionHandled) return false;
    if (currentState == PlayerState.playing) return false;
    return true;
  }

  @visibleForTesting
  static double? selectReplayGainDb({
    required ReplayGainMode mode,
    String? trackGain,
    String? albumGain,
  }) {
    final track = parseReplayGainDb(trackGain);
    final album = parseReplayGainDb(albumGain);
    return switch (mode) {
      ReplayGainMode.track => track ?? album,
      ReplayGainMode.album => album ?? track,
    };
  }

  @visibleForTesting
  static double? parseReplayGainDb(String? raw) {
    if (raw == null) return null;
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (text.length >= 2 && text.toLowerCase().endsWith('db')) {
      text = text.substring(0, text.length - 2).trim();
    }
    return double.tryParse(text);
  }

  @visibleForTesting
  static int? audibleStartMsFromProfileJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final value = decoded['audible_start_ms'];
      if (value is int) return value;
      if (value is num) return value.round();
      return int.tryParse(value?.toString() ?? '');
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static double? skipLeadingSilenceSeekSeconds({
    required int audibleStartMs,
    required int durationMs,
  }) {
    if (audibleStartMs < 400 || durationMs <= 0) return null;
    final percentCap = (durationMs * 0.15).round();
    final maxMs = percentCap < 20000 ? percentCap : 20000;
    if (audibleStartMs > maxMs) return null;
    return audibleStartMs / 1000.0;
  }

  @visibleForTesting
  static String? smartTransitionExplanation(String? mode) {
    return switch (mode) {
      'gapless' => '已无缝衔接',
      'silence_trim' => '已跳过尾部静音',
      'energy_crossfade' => '已交叉淡化',
      'beat_aligned' => '已按节拍对齐',
      'beat_matched' => '已按节拍对齐',
      _ => null,
    };
  }

  @visibleForTesting
  static double rememberedPositionSeconds({
    required bool enabled,
    required double position,
    required double length,
  }) {
    if (!enabled) {
      log.playback.info('legacy', '[remember] disabled by setting');
      return 0.0;
    }
    if (!position.isFinite || !length.isFinite) {
      log.playback.info('legacy', '[remember] position or length not finite');
      return 0.0;
    }
    if (length <= 1.0 || position <= 1.0) {
      log.playback.info(
        'legacy',
        '[remember] too early: length=$length, position=$position',
      );
      return 0.0;
    }
    if (length - position <= 1.0) {
      log.playback.info(
        'legacy',
        '[remember] too close to end: remaining=${length - position}s',
      );
      return 0.0;
    }
    final remembered = position.clamp(0.0, length).toDouble();
    log.playback.info(
      'legacy',
      '[remember] will save position=$remembered (length=$length)',
    );
    return remembered;
  }

  @visibleForTesting
  static double restoredPositionSeconds({
    required bool enabled,
    required double savedPosition,
    required double length,
    required String savedAudioPath,
    required String restoredAudioPath,
  }) {
    if (savedAudioPath.isEmpty || savedAudioPath != restoredAudioPath) {
      return 0.0;
    }
    if (!enabled) {
      log.playback.info('legacy', '[restore] disabled by setting');
      return 0.0;
    }
    if (!savedPosition.isFinite || savedPosition <= 1.0) {
      log.playback.info(
        'legacy',
        '[restore] savedPosition too small: $savedPosition',
      );
      return 0.0;
    }
    if (!length.isFinite || length <= 1.0) {
      log.playback.info('legacy', '[restore] invalid length: $length');
      return 0.0;
    }
    if (length - savedPosition <= 1.0) {
      log.playback.info(
        'legacy',
        '[restore] too close to end: saved=$savedPosition, length=$length, remaining=${length - savedPosition}',
      );
      return 0.0;
    }
    final restored = savedPosition.clamp(0.0, length).toDouble();
    log.playback.info(
      'legacy',
      '[restore] will seek to position=$restored (saved=$savedPosition, length=$length)',
    );
    return restored;
  }

  PlaybackService(this.playService) {
    unawaited(LastFmService.instance.ensureLoaded());
    _player.setMidiSoundfontPath(AppSettings.instance.midiSoundfontPath);
    _bindExclusiveMode();
    _bindPlayerState();
    _bindSmtcControls();
    _bindEqualizerAndSmartTransitions();
    _bindSleepTimer();
    _scheduleSessionRestore();
  }

  void _bindExclusiveMode() {
    _player.onExclusiveModeChanged = (exclusive) {
      _wasapiExclusive.value = exclusive;
      _rebuildGaplessPreparation();
    };
  }

  void _bindPlayerState() {
    _playerStateStreamSub = playerStateStream.listen((event) {
      var shouldAutoAdvance = false;
      if (event == PlayerState.completed) {
        _updateSmtcPosition();
        shouldAutoAdvance = shouldAutoAdvanceOnCompleted(
          smartHandled: _smartTransitions.handlePlayerCompleted(),
          transitionHandled: _player.consumeTransitionHandledCompletion(),
          currentState: _player.playerState,
        );
      }
      _playerState.value = event;
      if (event == PlayerState.playing) {
        SleepBlocker.instance.setPlayerPlaying(true);
      } else if (event == PlayerState.completed) {
        final wasExtending = SleepTimerService.instance.isExtending;
        SleepTimerService.instance.onSongCompleted();
        if (wasExtending) shouldAutoAdvance = false;
        if (_player.playerState == PlayerState.stopped) {
          SleepBlocker.instance.setPlayerPlaying(false);
        }
      } else if (event == PlayerState.paused) {
        SleepBlocker.instance.setPlayerPlaying(false);
        if (SleepTimerService.instance.isExtending) {
          SleepTimerService.instance.onManualPause();
        }
      } else if (event == PlayerState.stopped) {
        SleepBlocker.instance.setPlayerPlaying(false);
      }
      _notifyPositionSync();
      _syncSmtcPositionTimer();
      if (event == PlayerState.completed && shouldAutoAdvance) {
        _autoNextAudio();
      }
    });
  }

  void _bindSmtcControls() {
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
  }

  void _bindEqualizerAndSmartTransitions() {
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
  }

  void _bindSleepTimer() {
    SleepTimerService.instance.setOnExpired(_pauseForSleepTimer);
    SleepTimerService.instance.setOnEnterExtending(
      _abortQueuedTransitionsForSleepTimer,
    );
    SleepTimerService.instance.setOnCancelExtending(() {
      if (!_closed) _rebuildGaplessPreparation();
    });
  }

  void _scheduleSessionRestore() {
    Future.microtask(() async {
      try {
        await _restoreLastSession();
        _supportPath = (await getAppDataDir()).path;
        await ConcertSession.instance.restoreAfterStartup();
      } catch (err, trace) {
        log.playback.error('legacy', '[restoreLastSession] $err\n$trace');
      }
    });
  }

  final _player = BassPlayer();
  final _smtc = SmtcBridge.create();
  final _pref = AppPreference.instance.playbackPref;
  late final PlaybackSessionStore _sessionStore = PlaybackSessionStore(
    preference: _pref,
    save: AppPreference.instance.savePlaybackOnly,
  );
  final PlaybackListenTracker _listenTracker = PlaybackListenTracker();
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
  bool get eqEnabled => _eq.eqEnabled;
  AudioDspSettings get audioEffects => _eq.audioEffects;
  double get eqAutoHeadroomDb => _eq.eqAutoHeadroomDb;
  double get eqAutoGainDb => _eq.eqAutoGainDb;

  void refreshEQ() => _eq.refreshEQ();

  void setEQ(int band, double gain) {
    _synchronizeGaplessTransition();
    _eq.setEQ(band, gain);
    _rebuildGaplessPreparation();
  }

  void setEqEnabled(bool enabled) {
    _synchronizeGaplessTransition();
    _eq.setEqEnabled(enabled);
    _rebuildGaplessPreparation();
  }

  void setAudioEffects(AudioDspSettings settings) {
    _synchronizeGaplessTransition();
    _eq.setAudioEffects(settings);
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

  void setEqAutoHeadroomDb(double value) {
    _synchronizeGaplessTransition();
    _eq.setEqAutoHeadroomDb(value);
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

  void setReplayGainMode(ReplayGainMode mode) {
    _synchronizeGaplessTransition();
    _pref.replayGainMode = mode;
    if (_pref.replayGainEnabled) {
      final curr = nowPlaying;
      if (curr != null) _loadCurrentReplayGain(curr);
    }
    _rebuildGaplessPreparation();
  }

  void setSkipLeadingSilence(bool enabled) {
    _pref.skipLeadingSilence = enabled;
    if (enabled) {
      final curr = nowPlaying;
      if (curr != null) _maybeSkipLeadingSilence(curr, reason: 'user.play');
    } else {
      _skipLeadingSilenceToken++;
    }
  }

  void setMidiSoundfontPath(String? path) {
    AppSettings.instance.midiSoundfontPath = path;
    final applied = _player.setMidiSoundfontPath(path);
    _midiMissingFontWarned = false;
    final audio = nowPlaying;
    if (audio != null && BassPlayer.isMidiPath(audio.path) && applied) {
      final position = _player.position;
      _player.setSource(audio.path);
      if (position > 0.2) _player.seek(position);
      _player.start();
    }
  }

  Future<bool> saveEqPreset(String name) => _eq.saveEqPreset(name);
  Future<bool> saveEqPresetBatch(Iterable<EqPreset> presets) =>
      _eq.saveEqPresetBatch(presets);
  Future<bool> importEqPresetsAndApplyLast(Iterable<EqPreset> presets) async {
    _synchronizeGaplessTransition();
    final applied = await _eq.importEqPresetsAndApplyLast(presets);
    _rebuildGaplessPreparation();
    return applied;
  }

  Future<bool> removeEqPreset(String name) => _eq.removeEqPreset(name);
  Future<bool> applyEqPreset(EqPreset preset) async {
    _synchronizeGaplessTransition();
    final applied = await _eq.applyEqPreset(preset);
    _rebuildGaplessPreparation();
    return applied;
  }

  void applyEqGainsSnapshot(List<double> gains, {double? preampDb}) {
    _synchronizeGaplessTransition();
    _eq.applyEqGainsSnapshot(gains, preampDb: preampDb);
    _rebuildGaplessPreparation();
  }

  Future<bool> applyBuiltInAudioPreset(BuiltInAudioPreset preset) async {
    _synchronizeGaplessTransition();
    final applied = await _eq.applyBuiltInAudioPreset(preset);
    _rebuildGaplessPreparation();
    return applied;
  }

  void reapplyOutputGain() => _eq.reapplyOutputGain();

  Future<double?> _readReplayGain(String path) async {
    if (!_pref.replayGainEnabled) return null;
    try {
      final meta = await rust_tag_reader.readAudioExtraMetadata(path: path);
      return selectReplayGainDb(
        mode: _pref.replayGainMode,
        trackGain: meta.replaygainTrackGain,
        albumGain: meta.replaygainAlbumGain,
      );
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


  void _maybeSkipLeadingSilence(Audio audio, {required String reason}) {
    if (!_pref.skipLeadingSilence || reason == 'restore') return;
    final token = ++_skipLeadingSilenceToken;
    unawaited(_skipLeadingSilenceIfNeeded(audio, token));
  }

  Future<void> _skipLeadingSilenceIfNeeded(Audio audio, int token) async {
    try {
      final libraryRoot = _supportPath ??= (await getAppDataDir()).path;
      if (_closed || token != _skipLeadingSilenceToken || nowPlaying != audio) {
        return;
      }
      final profile = await rust_smart.analyzeSmartTransitionTrack(
        jobId: BigInt.from(0x100000000 + token),
        path: audio.path,
        libraryRoot: libraryRoot,
      );
      if (_closed || token != _skipLeadingSilenceToken || nowPlaying != audio) {
        return;
      }
      final audibleStartMs = audibleStartMsFromProfileJson(profile);
      if (audibleStartMs == null) return;
      final durationMs = audio.duration * 1000;
      final seekTo = skipLeadingSilenceSeekSeconds(
        audibleStartMs: audibleStartMs,
        durationMs: durationMs,
      );
      if (seekTo == null) return;
      if (_player.position >= seekTo - 0.05) return;
      _player.seek(seekTo);
    } catch (error, trace) {
      log.playback.warn(
        'legacy',
        '[skip silence] failed',
        error: error,
        stackTrace: trace,
      );
    }
  }

  void _warnMidiMissingFont(Audio audio) {
    if (!BassPlayer.isMidiPath(audio.path)) return;
    if (_player.hasMidiSoundfont) return;
    if (_midiMissingFontWarned) return;
    _midiMissingFontWarned = true;
    showTextOnSnackBar('MIDI 需要音色库才能发声，请在设置 → 播放里指定');
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
  bool useExclusiveMode(bool exclusive) {
    log.playback.info('legacy', '[action] useExclusiveMode=$exclusive');
    AudioEchoLogRecorder.instance.mark(
      'useExclusiveMode',
      extra: {'exclusive': exclusive},
    );
    _synchronizeGaplessTransition();
    final disabled = <String>[];
    final previousEqEnabled = _eq.eqEnabled;
    final previousAudioEffects = _eq.audioEffects;
    final previousRate = _rate.value;
    final previousPitch = _pitch.value;
    if (exclusive && !_player.wasapiExclusive) {
      if (_player.hasAudioSource) {
        disabled.addAll(_eq.disableForExclusiveMode());
        if ((_rate.value - 1.0).abs() > 1e-6) {
          _rate.value = 1.0;
          _player.setRate(1.0);
          disabled.add('变速');
        }
        if (_pitch.value.abs() > 1e-6) {
          _pitch.value = 0.0;
          _player.setPitch(0.0);
          disabled.add('变调');
        }
      }
    }
    final applied = _player.useExclusiveMode(exclusive);
    if (!applied && disabled.isNotEmpty) {
      if (disabled.contains('EQ')) {
        _eq.setEqEnabled(previousEqEnabled);
      }
      if (disabled.contains('DSP')) {
        _eq.setAudioEffects(previousAudioEffects);
      }
      if (disabled.contains('变速')) {
        _rate.value = previousRate;
        _player.setRate(previousRate);
      }
      if (disabled.contains('变调')) {
        _pitch.value = previousPitch;
        _player.setPitch(previousPitch);
      }
    }
    if (applied) {
      _wasapiExclusive.value = exclusive;
      if (disabled.isNotEmpty) {
        unawaited(AppPreference.instance.save());
      }
      final modeLabel = exclusive ? '独占' : '共享';
      final message = disabled.isEmpty
          ? '已切换到$modeLabel'
          : '已切换到$modeLabel，已关闭${disabled.join('、')}';
      showTextOnSnackBar(message, variant: ToastVariant.success);
    }
    return applied;
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
    log.playback.info('legacy', '[action] setPitch=$value');
    AudioEchoLogRecorder.instance.mark('setPitch', extra: {'value': value});
    _synchronizeGaplessTransition();
    _pitch.value = value;
    _player.setPitch(value);
    _rebuildGaplessPreparation();
  }

  late final _rate = ValueNotifier(1.0);
  ValueNotifier<double> get rate => _rate;

  void setRate(double value) {
    log.playback.info('legacy', '[action] setRate=$value');
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

  double get volumeDsp => _pref.volumeDsp;

  /// 修改解码时的音量（不影响 Windows 系统音量）
  void setVolumeDsp(double volume) {
    log.playback.info('legacy', '[action] setVolumeDsp=$volume');
    AudioEchoLogRecorder.instance.mark(
      'setVolumeDsp',
      extra: {'value': volume},
    );
    _pref.volumeDsp = volume;
    _eq.reapplyOutputGain();
    _savePlaybackOnly();
    notifyListeners();
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
        if (token != null && !_songChangeTasks.isCurrent(token)) return;
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
    if (_pendingGaplessTransition == null &&
        playerState == PlayerState.playing) {
      final sampledLength = _player.length;
      if (currentPosition.isFinite &&
          sampledLength.isFinite &&
          sampledLength > 1) {
        _diagAt = nextDiagnosticAt(
          previous: _diagAt,
          sample: currentPosition,
          length: sampledLength,
          playing: true,
        );
        if (_diagAt != null) _diagLength = sampledLength;
      }
    }
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
        SleepTimerService.instance.isExtending ||
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
      isSameAlbum: _sameAlbum(outgoing, incoming),
      isGaplessCandidate: false,
      userSpeed: _rate.value,
      pitch: _pitch.value,
      outgoingReplayGainDb: _player.replayGainDb,
    );
  }

  bool _sameAlbum(Audio outgoing, Audio incoming) {
    final outgoingAlbum = outgoing.album.trim().toLowerCase();
    final incomingAlbum = incoming.album.trim().toLowerCase();
    if (outgoingAlbum.isEmpty || incomingAlbum.isEmpty) return false;
    return outgoingAlbum == incomingAlbum;
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
    log.playback.info(
      'legacy',
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
    if (SleepTimerService.instance.isExtending) {
      SleepTimerService.instance.onSongCompleted();
      return;
    }
    final previousAudio = nowPlaying;
    if (previousAudio != null) {
      _onPositionUpdate(previousAudio.duration.toDouble());
    }
    final origin = _captureOrigin();
    _commitSongChange(
      reason: 'smart',
      origin: origin,
      audioIndex: commit.target.incomingIndex,
      playlist: _playlist.value,
      audio: commit.target.incoming,
      replayGainDb: commit.transition.replayGainDb,
      alreadyPlaying: true,
      state: _player.playerState,
      rebuildTransitionPreparation: false,
    );
    final explanation = smartTransitionExplanation(commit.planMode);
    if (explanation != null) {
      showTextOnSnackBar(explanation);
    }
  }

  void _abortQueuedTransitionsForSleepTimer() {
    _smartTransitions.cancel('sleep_timer_extending');
    _player.discardQueuedGaplessSource();
    _pendingGaplessTransition = null;
  }

  void _pauseForSleepTimer() {
    try {
      log.playback.debug('legacy', '[action] pauseForSleepTimer');
      _abortQueuedTransitionsForSleepTimer();
      if (_player.playerState == PlayerState.playing ||
          _player.playerState == PlayerState.stalled) {
        _player.pause();
      }
      unawaited(_smtc.updateState(SMTCState.paused));
      playService.desktopLyricService.canSendMessage.then((canSend) {
        if (!canSend) return;
        playService.desktopLyricService.sendPlayerStateMessage(false);
      });
    } catch (err, trace) {
      log.playback.error('legacy', '睡眠定时暂停失败', error: err, stackTrace: trace);
    }
  }

  void _rebuildGaplessPreparation() {
    if (SleepTimerService.instance.isExtending) {
      _pendingGaplessTransition = null;
      return;
    }
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
      if (SleepTimerService.instance.isExtending) {
        SleepTimerService.instance.onSongCompleted();
        return;
      }
      _loadAndPlayInDirection(
        reason: 'gapless',
        origin: _captureOrigin(),
        startIndex: (_playlistIndex ?? -1) + 1,
        playlist: items,
        step: 1,
        wrap: true,
      );
      return;
    }

    _pendingGaplessTransition = null;
    if (SleepTimerService.instance.isExtending) {
      SleepTimerService.instance.onSongCompleted();
      return;
    }
    final previousAudio = nowPlaying;
    if (previousAudio != null) {
      _onPositionUpdate(previousAudio.duration.toDouble());
    }
    final origin = _captureOrigin();
    _commitSongChange(
      reason: 'gapless',
      origin: origin,
      audioIndex: pending.targetIndex,
      playlist: items,
      audio: pending.audio,
      replayGainDb: _player.replayGainDb,
      alreadyPlaying: true,
      state: _player.playerState,
    );
  }

  SongOrigin? _captureOrigin() {
    final at = _diagAt;
    final sampledLength = _diagLength;
    if (at == null || sampledLength == null) return null;
    return SongOrigin(
      at: at,
      length: sampledLength,
      from: nowPlaying?.title,
      fromIndex: _playlistIndex,
      lengthSource: 'player',
    );
  }

  void _commitSongChange({
    required String reason,
    required SongOrigin? origin,
    required int audioIndex,
    required List<Audio> playlist,
    required Audio audio,
    double? replayGainDb,
    bool alreadyPlaying = false,
    PlayerState state = PlayerState.playing,
    bool rebuildTransitionPreparation = true,
  }) {
    logSongChanged(
      reason: reason,
      to: audio.title,
      index: audioIndex,
      origin: origin,
    );
    _maybeSkipLeadingSilence(audio, reason: reason);
    _warnMidiMissingFont(audio);
    _diagAt = null;
    _diagLength = null;
    _smtcDisplayRevision++;
    _replayGainRequestToken++;
    final token = _songChangeTasks.begin();
    _cancelSongChangeTasks();
    ThemeProvider.instance.cancelPendingAudioTheme();
    _playlistIndex = audioIndex;
    _publishSongChange(audio, state);
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

  void _publishSongChange(Audio audio, PlayerState state) {
    _nowPlaying.value = audio;
    SleepTimerService.instance.onSongChanged(audio.path);
    _lastNowPlayingChangedMs = DateTime.now().millisecondsSinceEpoch;
    _resetListenAccumulator(audio.duration.toDouble());
    unawaited(audio.loadSmallCoverBytes());
    playService.desktopLyricService.sendNowPlayingMessage(audio);
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
  }

  bool _loadAndPlay(
    int audioIndex,
    List<Audio> playlist, {
    required String reason,
    required SongOrigin? origin,
    bool reportFailure = true,
  }) {
    if (audioIndex < 0 || audioIndex >= playlist.length) return false;
    final audio = playlist[audioIndex];
    _invalidateGaplessPreparation();
    developer.Timeline.startSync('playback.loadAndPlay');
    try {
      _player.setSource(audio.path);
      _eq.reapplyOutputGain();
      _player.start();
      _commitSongChange(
        reason: reason,
        origin: origin,
        audioIndex: audioIndex,
        playlist: playlist,
        audio: audio,
      );
      return true;
    } catch (err, trace) {
      log.playback.error(
        'legacy',
        '加载并播放歌曲失败 index=$audioIndex title=${audio.title}',
        error: err,
        stackTrace: trace,
      );
      if (reportFailure) {
        _reportPlaybackLoadFailure('播放失败，请查看日志');
      }
      return false;
    } finally {
      developer.Timeline.finishSync();
    }
  }

  bool _loadAndPlayInDirection({
    required String reason,
    required SongOrigin? origin,
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
      if (_loadAndPlay(
        index,
        playlist,
        reason: reason,
        origin: origin,
        reportFailure: false,
      )) {
        return true;
      }
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

  void refreshNowPlayingArtwork() {
    if (_closed) return;
    final audio = nowPlaying;
    if (audio == null) return;
    unawaited(
      _smtc.updateDisplay(
        title: audio.title,
        artist: audio.artist,
        album: audio.album,
        duration: audio.duration * 1000,
        path: audio.path,
      ),
    );
  }

  bool _isCurrentSongChangeTask(int token, Audio audio) {
    return _songChangeTasks.isCurrent(token) && identical(nowPlaying, audio);
  }

  void _cancelSongChangeTasks() {
    _songChangeTasks.cancel();
  }

  void _resetListenAccumulator(double durationSec) {
    _listenTracker.reset(
      durationSec: durationSec,
      lastFmStartedAt: DateTime.now().millisecondsSinceEpoch,
      lastFmThresholdMs: lastFmScrobbleThresholdMs(durationSec.round()),
    );
    final audio = nowPlaying;
    if (audio != null) {
      unawaited(
        LastFmService.instance.updateNowPlaying(
          title: audio.title,
          artist: audio.artist,
          album: audio.album,
          durationSec: audio.duration,
        ),
      );
    }
  }

  void _onPositionUpdate(double positionSec) {
    final delta = _listenTracker.updatePosition(
      positionSec: positionSec,
      isPlaying: !_closed && playerState == PlayerState.playing,
    );
    if (delta <= 0) return;
    if (_listenTracker.shouldRecordListen) unawaited(_recordListen());
    _maybeQueueLastFmScrobble();
  }

  void _maybeQueueLastFmScrobble() {
    if (!_listenTracker.shouldQueueScrobble) return;
    if (!AppSettings.instance.lastFmEnabled ||
        !LastFmService.instance.isAuthorized) {
      return;
    }
    final audio = nowPlaying;
    if (audio == null) return;
    _listenTracker.markScrobbleQueued();
    unawaited(
      LastFmService.instance.enqueueScrobble(
        title: audio.title,
        artist: audio.artist,
        album: audio.album,
        durationSec: audio.duration,
        startedAt: _listenTracker.lastFmStartedAt,
      ),
    );
  }

  Future<void> _recordListen() async {
    if (!_listenTracker.shouldRecordListen) return;
    final audio = nowPlaying;
    if (audio == null) return;
    final audioPath = audio.path;

    final sessionToken = _listenTracker.sessionToken;
    if (_listenRecordingToken == sessionToken) return;
    _listenRecordingToken = sessionToken;

    try {
      final supportPath = _supportPath ??= (await getAppDataDir()).path;
      await rust_library_db.incrementPlayCount(
        indexPath: supportPath,
        path: audioPath,
      );
      audio.playCount++;
      if (sessionToken == _listenTracker.sessionToken) {
        _listenTracker.markListenRecorded();
      }
      if (!_closed) _playCountRevision.value++;
    } catch (err, trace) {
      log.playback.warn('legacy', '记录播放次数失败', error: err, stackTrace: trace);
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
    _songChangeTasks.schedule(
      token: token,
      onMetadata: () => _onSongChangeMetadata(token, audio),
      onPrefetch: () =>
          _onSongChangePrefetch(token, audio, audioIndex, playlist),
      onPersist: () => _onSongChangePersist(token, audio),
      onCleanup: () => _onSongChangeCleanup(token, audio),
    );
  }

  void _onSongChangeMetadata(int token, Audio audio) {
    if (!_isCurrentSongChangeTask(token, audio)) return;
    _syncSmtcPositionTimer();
    playService.desktopLyricService.canSendMessage.then((canSend) {
      if (!_isCurrentSongChangeTask(token, audio)) return;
      if (!canSend) return;
      playService.desktopLyricService.sendPlayerStateMessage(
        playerState == PlayerState.playing,
      );
    });
  }

  void _onSongChangePrefetch(
    int token,
    Audio audio,
    int audioIndex,
    List<Audio> playlist,
  ) {
    if (!_isCurrentSongChangeTask(token, audio)) return;
    ThemeProvider.instance.applyThemeFromAudio(audio);
    if (audioIndex + 1 < playlist.length) {
      final next = playlist[audioIndex + 1];
      CoverImageCache.instance.preload(next.path, modified: next.modified);
      CoverImageCache.instance.preloadNowPlayingCover(next);
      playService.lyricService.prefetchLyric(next);
      if (audioIndex + 2 < playlist.length) {
        playService.lyricService.prefetchLyric(playlist[audioIndex + 2]);
      }
    }
  }

  void _onSongChangePersist(int token, Audio audio) {
    if (!_isCurrentSongChangeTask(token, audio)) return;
    final currentIndex = _playlistIndex;
    if (currentIndex == null || _playlist.value.isEmpty) return;
    _persistLastSession(
      playlist: _playlist.value,
      playlistIndex: currentIndex,
      nowPlaying: audio,
    );
  }

  void _onSongChangeCleanup(int token, Audio audio) {
    if (!_isCurrentSongChangeTask(token, audio)) return;
    AudioLibrary.instance.evictStaleCoverBytes();
  }

  /// 播放当前播放列表的第几项，只能用在播放列表界面
  void playIndexOfPlaylist(int audioIndex) {
    log.playback.debug('legacy', '[action] playIndexOfPlaylist=$audioIndex');
    AudioEchoLogRecorder.instance.mark(
      'playIndexOfPlaylist',
      extra: {'index': audioIndex},
    );
    final origin = _captureOrigin();
    _loadAndPlay(
      audioIndex,
      playlist.value,
      reason: 'user.play',
      origin: origin,
    );
  }

  /// 仅更新播放列表索引，不触发重新播放。用于拖拽排序等场景
  void setPlaylistIndex(int newIndex) {
    log.playback.debug('legacy', '[action] setPlaylistIndex=$newIndex');
    if (newIndex < 0 || newIndex >= _playlist.value.length) return;
    _synchronizeGaplessTransition();
    _playlistIndex = newIndex;
    _persistCurrentSession();
    _rebuildGaplessPreparation();
  }

  void reorderPlaylist(int oldIndex, int newIndex) {
    log.playback.debug(
      'legacy',
      '[action] reorderPlaylist old=$oldIndex new=$newIndex',
    );
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
    log.playback.debug(
      'legacy',
      '[action] play index=$audioIndex playlistLen=${playlist.length}',
    );
    AudioEchoLogRecorder.instance.mark(
      'play',
      extra: {'index': audioIndex, 'playlistLen': playlist.length},
    );
    if (audioIndex < 0 || audioIndex >= playlist.length) return;
    _synchronizeGaplessTransition();
    final origin = _captureOrigin();
    if (shuffle.value) {
      final shuffled = List<Audio>.from(playlist);
      final willPlay = shuffled.removeAt(audioIndex);
      shuffled.shuffle();
      shuffled.insert(0, willPlay);
      _setPlaylistBackup(playlist);
      final activePlaylist = _setPlaylist(shuffled);
      _loadAndPlay(0, activePlaylist, reason: 'user.play', origin: origin);
    } else {
      _setPlaylistBackup(playlist);
      final activePlaylist = _setPlaylist(playlist);
      _loadAndPlay(
        audioIndex,
        activePlaylist,
        reason: 'user.play',
        origin: origin,
      );
    }
  }

  void shuffleAndPlay(List<Audio> audios) {
    log.playback.debug(
      'legacy',
      '[action] shuffleAndPlay len=${audios.length}',
    );
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

    final origin = _captureOrigin();
    _loadAndPlay(0, activePlaylist, reason: 'user.play', origin: origin);
  }

  /// 下一首播放
  void addToNext(Audio audio) {
    log.playback.debug('legacy', '[action] addToNext');
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
    log.playback.debug('legacy', '[action] clearQueue');
    AudioEchoLogRecorder.instance.mark('clearQueue');
    _synchronizeGaplessTransition();
    _songChangeTasks.begin();
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

  void _syncBackupAfterQueueRemove(Audio removedAudio) {
    if (shuffle.value) {
      final backup = List<Audio>.from(_playlistBackup);
      final backupIndex = backup.indexWhere(
        (audio) => audio.path == removedAudio.path,
      );
      if (backupIndex >= 0) {
        backup.removeAt(backupIndex);
      }
      _setPlaylistBackup(backup);
      return;
    }
    _setPlaylistBackup(_playlist.value);
  }

  void removeFromQueue(int index) {
    log.playback.debug('legacy', '[action] removeFromQueue index=$index');
    AudioEchoLogRecorder.instance.mark(
      'removeFromQueue',
      extra: {'index': index},
    );
    if (index < 0 || index >= _playlist.value.length) return;
    _synchronizeGaplessTransition();
    final removedAudio = _playlist.value[index];
    final wasPlaying = _playlistIndex == index;
    _setPlaylist([..._playlist.value]..removeAt(index));
    _syncBackupAfterQueueRemove(removedAudio);
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
          final origin = _captureOrigin();
          _loadAndPlay(
            _playlistIndex!,
            _playlist.value,
            reason: 'user.play',
            origin: origin,
          );
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
    if (flag == shuffle.value) return;
    if (nowPlaying == null) {
      if (!flag) {
        shuffle.value = false;
        _setPlaylistBackup(const []);
      }
      return;
    }
    _synchronizeGaplessTransition();
    log.playback.debug('legacy', '[action] useShuffle=$flag');
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
    unawaited(
      _sessionStore.save(
        PlaybackSessionSnapshot(
          lastAudioPath: nowPlaying.path,
          lastPlaylistPaths: playlist.map((e) => e.path).toList(),
          lastPlaylistIndex: playlistIndex,
          lastShuffleActive: shuffle.value,
          lastOriginalPlaylistPaths: shuffle.value
              ? _playlistBackup.map((e) => e.path).toList()
              : const [],
          lastPositionSeconds: _rememberedPositionSeconds(),
        ),
      ),
    );
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
    unawaited(_sessionStore.clear());
  }

  double _rememberedPositionSeconds() {
    return rememberedPositionSeconds(
      enabled: AppSettings.instance.rememberPlaybackPosition,
      position: position,
      length: length,
    );
  }

  Future<void> persistPlaybackPositionForExit() async {
    if (_closed) return;
    if (!AppSettings.instance.rememberPlaybackPosition) {
      if (_sessionStore.snapshot.lastPositionSeconds != 0.0) {
        await _sessionStore.save(
          _sessionStore.snapshot.copyWith(lastPositionSeconds: 0.0),
        );
      }
      log.playback.info(
        'legacy',
        '[persist] rememberPlaybackPosition disabled, cleared position',
      );
      return;
    }
    final currentAudio = nowPlaying;
    if (currentAudio == null || _playlist.value.isEmpty) {
      await _sessionStore.save(
        _sessionStore.snapshot.copyWith(lastPositionSeconds: 0.0),
      );
      log.playback.info(
        'legacy',
        '[persist] no audio playing, cleared position',
      );
      return;
    }
    final remembered = _rememberedPositionSeconds();
    await _sessionStore.save(
      _sessionStore.snapshot.copyWith(lastPositionSeconds: remembered),
    );
    log.playback.info(
      'legacy',
      '[persist] saved position: $remembered (from pos=$position, len=$length)',
    );
  }

  Future<void> _restoreLastSession() async {
    var session = _sessionStore.snapshot;
    var lastPath = session.lastAudioPath;
    if (lastPath.isEmpty) return;
    if (!await _waitForLibraryAudios()) return;
    session = _sessionStore.snapshot;
    lastPath = session.lastAudioPath;
    if (lastPath.isEmpty) return;
    final pathToAudio = {
      for (final audio in AudioLibrary.instance.audioCollection)
        audio.path: audio,
    };
    final restoredPlaylist = _playlistFromSessionPaths(
      session.lastPlaylistPaths,
      pathToAudio,
      lastPath,
    );
    if (restoredPlaylist.isEmpty) return;
    _installRestoredSession(session, restoredPlaylist, pathToAudio, lastPath);
    await _restorePlayerAndSmtc(session, lastPath);
  }

  Future<bool> _waitForLibraryAudios() async {
    for (int i = 0; i < 10; i++) {
      if (AudioLibrary.instance.audioCollection.isNotEmpty) return true;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return AudioLibrary.instance.audioCollection.isNotEmpty;
  }

  List<Audio> _playlistFromSessionPaths(
    List<String> paths,
    Map<String, Audio> pathToAudio,
    String lastPath,
  ) {
    final restoredPlaylist = <Audio>[
      for (final p in paths)
        if (pathToAudio[p] != null) pathToAudio[p]!,
    ];
    if (restoredPlaylist.isEmpty) {
      final single = pathToAudio[lastPath];
      if (single != null) restoredPlaylist.add(single);
    }
    return restoredPlaylist;
  }

  void _installRestoredSession(
    PlaybackSessionSnapshot session,
    List<Audio> restoredPlaylist,
    Map<String, Audio> pathToAudio,
    String lastPath,
  ) {
    final restoredOriginalPlaylist = <Audio>[];
    for (final p in session.lastOriginalPlaylistPaths) {
      final a = pathToAudio[p];
      if (a != null) {
        restoredOriginalPlaylist.add(a);
      }
    }

    var restoredIndex = session.lastPlaylistIndex;
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
    shuffle.value = session.lastShuffleActive;
    _playlistIndex = restoredIndex;
    _nowPlaying.value = restoredPlaylist[restoredIndex];
    final restored = restoredPlaylist[restoredIndex];
    logSongChanged(
      reason: 'restore',
      to: restored.title,
      index: restoredIndex,
      origin: SongOrigin(
        at: session.lastPositionSeconds,
        length: restored.duration.toDouble(),
        from: null,
        fromIndex: null,
        lengthSource: 'tag',
      ),
    );
    _diagAt = null;
    _diagLength = null;
    _smtcDisplayRevision++;
    _lastNowPlayingChangedMs = DateTime.now().millisecondsSinceEpoch;
    nowPlaying!.loadSmallCoverBytes();
  }

  Future<void> _restorePlayerAndSmtc(
    PlaybackSessionSnapshot session,
    String lastPath,
  ) async {
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
      if (_closed || !identical(nowPlaying, restoredAudio)) return;
      final restoreTo = restoredPositionSeconds(
        enabled: AppSettings.instance.rememberPlaybackPosition,
        savedPosition: session.lastPositionSeconds,
        length: _player.length,
        savedAudioPath: lastPath,
        restoredAudioPath: restoredAudio.path,
      );
      log.playback.info(
        'legacy',
        '[restore] rememberPlaybackPosition=${AppSettings.instance.rememberPlaybackPosition}, '
            'session.lastPositionSeconds=${session.lastPositionSeconds}, '
            'playerLength=${_player.length}, '
            'restoreTo=$restoreTo',
      );
      if (restoreTo > 0) {
        _player.seek(restoreTo);
      }
      _schedulePositionSyncBurst();
      _syncSmtcPositionTimer();
      _rebuildGaplessPreparation();
    } catch (err) {
      log.playback.error('legacy', '[restore last session] $err');
    }
  }

  void _nextAudioLoop({required String reason, required SongOrigin? origin}) {
    if (_playlistIndex == null) return;
    _synchronizeGaplessTransition();

    _loadAndPlayInDirection(
      reason: reason,
      origin: origin,
      startIndex: _playlistIndex! + 1,
      playlist: _playlist.value,
      step: 1,
      wrap: true,
    );
  }

  void _nextAudioSingleLoop({
    required String reason,
    required SongOrigin? origin,
  }) {
    if (_playlistIndex == null) return;
    _synchronizeGaplessTransition();

    _loadAndPlay(
      _playlistIndex!,
      _playlist.value,
      reason: reason,
      origin: origin,
    );
  }

  void _autoNextAudio() {
    final origin = _captureOrigin();
    switch (playMode.value) {
      case PlayMode.forward:
      case PlayMode.loop:
        _nextAudioLoop(reason: 'completed', origin: origin);
        break;
      case PlayMode.singleLoop:
        _nextAudioSingleLoop(reason: 'completed', origin: origin);
        break;
    }
  }

  /// 手动下一曲时默认循环播放列表
  void nextAudio() {
    log.playback.debug('legacy', '[action] nextAudio');
    AudioEchoLogRecorder.instance.mark('nextAudio');
    final origin = _captureOrigin();
    _nextAudioLoop(reason: 'user.next', origin: origin);
  }

  /// 手动上一曲时默认循环播放列表
  void lastAudio() {
    log.playback.debug('legacy', '[action] lastAudio');
    AudioEchoLogRecorder.instance.mark('lastAudio');
    if (_playlistIndex == null) return;
    final origin = _captureOrigin();
    _synchronizeGaplessTransition();

    _loadAndPlayInDirection(
      reason: 'user.previous',
      origin: origin,
      startIndex: _playlistIndex! - 1,
      playlist: _playlist.value,
      step: -1,
      wrap: true,
    );
  }

  /// 暂停
  void pause() {
    try {
      log.playback.debug('legacy', '[action] pause');
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
      log.playback.error('legacy', '暂停播放失败', error: err, stackTrace: trace);
      showTextOnSnackBar('暂停播放失败，请查看日志', variant: ToastVariant.error);
    }
  }

  /// 恢复播放
  void start() {
    try {
      log.playback.debug('legacy', '[action] start');
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
      log.playback.error('legacy', '恢复播放失败', error: err, stackTrace: trace);
      showTextOnSnackBar('恢复播放失败，请查看日志', variant: ToastVariant.error);
    }
  }

  /// 再次播放。在顺序播放完最后一曲时再次按播放时使用。
  /// 与 [start] 的差别在于它会通知重绘组件
  void playAgain() {
    final origin = _captureOrigin();
    _nextAudioSingleLoop(reason: 'user.play', origin: origin);
  }

  void seek(double position) {
    log.playback.debug('legacy', '[action] seek=$position');
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
    SleepBlocker.instance.unblock();
    SleepTimerService.instance.cancel();
    _songChangeTasks.begin();
    _cancelSongChangeTasks();
    _cancelPositionSyncBurst();
    try {
      await _smartTransitions.close();
    } catch (_) {}
    try {
      _player.pause();
    } catch (_) {}
    final smtcCancels = await _cancelPlaybackSubscriptions();
    await Future.delayed(const Duration(milliseconds: 100));
    await _closeSmtc(smtcCancels);
    _disposePlaybackNotifiers();
    try {
      _player.free();
    } catch (e) {
      log.playback.warn('legacy', '_player.free error: $e');
    }
  }

  Future<({Future<void> events, Future<void> position})>
  _cancelPlaybackSubscriptions() async {
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
    return (events: smtcEventCancellation, position: smtcPositionCancellation);
  }

  Future<void> _closeSmtc(
    ({Future<void> events, Future<void> position}) smtcCancels,
  ) async {
    try {
      await _smtc.updateState(SMTCState.paused);
      await _smtc.close();
    } catch (_) {}
    try {
      await smtcCancels.events;
    } catch (_) {}
    try {
      await smtcCancels.position;
    } catch (_) {}
  }

  void _disposePlaybackNotifiers() {
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
  }
}
