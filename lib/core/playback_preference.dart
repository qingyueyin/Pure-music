part of 'preference.dart';

class PlaybackPreference {
  PlayMode playMode;
  double volumeDsp;
  List<double> eqGains;
  int eqBandModelVersion;
  bool eqEnabled;
  double eqPreampDb;
  bool eqAutoGainEnabled;
  double eqAutoHeadroomDb;
  List<EqPreset> eqPresets;
  AudioDspSettings audioDspSettings;
  String lastAudioPath;
  List<String> lastPlaylistPaths;
  int lastPlaylistIndex;
  bool lastShuffleActive;
  List<String> lastOriginalPlaylistPaths;
  double lastPositionSeconds;
  bool reinitOnSetSource;
  bool replayGainEnabled;
  ReplayGainMode replayGainMode;
  bool skipLeadingSilence;
  TransitionMode transitionMode;
  int transitionFadeOutMs;
  int transitionFadeInMs;
  SleepTimerAction sleepTimerAction;

  /// 共享模式选定的输出设备 key；空字符串表示跟随系统默认设备。
  String sharedOutputDevice;

  /// WASAPI 独占模式选定的输出设备 key；空字符串表示跟随系统默认设备。
  String wasapiOutputDevice;

  PlaybackPreference(
    this.playMode,
    this.volumeDsp,
    this.eqGains,
    this.eqPresets, {
    this.eqBandModelVersion = currentEqBandModelVersion,
    this.eqEnabled = true,
    this.audioDspSettings = const AudioDspSettings(),
    this.replayGainEnabled = false,
    this.replayGainMode = ReplayGainMode.track,
    this.skipLeadingSilence = false,
    this.eqPreampDb = 0.0,
    this.eqAutoGainEnabled = true,
    this.eqAutoHeadroomDb = 1.0,
    this.lastAudioPath = '',
    this.lastPlaylistPaths = const [],
    this.lastPlaylistIndex = 0,
    this.lastShuffleActive = false,
    this.lastOriginalPlaylistPaths = const [],
    this.lastPositionSeconds = 0.0,
    this.reinitOnSetSource = false,
    this.transitionMode = TransitionMode.seamless,
    this.transitionFadeOutMs = 300,
    this.transitionFadeInMs = 200,
    this.sleepTimerAction = SleepTimerAction.pause,
    this.sharedOutputDevice = '',
    this.wasapiOutputDevice = '',
  });

  Map<String, dynamic> toMap() => {
    'playMode': playMode.name,
    'volumeDsp': volumeDsp,
    'eqGains': eqGains,
    'eqBandModelVersion': currentEqBandModelVersion,
    'eqEnabled': eqEnabled,
    'eqPreampDb': eqPreampDb,
    'eqAutoGainEnabled': eqAutoGainEnabled,
    'eqAutoHeadroomDb': eqAutoHeadroomDb,
    'eqPresets': eqPresets.map((e) => e.toMap()).toList(),
    'audioDspSettings': audioDspSettings.toMap(),
    'lastAudioPath': lastAudioPath,
    'lastPlaylistPaths': lastPlaylistPaths,
    'lastPlaylistIndex': lastPlaylistIndex,
    'lastShuffleActive': lastShuffleActive,
    'lastOriginalPlaylistPaths': lastOriginalPlaylistPaths,
    'lastPositionSeconds': lastPositionSeconds,
    'reinitOnSetSource': reinitOnSetSource,
    'replayGainEnabled': replayGainEnabled,
    'replayGainMode': replayGainMode.name,
    'skipLeadingSilence': skipLeadingSilence,
    'transitionMode': transitionMode.name,
    'transitionFadeOutMs': transitionFadeOutMs,
    'transitionFadeInMs': transitionFadeInMs,
    'sleepTimerAction': sleepTimerAction.name,
    'sharedOutputDevice': sharedOutputDevice,
    'wasapiOutputDevice': wasapiOutputDevice,
  };

  factory PlaybackPreference.fromMap(Object? value) {
    final map = value is Map<String, dynamic>
        ? value
        : const <String, dynamic>{};
    final session = _sessionFromMap(map);
    final legacyOutputDevice = _normalizedOutputDeviceName(
      map['audioOutputDevice'],
    );
    final eq = _eqFromMap(map);
    final transition = _transitionFromMap(map);
    return PlaybackPreference(
      _playModeFromStoredValue(map['playMode']) ?? PlayMode.forward,
      _normalizedVolumeDsp(map['volumeDsp']),
      eq.gains,
      eq.presets,
      eqBandModelVersion: currentEqBandModelVersion,
      eqEnabled: eq.enabled,
      audioDspSettings: eq.dsp,
      eqPreampDb: eq.preampDb,
      eqAutoGainEnabled: eq.autoGainEnabled,
      eqAutoHeadroomDb: eq.autoHeadroomDb,
      lastAudioPath: session.lastAudioPath,
      lastPlaylistPaths: session.lastPlaylistPaths,
      lastPlaylistIndex: session.lastPlaylistIndex,
      lastShuffleActive: session.lastShuffleActive,
      lastOriginalPlaylistPaths: session.lastOriginalPlaylistPaths,
      lastPositionSeconds: session.lastPositionSeconds,
      reinitOnSetSource: session.reinitOnSetSource,
      replayGainEnabled: session.replayGainEnabled,
      replayGainMode: session.replayGainMode,
      skipLeadingSilence: session.skipLeadingSilence,
      transitionMode: transition.mode,
      transitionFadeOutMs: transition.fadeOutMs,
      transitionFadeInMs: transition.fadeInMs,
      sleepTimerAction:
          SleepTimerAction.fromString(
            (map['sleepTimerAction'] as String?) ?? '',
          ) ??
          SleepTimerAction.pause,
      sharedOutputDevice: _normalizedOutputDeviceName(
        map['sharedOutputDevice'] ?? legacyOutputDevice,
      ),
      wasapiOutputDevice: _normalizedOutputDeviceName(
        map['wasapiOutputDevice'] ?? legacyOutputDevice,
      ),
    );
  }

  static String _normalizedOutputDeviceName(Object? value) {
    if (value is! String) return '';
    final trimmed = value.trim();
    return trimmed.length > 256 ? trimmed.substring(0, 256) : trimmed;
  }

  static ({
    String lastAudioPath,
    List<String> lastPlaylistPaths,
    int lastPlaylistIndex,
    bool lastShuffleActive,
    List<String> lastOriginalPlaylistPaths,
    double lastPositionSeconds,
    bool reinitOnSetSource,
    bool replayGainEnabled,
    ReplayGainMode replayGainMode,
    bool skipLeadingSilence,
  })
  _sessionFromMap(Map<String, dynamic> map) {
    final lastPlaylistPaths = _normalizedPathStringList(
      map['lastPlaylistPaths'],
    );
    return (
      lastAudioPath: _normalizedPathString(map['lastAudioPath']),
      lastPlaylistPaths: lastPlaylistPaths,
      lastPlaylistIndex: _normalizedBoundedInt(
        map['lastPlaylistIndex'],
        defaultValue: 0,
        min: 0,
        max: lastPlaylistPaths.isEmpty ? 0 : lastPlaylistPaths.length - 1,
      ),
      lastShuffleActive: _normalizedBool(
        map['lastShuffleActive'],
        defaultValue: false,
      ),
      lastOriginalPlaylistPaths: _normalizedPathStringList(
        map['lastOriginalPlaylistPaths'],
      ),
      lastPositionSeconds: _normalizedBoundedDouble(
        map['lastPositionSeconds'],
        defaultValue: 0.0,
        min: 0.0,
        max: 24 * 60 * 60,
      ),
      reinitOnSetSource: _normalizedBool(
        map['reinitOnSetSource'],
        defaultValue: false,
      ),
      replayGainEnabled: _normalizedBool(
        map['replayGainEnabled'],
        defaultValue: false,
      ),
      replayGainMode: _replayGainModeFromStored(map['replayGainMode']),
      skipLeadingSilence: _normalizedBool(
        map['skipLeadingSilence'],
        defaultValue: false,
      ),
    );
  }

  static ({
    List<double> gains,
    List<EqPreset> presets,
    bool enabled,
    AudioDspSettings dsp,
    double preampDb,
    bool autoGainEnabled,
    double autoHeadroomDb,
  })
  _eqFromMap(Map<String, dynamic> map) {
    return (
      gains: migrateEqGains(
        map['eqGains'],
        fromVersion: _storedEqBandVersion(map),
      ),
      presets: _eqPresetsFromStoredValue(map['eqPresets']),
      enabled: _normalizedBool(map['eqEnabled'], defaultValue: true),
      dsp: AudioDspSettings.fromMap(map['audioDspSettings']),
      preampDb: normalizedEqPreampDb(map['eqPreampDb']),
      autoGainEnabled: _normalizedBool(
        map['eqAutoGainEnabled'],
        defaultValue: true,
      ),
      autoHeadroomDb: _normalizedBoundedDouble(
        map['eqAutoHeadroomDb'],
        defaultValue: 1.0,
        min: 0.0,
        max: 24.0,
      ),
    );
  }

  static ({TransitionMode mode, int fadeOutMs, int fadeInMs})
  _transitionFromMap(Map<String, dynamic> map) {
    return (
      mode: _transitionModeFromStored(map),
      fadeOutMs: _normalizedBoundedInt(
        map['transitionFadeOutMs'],
        defaultValue: 300,
        min: 0,
        max: 10000,
      ),
      fadeInMs: _normalizedBoundedInt(
        map['transitionFadeInMs'],
        defaultValue: 200,
        min: 0,
        max: 10000,
      ),
    );
  }

  static int _storedEqBandVersion(Map<String, dynamic> map) {
    return _normalizedBoundedInt(
      map['eqBandModelVersion'],
      defaultValue: legacyEqBandModelVersion,
      min: legacyEqBandModelVersion,
      max: currentEqBandModelVersion,
    );
  }
}

class PlaybackPreferenceCodec {
  const PlaybackPreferenceCodec._();

  static PlaybackPreference decode(Object? value) =>
      PlaybackPreference.fromMap(value);

  static Map<String, dynamic> encode(PlaybackPreference value) => value.toMap();
}
