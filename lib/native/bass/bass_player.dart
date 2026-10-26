// ignore_for_file: constant_identifier_names

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/audio_dsp_settings.dart';
import 'package:pure_music/core/equalizer_action_state.dart';
import 'package:pure_music/core/window_render_gate.dart';
import 'package:pure_music/native/bass/bass.dart' as bass;
import 'package:pure_music/native/bass/bass_fx.dart';
import 'package:pure_music/native/bass/bass_mix.dart';
import 'package:pure_music/native/bass/bass_wasapi.dart' as bass_wasapi;
import 'package:pure_music/native/bass/bass_url.dart';
import 'package:pure_music/core/utils.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

const int _bassConfigMidiDeffont = 0x10403;

/// 播放预缓冲。解码可以提前准备，不直接等于听到的延迟。
const int _playbackBufferMs = 500;

/// 设备输出缓冲必须在 Init 前设置。500ms 实际不会生效，还会让人误以为暂停很钝；40ms 用来减少偶发破音。
const int _deviceBufferMs = 40;

enum PlayerState {
  /// stop() has been called or the end of an audio has been reached
  stopped,

  /// start() has been called
  playing,

  /// pause() has been called
  paused,

  /// BASS_Pause() has been called or stopping unexpectedly (eg. a USB soundcard being disconnected).
  /// In either case, playback will be resumed by BASS_Start.
  pausedDevice,

  ///Playback of the stream has been stalled due to a lack of sample data.
  ///Playback will automatically resume once there is sufficient data to do so.
  stalled,

  /// the end of an audio has been reached
  completed,

  unknown,
}

enum SpectrumUpdateMode { auto, hz60, hz90, hz120 }

final class GaplessTransition {
  const GaplessTransition({
    required this.id,
    required this.path,
    required this.replayGainDb,
  });

  final int id;
  final String path;
  final double? replayGainDb;
}

final class SmartTransitionPreparation {
  const SmartTransitionPreparation({
    required this.transitionId,
    required this.sourceGeneration,
    required this.mixerHandle,
    required this.outgoingHandle,
    required this.incomingHandle,
    required this.path,
    required this.lengthSeconds,
    required this.replayGainDb,
  });

  final int transitionId;
  final int sourceGeneration;
  final int mixerHandle;
  final int outgoingHandle;
  final int incomingHandle;
  final String path;
  final double? lengthSeconds;
  final double? replayGainDb;
}

/// 一个可选的音频输出设备。
///
/// [name] 用于界面展示和持久化匹配；[id] 仅 WASAPI 提供，是稳定的端点标识；
/// [driver] 仅共享模式提供，是驱动名。序号 [index] 会随设备增减和重启变化，不要持久化。
class AudioOutputDevice {
  const AudioOutputDevice({
    required this.index,
    required this.name,
    required this.isDefault,
    required this.key,
    this.id = '',
    this.driver = '',
  });

  final int index;
  final String name;
  final bool isDefault;
  final String key;
  final String id;
  final String driver;

  @override
  String toString() => 'AudioOutputDevice($index, $name, default=$isDefault)';
}

enum AudioOutputApplyStatus { applied, fellBackToDefault, failed }

class AudioOutputApplyResult {
  const AudioOutputApplyResult({
    required this.status,
    required this.requestedKey,
    required this.activeKey,
    this.error,
  });

  final AudioOutputApplyStatus status;
  final String requestedKey;
  final String activeKey;
  final Object? error;

  bool get succeeded => status != AudioOutputApplyStatus.failed;
}

class BassPlayer {
  static const _eqFxPriority = 1000;
  static const _highPassFxPriority = 900;
  static const _lowPassFxPriority = 890;
  static const _driveFxPriority = 800;
  static const _reverbFxPriority = 700;
  static const _punchFxPriority = 600;
  static const _dspVolumePriority = 100;
  static const _limiterFxPriority = 10;

  late final ffi.DynamicLibrary _bassLib;
  late final bass.Bass _bass;
  late final BassUrl _bassUrl;
  late final bass_wasapi.BassWasapi _bassWasapi;
  ffi.DynamicLibrary? _bassFxLib;
  BassFx? _bassFx;
  ffi.DynamicLibrary? _bassMixLib;
  BassMix? _bassMix;
  BassSync? _bassSync;
  BassChannel? _bassChannel;
  ffi.NativeCallable<BassSyncProc>? _queueSyncCallback;
  ffi.NativeCallable<BassSyncProc>? _posSyncCallback;
  bool get isBassFxLoaded => _bassFx != null;

  late final String _bassDir;

  String? _fPath;
  int? _fstream;
  int? _mixerStream;
  bool _mixerUsesQueue = false;
  int? _queuedStream;
  bool _queuedStreamAttached = false;
  String? _queuedPath;
  double? _queuedLengthSeconds;
  double? _queuedReplayGainDb;
  int? _queuedTransitionId;
  TransitionMode? _queuedTransitionMode;
  int? _activeGaplessTransitionId;
  GaplessTransition? _unreportedGaplessTransition;
  SmartTransitionPreparation? _smartPreparation;
  bool _smartIncomingNativeOwned = false;
  int? _activeSmartTransitionId;
  int? _smartOutgoingStream;
  int _mixerGeneration = 0;
  bool _streamWasapiExclusive = false;
  bool _wasapiInitialized = false;
  bool _wasapiStarted = false;
  bool _freed = false;
  bool _transitionHandledCompletion = false;

  double? _replayGainDb;
  ffi.Pointer<ffi.Void>? _midiFontPathPtr;
  bool _hasMidiSoundfont = false;
  String? _midiFontPath;
  double _baseOutputVolume = 1.0;
  Timer? _outputGainFadeTimer;
  double? _outputGainFadeTarget;

  double? get replayGainDb => _replayGainDb;

  set replayGainDb(double? value) {
    _replayGainDb = value;
    _applyPlaybackGains();
  }

  // Equalizer
  final List<int> _eqHandles = [];
  int _bfxEqHandle = 0;
  final List<double> _eqGains = List.filled(10, 0.0);
  final List<double> _appliedEqGains = List.filled(10, 0.0);
  final List<Timer?> _eqSmoothingTimers = List<Timer?>.filled(10, null);
  Timer? _eqRemovalTimer;
  bool _eqEnabled = true;
  double _eqPreampDb = 0.0;
  AudioDspSettings _audioEffects = const AudioDspSettings();
  final Map<int, int> _dspFxHandles = <int, int>{};
  int? _dspChannel;
  List<double> get eqGains => List.unmodifiable(_eqGains);
  double _rate = 1.0;
  double _pitch = 0.0;

  double get rate => _rate;

  bool get _isEqFlat => !_eqEnabled || _eqGains.every((g) => g.abs() < 1e-6);

  bool get _isDspNeutral => _audioEffects.isNeutral;

  bool get _hasEqFx =>
      _bfxEqHandle != 0 || _eqHandles.any((handle) => handle != 0);

  bool get isEqNeutral =>
      _isEqFlat && (!_eqEnabled || _eqPreampDb.abs() < 1e-6);

  bool get isDspNeutral => _isDspNeutral;

  String get _dspStateLine {
    if (!_audioEffects.enabled && !_audioEffects.limiterEnabled) return 'off';
    final parts = <String>[];
    if (_audioEffects.enabled && _audioEffects.highPassHz > 20.0) {
      parts.add('hp=${_audioEffects.highPassHz.round()}');
    }
    if (_audioEffects.enabled && _audioEffects.lowPassHz < 20000.0) {
      parts.add('lp=${_audioEffects.lowPassHz.round()}');
    }
    if (_audioEffects.enabled && _audioEffects.drive > 0.0001) {
      parts.add('drive=${(_audioEffects.drive * 100).round()}%');
    }
    if (_audioEffects.enabled && _audioEffects.reverb > 0.0001) {
      parts.add('reverb=${(_audioEffects.reverb * 100).round()}%');
    }
    if (_audioEffects.enabled && _audioEffects.punch > 0.0001) {
      parts.add('dyn=${(_audioEffects.punch * 100).round()}%');
    }
    if (_audioEffects.limiterEnabled) {
      parts.add('limit=${_audioEffects.limiterCeilingDb.toStringAsFixed(1)}');
    }
    return parts.isEmpty ? 'on' : parts.join(',');
  }

  List<String> get exclusiveModeConflicts {
    final conflicts = <String>[];
    if (_fstream == null || _fPath == null) {
      conflicts.add('当前没有可用的音频流');
    }
    if (!isEqNeutral) {
      conflicts.add('均衡器或前级增益不是中性');
    }
    if (!_isDspNeutral) {
      conflicts.add('DSP 音效链不是中性');
    }
    if ((_rate - 1.0).abs() > 1e-6) {
      conflicts.add('播放速度不是 1.0x');
    }
    if (_pitch.abs() > 1e-6) {
      conflicts.add('音调不是 0 半音');
    }
    return List.unmodifiable(conflicts);
  }

  /// 共享模式（BASS）输出设备列表；跳过 0 号“无声音”设备。
  List<AudioOutputDevice> listSharedOutputDevices() {
    final devices = <AudioOutputDevice>[];
    final info = calloc<bass.BASS_DEVICEINFO>();
    try {
      for (var index = 1; ; index++) {
        if (_bass.BASS_GetDeviceInfo(index, info) == 0) break;
        final flags = info.ref.flags;
        if (flags & bass.BASS_DEVICE_ENABLED == 0) continue;
        devices.add(
          AudioOutputDevice(
            index: index,
            name: _readBassAnsi(info.ref.name),
            key: _sharedDeviceKey(
              _readBassAnsi(info.ref.driver),
              _readBassAnsi(info.ref.name),
            ),
            driver: _readBassAnsi(info.ref.driver),
            isDefault: flags & bass.BASS_DEVICE_DEFAULT != 0,
          ),
        );
      }
    } finally {
      calloc.free(info);
    }
    return devices;
  }

  /// 独占模式（WASAPI）输出设备列表；只保留可用的输出设备。
  List<AudioOutputDevice> listWasapiOutputDevices() {
    final devices = <AudioOutputDevice>[];
    final info = calloc<bass_wasapi.BASS_WASAPI_DEVICEINFO>();
    try {
      for (var index = 0; ; index++) {
        if (_bassWasapi.BASS_WASAPI_GetDeviceInfo(index, info) == 0) break;
        final flags = info.ref.flags;
        if (flags & bass_wasapi.BASS_WASAPI_DEVICE_ENABLED == 0) continue;
        if (flags & bass_wasapi.BASS_WASAPI_DEVICE_INPUT != 0) continue;
        if (flags & bass_wasapi.BASS_WASAPI_DEVICE_LOOPBACK != 0) continue;
        devices.add(
          AudioOutputDevice(
            index: index,
            name: _readBassAnsi(info.ref.name),
            key: _wasapiDeviceKey(_readBassAnsi(info.ref.id), _readBassAnsi(info.ref.name)),
            id: _readBassAnsi(info.ref.id),
            isDefault: flags & bass_wasapi.BASS_WASAPI_DEVICE_DEFAULT != 0,
          ),
        );
      }
    } finally {
      calloc.free(info);
    }
    return devices;
  }

  static String _readBassAnsi(ffi.Pointer<ffi.Char> pointer) {
    if (pointer == ffi.nullptr) return '';

    if (Platform.isWindows) {
      try {
        final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
        final multiByteToWideChar = kernel32.lookupFunction<
          ffi.Int32 Function(
            ffi.Uint32,
            ffi.Uint32,
            ffi.Pointer<ffi.Char>,
            ffi.Int32,
            ffi.Pointer<Utf16>,
            ffi.Int32,
          ),
          int Function(
            int,
            int,
            ffi.Pointer<ffi.Char>,
            int,
            ffi.Pointer<Utf16>,
            int,
          )
        >('MultiByteToWideChar');
        final length = multiByteToWideChar(
          0, // CP_ACP: Windows 当前系统代码页（中文系统通常是 GBK）
          0,
          pointer,
          -1,
          ffi.nullptr,
          0,
        );
        if (length > 1) {
          final wideUnits = calloc<ffi.Uint16>(length);
          final wide = wideUnits.cast<Utf16>();
          try {
            final written = multiByteToWideChar(
              0,
              0,
              pointer,
              -1,
              wide,
              length,
            );
            if (written > 0) return wide.toDartString();
          } finally {
            calloc.free(wideUnits);
          }
        }
      } catch (_) {
        // 非 Windows 环境或系统 API 不可用时走 UTF-8 兜底。
      }
    }

    final bytes = <int>[];
    final bytePointer = pointer.cast<ffi.Uint8>();
    for (var index = 0; index < 1024; index++) {
      final byte = (bytePointer + index).value;
      if (byte == 0) break;
      bytes.add(byte);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String _normalizeDeviceKey(String value) => value.trim().toLowerCase();

  static String _sharedDeviceKey(String driver, String name) =>
      'shared:${_normalizeDeviceKey(driver)}\u0000${_normalizeDeviceKey(name)}';

  static String _wasapiDeviceKey(String id, String name) =>
      'wasapi:${_normalizeDeviceKey(id.isNotEmpty ? id : name)}';

  /// 返回 null 表示已选择但当前不存在，-1 表示系统默认。
  int? _resolveSharedDeviceIndex(String key) {
    final target = _normalizeDeviceKey(key);
    if (target.isEmpty) return -1;
    for (final device in listSharedOutputDevices()) {
      if (_normalizeDeviceKey(device.key) == target ||
          _normalizeDeviceKey(device.name) == target) {
        return device.index;
      }
    }
    return null;
  }

  /// 返回 null 表示已选择但当前不存在，-1 表示系统默认。
  int? _resolveWasapiDeviceIndex(String key) {
    final target = _normalizeDeviceKey(key);
    if (target.isEmpty) return -1;
    for (final device in listWasapiOutputDevices()) {
      if (_normalizeDeviceKey(device.key) == target ||
          _normalizeDeviceKey(device.name) == target) {
        return device.index;
      }
    }
    return null;
  }

  /// 切换输出设备并保存设置；正在播放时保留播放位置重建输出。
  ///
  /// 返回是否已达到期望的输出模式。设备名不存在时按系统默认设备初始化。
  AudioOutputApplyResult applyOutputDevice(String deviceKey) {
    final normalized = _normalizeDeviceKey(deviceKey);
    final pref = AppPreference.instance.playbackPref;
    final wasExclusive = wasapiExclusive;
    final previous = wasExclusive
        ? pref.wasapiOutputDevice
        : pref.sharedOutputDevice;
    if (previous == normalized) {
      return AudioOutputApplyResult(
        status: AudioOutputApplyStatus.applied,
        requestedKey: normalized,
        activeKey: previous,
      );
    }

    final resolved = wasExclusive
        ? _resolveWasapiDeviceIndex(normalized)
        : _resolveSharedDeviceIndex(normalized);
    final fellBack = normalized.isNotEmpty && resolved == null;
    final effective = fellBack ? '' : normalized;
    if (wasExclusive) {
      pref.wasapiOutputDevice = effective;
    } else {
      pref.sharedOutputDevice = effective;
    }

    final path = _fPath;
    final lastPos = position;
    final wasPlaying = playerState == PlayerState.playing;

    try {
      // 独占模式：先退回共享（按新设备重新初始化），再重新进入独占。
      if (wasExclusive && path != null) {
        if (!useExclusiveMode(false) || !useExclusiveMode(true)) {
          throw const FormatException('无法切换 WASAPI 输出设备');
        }
      } else {
        if (wasExclusive) {
          _releaseWasapiOutput();
          wasapiExclusive = false;
          _streamWasapiExclusive = false;
          onExclusiveModeChanged?.call(false);
        }
        // BASS_Free() 会释放所有句柄，必须先拆掉旧流再重新初始化设备。
        final oldStream = _fstream;
        if (oldStream != null) {
          _bass.BASS_ChannelStop(oldStream);
          _bass.BASS_StreamFree(oldStream);
          _fstream = null;
        }
        _bassInit();
        if (path != null) {
          _positionUpdaterVersion++;
          _positionUpdater?.cancel();
          _positionUpdater = null;
          _createSharedStream(path, lastPos, startPlayback: wasPlaying);
        }
      }
      unawaited(AppPreference.instance.save());
      return AudioOutputApplyResult(
        status: fellBack
            ? AudioOutputApplyStatus.fellBackToDefault
            : AudioOutputApplyStatus.applied,
        requestedKey: normalized,
        activeKey: effective,
      );
    } catch (error, trace) {
      if (wasExclusive) {
        pref.wasapiOutputDevice = previous;
      } else {
        pref.sharedOutputDevice = previous;
      }
      try {
        if (wasExclusive) {
          if (!wasapiExclusive && path != null) {
            useExclusiveMode(true);
          }
        } else {
          final failedStream = _fstream;
          if (failedStream != null) {
            _bass.BASS_ChannelStop(failedStream);
            _bass.BASS_StreamFree(failedStream);
            _fstream = null;
          }
          _bassInit();
          if (path != null) {
            _positionUpdaterVersion++;
            _positionUpdater?.cancel();
            _positionUpdater = null;
            _createSharedStream(path, lastPos, startPlayback: wasPlaying);
          }
        }
      } catch (restoreError, restoreTrace) {
        log.bass.error(
          'legacy',
          '[bass] output device rollback failed',
          error: restoreError,
          stackTrace: restoreTrace,
        );
      }
      log.bass.error(
        'legacy',
        '[bass] output device switch failed',
        error: error,
        stackTrace: trace,
      );
      return AudioOutputApplyResult(
        status: AudioOutputApplyStatus.failed,
        requestedKey: normalized,
        activeKey: previous,
        error: error,
      );
    }
  }

  /// 是否启用 wasapi 独占模式
  bool wasapiExclusive = false;
  String _wasapiOutputInfo = 'off';

  Timer? _fadeInTimer;

  /// 暂停淡出：淡出完成前不真正暂停，期间可被播放/换源打断
  Timer? _pauseFadeTimer;
  int? _pauseFadeHandle;
  double _pauseFadeGain = 1.0;
  static const int _pauseFadeMs = 150;

  /// 淡出旧流时延迟释放资源的定时器
  Timer? _fadeOutTimer;
  int? _fadeOutHandle;
  bool _fadeOutRemoveFromMixer = false;

  /// 自动切歌过渡（淡入淡出/交叉淡化）状态
  Timer? _transitionTimer;
  Timer? _handledCompletionClearTimer;
  int? _transitionOldStream;
  int? _transitionSyncHandle;
  int? _transitionSyncChannel;
  int _transitionGeneration = 0;

  /// 独占模式状态变化回调
  void Function(bool)? onExclusiveModeChanged;

  /// 打开中的音频文件有变化时通知。用来把标签写入推迟到文件松开之后。
  void Function()? onAudioFilesChanged;
  String? _lingeringPath;
  String? _smartOutgoingPath;

  bool isAudioFileOpen(String path) {
    final key = path.toLowerCase();
    bool same(String? candidate) =>
        candidate != null && candidate.toLowerCase() == key;
    if (_fstream != null && same(_fPath)) return true;
    if (_queuedStream != null && same(_queuedPath)) return true;
    if (_smartPreparation != null && same(_smartPreparation!.path)) {
      return true;
    }
    if ((_fadeOutHandle != null || _transitionOldStream != null) &&
        same(_lingeringPath)) {
      return true;
    }
    if (_smartOutgoingStream != null && same(_smartOutgoingPath)) return true;
    return false;
  }

  void _publishAudioFiles() {
    onAudioFilesChanged?.call();
  }

  /// 同步阻塞 Sleep 函数（Windows kernel32.dll）
  void Function(int milliseconds)? _windowsSleep;

  /// 同步阻塞等待指定毫秒数（必须用于同步函数中的延迟）
  void _sleepSync(int ms) {
    if (_windowsSleep != null) {
      _windowsSleep!(ms);
    } else {
      // 回退到忙等待（非 Windows 或 kernel32 加载失败）
      final end = DateTime.now().millisecondsSinceEpoch + ms;
      while (DateTime.now().millisecondsSinceEpoch < end) {}
    }
  }

  Timer? _positionUpdater;
  Duration? _positionUpdaterPeriod;
  int _positionUpdaterVersion = 0;
  bool _windowGateListening = false;

  // 窗口可见性变化时立即切换定时器间隔。
  void _listenWindowGateOnce() {
    if (_windowGateListening) return;
    _windowGateListening = true;
    WindowRenderGate.instance.framesEnabled.addListener(
      _syncPositionUpdaterPeriod,
    );
  }

  late final StreamController<double> _positionStreamController;
  late final StreamController<Float32List> _spectrumStreamController;
  late final StreamController<Float32List> _spectrumDisplayStreamController;
  late final StreamController<GaplessTransition>
  _gaplessTransitionStreamController;
  final _playerStateStreamController =
      StreamController<PlayerState>.broadcast();

  int? get _sharedOutputHandle => _mixerStream ?? _fstream;
  int? get _effectHandle => _mixerStream ?? _fstream;
  int? _eqChannel;

  bool get canUseGaplessPlayback =>
      _mixerStream != null && !wasapiExclusive && !_streamWasapiExclusive;

  bool get canUseSmartTransition =>
      canUseGaplessPlayback &&
      !_mixerUsesQueue &&
      _queuedStream == null &&
      _smartPreparation == null &&
      _activeSmartTransitionId == null;

  String get bassDirectory => _bassDir;

  bool get hasMidiSoundfont => _hasMidiSoundfont;

  static bool isMidiPath(String audioPath) {
    final ext = path.extension(audioPath).toLowerCase();
    return ext == '.mid' || ext == '.midi' || ext == '.kar' || ext == '.rmi';
  }

  bool setMidiSoundfontPath(String? fontPath) {
    final trimmed = fontPath?.trim() ?? '';
    _releaseMidiFontPointer();
    if (trimmed.isEmpty || !File(trimmed).existsSync()) {
      _midiFontPath = null;
      _bass.BASS_SetConfigPtr(_bassConfigMidiDeffont, ffi.nullptr);
      _hasMidiSoundfont = false;
      return false;
    }
    _bass.BASS_SetConfig(bass.BASS_CONFIG_UNICODE, bass.TRUE);
    final pointer = trimmed.toNativeUtf16().cast<ffi.Void>();
    final ok = _bass.BASS_SetConfigPtr(_bassConfigMidiDeffont, pointer) != 0;
    if (!ok) {
      malloc.free(pointer);
      _midiFontPath = null;
      _hasMidiSoundfont = false;
      log.bass.warn(
        'legacy',
        '[bass] set midi soundfont failed: ${_bass.BASS_ErrorGetCode()}',
      );
      return false;
    }
    _midiFontPathPtr = pointer;
    _midiFontPath = trimmed;
    _hasMidiSoundfont = true;
    return true;
  }

  void _releaseMidiFontPointer() {
    if (_midiFontPathPtr == null) return;
    malloc.free(_midiFontPathPtr!);
    _midiFontPathPtr = null;
  }

  void _reapplyMidiSoundfont() {
    final saved = _midiFontPath;
    if (saved == null || saved.isEmpty) return;
    setMidiSoundfontPath(saved);
  }

  int get sourceGeneration => _mixerGeneration;

  bool get hasGaplessMixer => _mixerStream != null;

  Stream<GaplessTransition> get gaplessTransitionStream =>
      _gaplessTransitionStreamController.stream;

  void _logAudioState(String tag) {
    final wasapiStarted = _bassWasapi.BASS_WASAPI_IsStarted() == bass.TRUE;
    final eqCount =
        (_bfxEqHandle != 0 ? 1 : 0) + _eqHandles.where((e) => e != 0).length;
    log.bass.debug(
      'legacy',
      '[bass] $tag | exclusive=$wasapiExclusive streamExclusive=$_streamWasapiExclusive '
          'wasapiStarted=$wasapiStarted handle=$_fstream mixer=$_mixerStream queued=$_queuedStream '
          'smart=${_smartPreparation?.transitionId ?? _activeSmartTransitionId} '
          'eq=$eqCount eqFlat=${isEqNeutral ? 1 : 0} '
          'dsp=$_dspStateLine volume=${_baseOutputVolume.toStringAsFixed(3)} '
          'rate=$_rate pitch=$_pitch sampleRate=${_streamSampleRate.round()}Hz '
          'wasapi=$_wasapiOutputInfo',
    );
  }

  String get debugStateLine {
    final wasapiStarted = _bassWasapi.BASS_WASAPI_IsStarted() == bass.TRUE;
    final eqCount =
        (_bfxEqHandle != 0 ? 1 : 0) + _eqHandles.where((e) => e != 0).length;
    return 'exclusive=$wasapiExclusive streamExclusive=$_streamWasapiExclusive '
        'wasapiStarted=$wasapiStarted handle=$_fstream mixer=$_mixerStream queued=$_queuedStream '
        'smart=${_smartPreparation?.transitionId ?? _activeSmartTransitionId} '
        'eq=$eqCount eqFlat=${isEqNeutral ? 1 : 0} '
        'dsp=$_dspStateLine volume=${_baseOutputVolume.toStringAsFixed(3)} '
        'rate=$_rate pitch=$_pitch sampleRate=${_streamSampleRate.round()}Hz '
        'wasapi=$_wasapiOutputInfo';
  }

  /// audio's length in seconds
  double get length {
    _promoteDequeuedSource();
    if (_fstream == null) return 1.0;
    final cached = _cachedLengthSeconds;
    if (cached != null && cached > 0) return cached;
    return _refreshCachedLength();
  }

  double _refreshCachedLength() {
    if (_fstream == null) {
      _cachedLengthSeconds = null;
      return 1.0;
    }
    final len = _bass.BASS_ChannelBytes2Seconds(
      _fstream!,
      _bass.BASS_ChannelGetLength(_fstream!, bass.BASS_POS_BYTE),
    );
    final value = len > 0 ? len : 1.0;
    _cachedLengthSeconds = value;
    return value;
  }

  /// current position in seconds
  double get position {
    _promoteDequeuedSource();
    return _fstream == null ? 0.0 : _getPosition();
  }

  double _getPosition() {
    final source = _fstream!;
    final posBytes = _mixerStream == null
        ? _bass.BASS_ChannelGetPosition(source, bass.BASS_POS_BYTE)
        : _bassMix!.channelGetPosition(source, bass.BASS_POS_BYTE);
    if (posBytes == -1) {
      final errCode = _bass.BASS_ErrorGetCode();
      if (errCode == bass.BASS_ERROR_HANDLE) {
        if (_mixerStream != null) {
          if (_promoteDequeuedSource() != null) return _getPosition();
        } else {
          freeFStream();
        }
      }
      return 0.0;
    }

    // 独占模式下，需要减去 WASAPI 缓冲区残留
    var finalBytes = posBytes;
    if (wasapiExclusive || _streamWasapiExclusive) {
      final decodeBytes = _bassWasapi.BASS_WASAPI_GetData(
        ffi.nullptr,
        bass_wasapi.BASS_DATA_AVAILABLE,
      );
      if (decodeBytes > 0 && decodeBytes != -1) {
        finalBytes = finalBytes - decodeBytes;
      }
    }

    return _bass.BASS_ChannelBytes2Seconds(
      _fstream!,
      finalBytes,
    ).clamp(0.0, length);
  }

  PlayerState get playerState {
    _promoteDequeuedSource();
    if (_fstream == null) {
      return PlayerState.unknown;
    }
    if (_pauseFadeTimer != null) return PlayerState.paused;

    switch (_bass.BASS_ChannelIsActive(_sharedOutputHandle!)) {
      case bass.BASS_ACTIVE_STOPPED:
        return PlayerState.stopped;
      case bass.BASS_ACTIVE_PLAYING:
        if (wasapiExclusive) {
          /// wasapi exclusive's channel is a decoding channel,
          /// will be BASS_ACTIVE_PLAYING as long as there is still data to decode.
          /// So here we check BASS_WASAPI_IsStarted to
          /// judge between BASS_ACTIVE_PLAYING and BASS_ACTIVE_PAUSED
          return _bassWasapi.BASS_WASAPI_IsStarted() == bass.TRUE
              ? PlayerState.playing
              : PlayerState.paused;
        }
        return PlayerState.playing;
      case bass.BASS_ACTIVE_PAUSED:
        return PlayerState.paused;
      case bass.BASS_ACTIVE_PAUSED_DEVICE:
        return PlayerState.pausedDevice;
      case bass.BASS_ACTIVE_STALLED:
        return PlayerState.stalled;
      default:
        return PlayerState.unknown;
    }
  }

  double get volumeDsp {
    return _baseOutputVolume;
  }

  /// update every 33ms
  Stream<double> get positionStream => _positionStreamController.stream;

  Stream<Float32List> get spectrumStream => _spectrumStreamController.stream;

  /// 播放页频谱条用的细分段频谱（与 [spectrumStream] 同源同节奏，互不影响）。
  Stream<Float32List> get spectrumDisplayStream =>
      _spectrumDisplayStreamController.stream;

  Stream<PlayerState> get playerStateStream =>
      _playerStateStreamController.stream;

  static const int _bassDataFft512 = 0x80000001;
  int Function(int, ffi.Pointer<ffi.Void>, int)? _bassChannelGetData;
  ffi.Pointer<ffi.Float>? _fftBuffer;
  ffi.Pointer<ffi.Float>? _wasapiFftBuffer;
  ffi.Pointer<ffi.Float>? _freqAttrPtr;
  double? _cachedLengthSeconds;
  double _streamSampleRate = 44100.0;
  double get streamSampleRate => _streamSampleRate;
  bool get hasAudioSource => _fstream != null && _fPath != null;
  int _lastSpectrumUpdateUs = 0;
  final Stopwatch _spectrumClock = Stopwatch()..start();
  Duration _spectrumTickPeriod = const Duration(milliseconds: 66);
  SpectrumUpdateMode spectrumUpdateMode = SpectrumUpdateMode.auto;
  static const int _spectrumBandCount = 8;
  static const int _activeSpectrumBandCount = 4;
  static final double _spectrumLogDenominator = math.log(19.0);
  final Float32List _spectrumSmoothed = Float32List(8);
  final Float32List _spectrumBands = Float32List(_spectrumBandCount);
  final Float32List _spectrumOutputA = Float32List(_spectrumBandCount);
  final Float32List _spectrumOutputB = Float32List(_spectrumBandCount);
  bool _useSpectrumOutputA = true;
  final Int32List _spectrumBandStarts = Int32List(_spectrumBandCount);
  final Int32List _spectrumBandEnds = Int32List(_spectrumBandCount);
  double _spectrumBandsSampleRate = 0.0;

  // 频谱条：32 段、独立平滑与输出缓冲，不与流光那条流互相干扰
  static const int _displaySpectrumBandCount = 64;
  final Float32List _displaySpectrumBands = Float32List(
    _displaySpectrumBandCount,
  );
  final Float32List _displaySpectrumSmoothed = Float32List(
    _displaySpectrumBandCount,
  );
  final Float32List _displaySpectrumOutputA = Float32List(
    _displaySpectrumBandCount,
  );
  final Float32List _displaySpectrumOutputB = Float32List(
    _displaySpectrumBandCount,
  );
  bool _useDisplaySpectrumOutputA = true;
  final Int32List _displaySpectrumBandStarts = Int32List(
    _displaySpectrumBandCount,
  );
  final Int32List _displaySpectrumBandEnds = Int32List(
    _displaySpectrumBandCount,
  );
  double _displaySpectrumBandsSampleRate = 0.0;
  bool get _hasAnySpectrumListener =>
      _spectrumStreamController.hasListener ||
      _spectrumDisplayStreamController.hasListener;

  void setSpectrumUpdateMode(SpectrumUpdateMode mode) {
    spectrumUpdateMode = mode;
    _spectrumTickPeriod = _computeSpectrumTickPeriod();
    _lastSpectrumUpdateUs = 0;
  }

  Timer _getPositionUpdater(Duration period) {
    final myVersion = _positionUpdaterVersion;
    PlayerState? lastNotifiedState;
    var tick = 0;
    final stateCheckEvery = math.max(
      1,
      (const Duration(milliseconds: 200).inMicroseconds / period.inMicroseconds)
          .round(),
    );
    return Timer.periodic(period, (timer) {
      // 如果版本号已变更（切歌了），立即停止此 Timer
      if (myVersion != _positionUpdaterVersion) {
        timer.cancel();
        // 如果当前 Timer 是 _positionUpdater，清除引用以便 GC
        if (_positionUpdater == timer) {
          _positionUpdater = null;
        }
        return;
      }
      _emitPositionSnapshot();

      /// check if the channel has completed
      tick++;
      if (tick % stateCheckEvery != 0) {
        _maybeUpdateSpectrum();
        return;
      }
      final currentState = playerState;
      final emit = playbackStateToEmit(
        lastNotified: lastNotifiedState,
        current: currentState,
        suppressCompletion: _transitionHandledCompletion,
      );
      if (emit != null) {
        lastNotifiedState = emit;
        _playerStateStreamController.add(emit);
      }

      _maybeUpdateSpectrum(knownState: currentState);
    });
  }

  void _emitPositionSnapshot() {
    if (_positionStreamController.hasListener) {
      _positionStreamController.add(position);
    }
  }

  Duration _computePlayingTickPeriod() {
    return const Duration(milliseconds: 33);
  }

  Duration _computeIdleTickPeriod() {
    return const Duration(milliseconds: 200);
  }

  Duration _computeActiveTickPeriod() {
    if (!WindowRenderGate.instance.framesEnabled.value) {
      return _computeHiddenTickPeriod();
    }
    if (_positionStreamController.hasListener) {
      return _computePlayingTickPeriod();
    }
    if (_hasAnySpectrumListener) {
      return _computeSpectrumTickPeriod();
    }
    return _computeIdleTickPeriod();
  }

  Duration _computeHiddenTickPeriod() {
    return const Duration(seconds: 1);
  }

  void _startPositionUpdater() {
    if (_fstream == null) return;
    _listenWindowGateOnce();
    final period = _computeActiveTickPeriod();
    if (_positionUpdater != null && _positionUpdaterPeriod == period) return;
    _positionUpdaterVersion++;
    _positionUpdater?.cancel();
    _positionUpdaterPeriod = period;
    _positionUpdater = _getPositionUpdater(period);
  }

  void _syncPositionUpdaterPeriod() {
    if (_positionUpdater == null || playerState != PlayerState.playing) return;
    final period = _computeActiveTickPeriod();
    if (_positionUpdaterPeriod == period) return;
    _startPositionUpdater();
  }

  Duration _computeSpectrumTickPeriod() {
    return const Duration(milliseconds: 66);
  }

  void _refreshStreamSampleRate() {
    final handle = _sharedOutputHandle;
    if (handle == null) return;
    _freqAttrPtr ??= malloc.allocate<ffi.Float>(ffi.sizeOf<ffi.Float>());
    final freqPtr = _freqAttrPtr!;
    final ok = _bass.BASS_ChannelGetAttribute(
      handle,
      bass.BASS_ATTRIB_FREQ,
      freqPtr,
    );
    if (ok != 0 && freqPtr.value.isFinite && freqPtr.value > 1.0) {
      final nextRate = freqPtr.value.toDouble();
      if ((_streamSampleRate - nextRate).abs() > 1e-3) {
        _streamSampleRate = nextRate;
        _spectrumBandsSampleRate = 0.0;
      }
    }
  }

  /// 根据音频采样率动态计算 WASAPI 缓冲区大小
  /// 过小的缓冲会在 GC 抖动/IO 延迟时导致缓冲区欠载，产生哒哒哒的卡顿音
  double _computeWasapiBufferSec() {
    _refreshStreamSampleRate();
    if (_streamSampleRate <= 44100) return 0.10;
    if (_streamSampleRate <= 48000) return 0.12;
    if (_streamSampleRate <= 96000) return 0.15;
    return 0.20;
  }

  void _refreshWasapiOutputInfo(double requestedBufferSec) {
    final info = calloc<bass_wasapi.BASS_WASAPI_INFO>();
    try {
      if (_bassWasapi.BASS_WASAPI_GetInfo(info) == bass.FALSE) {
        _wasapiOutputInfo =
            'unknown requested=2x${(requestedBufferSec * 1000).round()}ms async=1';
        return;
      }
      final value = info.ref;
      final format = switch (value.format) {
        bass_wasapi.BASS_WASAPI_FORMAT_FLOAT => ('float32', 4),
        bass_wasapi.BASS_WASAPI_FORMAT_8BIT => ('8bit', 1),
        bass_wasapi.BASS_WASAPI_FORMAT_16BIT => ('16bit', 2),
        bass_wasapi.BASS_WASAPI_FORMAT_24BIT => ('24bit', 3),
        bass_wasapi.BASS_WASAPI_FORMAT_32BIT => ('32bit', 4),
        _ => ('format${value.format}', 0),
      };
      final frameBytes = value.chans * format.$2;
      final bufferMs = value.freq > 0 && frameBytes > 0
          ? (value.buflen * 1000 / value.freq / frameBytes).round()
          : 0;
      _wasapiOutputInfo =
          '${value.freq}Hz/${format.$1}/${value.chans}ch '
          'buffer=${bufferMs}ms(${value.buflen}B) '
          'requested=2x${(requestedBufferSec * 1000).round()}ms async=1';
      log.bass.debug('legacy', '[bass] wasapi output $_wasapiOutputInfo');
    } finally {
      calloc.free(info);
    }
  }

  void _maybeUpdateSpectrum({PlayerState? knownState}) {
    if (_fstream == null) return;
    // 窗口不可见时不取频谱数据，避免 FFT 和无谓的缓冲分配。
    if (!WindowRenderGate.instance.framesEnabled.value) return;
    if (!_hasAnySpectrumListener) return;
    final state = knownState ?? playerState;
    if (state != PlayerState.playing) return;

    // Exclusive mode uses BASS_WASAPI_GetData (separate path),
    // shared mode uses BASS_ChannelGetData. Neither is blocked now.
    if (_bassChannelGetData == null &&
        !wasapiExclusive &&
        !_streamWasapiExclusive) {
      return;
    }

    final nowUs = _spectrumClock.elapsedMicroseconds;
    final intervalUs = _spectrumTickPeriod.inMicroseconds;
    if (nowUs - _lastSpectrumUpdateUs < intervalUs) return;
    _lastSpectrumUpdateUs = nowUs;

    if (wasapiExclusive || _streamWasapiExclusive) {
      _emitWasapiSpectrumFrame();
    } else {
      _emitSpectrumFrame();
    }
  }

  void _emitSpectrumFrame() {
    final handle = _sharedOutputHandle;
    if (handle == null) return;
    if (!_hasAnySpectrumListener) return;
    final getData = _bassChannelGetData;
    if (getData == null) return;

    _fftBuffer ??= malloc.allocate<ffi.Float>(256 * ffi.sizeOf<ffi.Float>());
    final bytesRead = getData(
      handle,
      _fftBuffer!.cast<ffi.Void>(),
      _bassDataFft512,
    );
    if (bytesRead <= 0) return;

    _emitSpectrumOutputs(_fftBuffer!.asTypedList(256));
  }

  void _emitWasapiSpectrumFrame() {
    if (!_hasAnySpectrumListener) return;

    _wasapiFftBuffer ??= malloc.allocate<ffi.Float>(
      256 * ffi.sizeOf<ffi.Float>(),
    );
    final bytesRead = _bassWasapi.BASS_WASAPI_GetData(
      _wasapiFftBuffer!.cast<ffi.Void>(),
      bass_wasapi.BASS_DATA_FFT512,
    );
    // BASS_WASAPI_GetData returns the number of bytes written; negative means error
    if (bytesRead <= 0) return;

    _emitSpectrumOutputs(_wasapiFftBuffer!.asTypedList(256));
  }

  void _emitSmoothedSpectrum() {
    final out = _useSpectrumOutputA ? _spectrumOutputA : _spectrumOutputB;
    _useSpectrumOutputA = !_useSpectrumOutputA;
    for (int i = 0; i < _activeSpectrumBandCount; i++) {
      final target = _spectrumBands[i];
      final prev = _spectrumSmoothed[i];
      // Attack/release IIR: fast rise (0.6), slower fall (0.4)
      final a = target > prev ? 0.6 : 0.4;
      final next = (prev + (target - prev) * a).clamp(0.0, 1.0).toDouble();
      _spectrumSmoothed[i] = next;
      out[i] = next;
    }
    for (int i = _activeSpectrumBandCount; i < _spectrumBandCount; i++) {
      _spectrumSmoothed[i] = 0.0;
      out[i] = 0.0;
    }
    _spectrumStreamController.add(out);
  }

  /// 同一帧 FFT 分别发给流光（8 段）与频谱条（64 段），各自只关心自己的监听者。
  void _emitSpectrumOutputs(Float32List fft) {
    if (_spectrumStreamController.hasListener) {
      _computeSpectrum8Into(fft, _streamSampleRate, _spectrumBands);
      _emitSmoothedSpectrum();
    }
    if (_spectrumDisplayStreamController.hasListener) {
      _computeDisplaySpectrumInto(fft, _streamSampleRate);
      _emitSmoothedDisplaySpectrum();
    }
  }

  void _resetSpectrumSmoothing() {
    _spectrumBands.fillRange(0, _spectrumBands.length, 0.0);
    _spectrumSmoothed.fillRange(0, _spectrumSmoothed.length, 0.0);
    _displaySpectrumBands.fillRange(0, _displaySpectrumBands.length, 0.0);
    _displaySpectrumSmoothed.fillRange(0, _displaySpectrumSmoothed.length, 0.0);
    _lastSpectrumUpdateUs = 0;
  }

  void _ensureSpectrumBandBins(double sampleRate) {
    const fftSize = 512.0;
    const minF = 45.0;
    const maxF = 16000.0;
    if ((_spectrumBandsSampleRate - sampleRate).abs() < 1e-3 &&
        _spectrumBandsSampleRate > 0) {
      return;
    }

    final nyquist = sampleRate * 0.5;
    final clampedMaxF = math.min(maxF, nyquist - 1.0);
    if (clampedMaxF <= minF || nyquist <= 1.0) {
      for (int i = 0; i < _spectrumBandCount; i++) {
        _spectrumBandStarts[i] = 1;
        _spectrumBandEnds[i] = 2;
      }
      _spectrumBandsSampleRate = sampleRate;
      return;
    }

    final ratio = clampedMaxF / minF;
    for (int i = 0; i < _spectrumBandCount; i++) {
      final a = i / _spectrumBandCount;
      final b = (i + 1) / _spectrumBandCount;
      final fa = minF * math.pow(ratio, a).toDouble();
      final fb = minF * math.pow(ratio, b).toDouble();
      final start = ((fa / sampleRate) * fftSize).floor().clamp(1, 255).toInt();
      final end = ((fb / sampleRate) * fftSize)
          .ceil()
          .clamp(start + 1, 255)
          .toInt();
      _spectrumBandStarts[i] = start;
      _spectrumBandEnds[i] = end;
    }
    _spectrumBandsSampleRate = sampleRate;
  }

  void _computeSpectrum8Into(
    Float32List fft,
    double sampleRate,
    Float32List out,
  ) {
    _ensureSpectrumBandBins(sampleRate);

    for (int i = 0; i < _activeSpectrumBandCount; i++) {
      final start = _spectrumBandStarts[i];
      final end = _spectrumBandEnds[i];
      double m = 0.0;
      for (int k = start; k < end; k++) {
        final v = fft[k];
        if (v.isFinite && v > m) m = v.toDouble();
      }
      out[i] = (math.log(1.0 + m * 18.0) / _spectrumLogDenominator)
          .clamp(0.0, 1.0)
          .toDouble();
    }
  }

  void _ensureDisplaySpectrumBandBins(double sampleRate) {
    const fftSize = 512.0;
    const minF = 45.0;
    const maxF = 16000.0;
    if ((_displaySpectrumBandsSampleRate - sampleRate).abs() < 1e-3 &&
        _displaySpectrumBandsSampleRate > 0) {
      return;
    }

    final nyquist = sampleRate * 0.5;
    final clampedMaxF = math.min(maxF, nyquist - 1.0);
    if (clampedMaxF <= minF || nyquist <= 1.0) {
      for (int i = 0; i < _displaySpectrumBandCount; i++) {
        _displaySpectrumBandStarts[i] = 1;
        _displaySpectrumBandEnds[i] = 2;
      }
      _displaySpectrumBandsSampleRate = sampleRate;
      return;
    }

    final ratio = clampedMaxF / minF;
    for (int i = 0; i < _displaySpectrumBandCount; i++) {
      final a = i / _displaySpectrumBandCount;
      final b = (i + 1) / _displaySpectrumBandCount;
      final fa = minF * math.pow(ratio, a).toDouble();
      final fb = minF * math.pow(ratio, b).toDouble();
      final start = ((fa / sampleRate) * fftSize).floor().clamp(1, 255).toInt();
      final end = ((fb / sampleRate) * fftSize)
          .ceil()
          .clamp(start + 1, 255)
          .toInt();
      _displaySpectrumBandStarts[i] = start;
      _displaySpectrumBandEnds[i] = end;
    }
    _displaySpectrumBandsSampleRate = sampleRate;
  }

  void _computeDisplaySpectrumInto(Float32List fft, double sampleRate) {
    _ensureDisplaySpectrumBandBins(sampleRate);

    for (int i = 0; i < _displaySpectrumBandCount; i++) {
      final start = _displaySpectrumBandStarts[i];
      final end = _displaySpectrumBandEnds[i];
      double m = 0.0;
      for (int k = start; k < end; k++) {
        final v = fft[k];
        if (v.isFinite && v > m) m = v.toDouble();
      }
      _displaySpectrumBands[i] =
          (math.log(1.0 + m * 18.0) / _spectrumLogDenominator)
              .clamp(0.0, 1.0)
              .toDouble();
    }
  }

  void _emitSmoothedDisplaySpectrum() {
    final out = _useDisplaySpectrumOutputA
        ? _displaySpectrumOutputA
        : _displaySpectrumOutputB;
    _useDisplaySpectrumOutputA = !_useDisplaySpectrumOutputA;
    for (int i = 0; i < _displaySpectrumBandCount; i++) {
      final target = _displaySpectrumBands[i];
      final prev = _displaySpectrumSmoothed[i];
      // 快起慢落，柱条跳动更干脆
      final a = target > prev ? 0.72 : 0.28;
      final next = (prev + (target - prev) * a).clamp(0.0, 1.0).toDouble();
      _displaySpectrumSmoothed[i] = next;
      out[i] = next;
    }
    _spectrumDisplayStreamController.add(out);
  }

  void setEQ(int band, double gain) {
    if (band < 0 || band >= 10) return;
    _eqRemovalTimer?.cancel();
    _eqRemovalTimer = null;
    final wasFlat = _isEqFlat;
    _eqGains[band] = gain.isFinite
        ? gain.clamp(eqGainMinDb, eqGainMaxDb).toDouble()
        : 0.0;
    if (_fstream == null) return;

    if (wasapiExclusive) {
      if (!isEqNeutral) {
        log.bass.warn(
          'legacy',
          '[bass] EQ enabled in exclusive mode, keep shared mode',
        );
        useExclusiveMode(false);
      }
      return;
    }

    if (_isEqFlat) {
      if (!wasFlat) {
        _fadeOutEQ();
      }
      return;
    }

    if (!_hasEqFx) {
      _initEQ();
    }

    _smoothEQBand(band, targetGain: _eqEnabled ? _eqGains[band] : 0.0);
  }

  void applyEqGains(Iterable<double> gains, {bool smooth = true}) {
    _eqRemovalTimer?.cancel();
    _eqRemovalTimer = null;
    final wasFlat = _isEqFlat;
    final values = gains.toList(growable: false);
    for (var i = 0; i < eqBandCount; i++) {
      final value = i < values.length ? values[i] : 0.0;
      _eqGains[i] = value.isFinite
          ? value.clamp(eqGainMinDb, eqGainMaxDb).toDouble()
          : 0.0;
    }
    if (_fstream == null) return;

    if (wasapiExclusive) {
      if (!isEqNeutral) useExclusiveMode(false);
      return;
    }
    if (_isEqFlat) {
      if (!wasFlat) {
        _fadeOutEQ();
      } else {
        _removeEQ();
      }
      return;
    }
    if (!_hasEqFx) _initEQ();
    for (var i = 0; i < eqBandCount; i++) {
      final target = _eqEnabled ? _eqGains[i] : 0.0;
      if (smooth) {
        _smoothEQBand(i, targetGain: target);
      } else {
        _eqSmoothingTimers[i]?.cancel();
        _eqSmoothingTimers[i] = null;
        _appliedEqGains[i] = target;
        _updateEQ(i);
      }
    }
  }

  void setEqPreampDb(double value) {
    _eqPreampDb = value.isFinite
        ? value.clamp(eqPreampMinDb, eqPreampMaxDb).toDouble()
        : 0.0;
    if (wasapiExclusive && !isEqNeutral) {
      useExclusiveMode(false);
    }
  }

  void setEqEnabled(bool enabled) {
    if (_eqEnabled == enabled) return;
    final wasFlat = _isEqFlat;
    _eqEnabled = enabled;
    if (_fstream == null) return;
    if (enabled && wasapiExclusive && !isEqNeutral) {
      useExclusiveMode(false);
      return;
    }
    if (!enabled && !wasFlat && !wasapiExclusive) {
      _fadeOutEQ();
      return;
    }
    refreshEQ();
  }

  void setAudioEffects(AudioDspSettings settings) {
    _audioEffects = settings.normalized();
    if (_fstream == null) return;
    if (!_isDspNeutral && wasapiExclusive) {
      useExclusiveMode(false);
      return;
    }
    refreshAudioEffects();
  }

  void _smoothEQBand(int band, {double? targetGain}) {
    _eqSmoothingTimers[band]?.cancel();
    final start = _appliedEqGains[band];
    final target = targetGain ?? _eqGains[band];
    if ((start - target).abs() < 0.01) {
      _appliedEqGains[band] = target;
      _updateEQ(band);
      return;
    }
    const steps = 6;
    var step = 0;
    _eqSmoothingTimers[band] = Timer.periodic(
      const Duration(milliseconds: 10),
      (timer) {
        step++;
        _appliedEqGains[band] = start + (target - start) * step / steps;
        _updateEQ(band);
        if (step >= steps) {
          timer.cancel();
          _eqSmoothingTimers[band] = null;
        }
      },
    );
  }

  void _fadeOutEQ() {
    if (_eqChannel == null && !_hasEqFx) {
      return;
    }
    for (var i = 0; i < eqBandCount; i++) {
      _smoothEQBand(i, targetGain: 0.0);
    }
    _eqRemovalTimer?.cancel();
    _eqRemovalTimer = Timer(const Duration(milliseconds: 70), () {
      _eqRemovalTimer = null;
      if (_isEqFlat) _removeEQ();
    });
  }

  void refreshEQ() {
    if (_fstream == null) return;
    if (wasapiExclusive || _isEqFlat) {
      _removeEQ();
      return;
    }
    _cancelEqSmoothing();
    if (!_hasEqFx) {
      _initEQ();
    } else {
      for (int i = 0; i < 10; i++) {
        _appliedEqGains[i] = _eqGains[i];
        _updateEQ(i);
      }
    }
  }

  void _initEQ() {
    final channel = _effectHandle;
    if (channel == null) return;
    _eqChannel = channel;

    if (_bassFx != null) {
      _bfxEqHandle = _bass.BASS_ChannelSetFX(
        channel,
        bass.BASS_FX_BFX_PEAKEQ,
        _eqFxPriority,
      );
      if (_bfxEqHandle != 0) {
        for (int i = 0; i < 10; i++) {
          _appliedEqGains[i] = _eqGains[i];
          _updateEQ(i);
        }
        return;
      }
      log.bass.warn(
        'legacy',
        'Failed to set BFX EQ: BASS Error ${_bass.BASS_ErrorGetCode()}',
      );
      _bfxEqHandle = 0;
    }

    _eqHandles
      ..clear()
      ..addAll(List.filled(10, 0));

    try {
      for (int i = 0; i < 10; i++) {
        final fx = _bass.BASS_ChannelSetFX(
          channel,
          bass.BASS_FX_DX8_PARAMEQ,
          _eqFxPriority,
        );

        if (fx == 0) {
          final err = _bass.BASS_ErrorGetCode();
          log.bass.warn('legacy', 'Failed to set EQ band $i: BASS Error $err');
          continue;
        }

        _eqHandles[i] = fx;
        _updateEQ(i);
      }
    } catch (e) {
      log.bass.error('legacy', 'Error initializing EQ: $e');
    }
  }

  void _updateEQ(int band) {
    if (band < 0 || band >= 10) return;

    if (_bfxEqHandle != 0) {
      final params = calloc<bass.BASS_BFX_PEAKEQ>();
      try {
        final center = eqBandCenterForSampleRate(
          eqBandFrequenciesHz[band],
          _streamSampleRate,
        );
        final gain = _appliedEqGains[band];

        params.ref.lBand = band;
        params.ref.fCenter = center;
        params.ref.fBandwidth = eqBandBandwidthOctaves;
        params.ref.fQ = 0.0;
        params.ref.fGain = gain;
        params.ref.lChannel = bass.BASS_BFX_CHANALL;

        final result = _bass.BASS_FXSetParameters(_bfxEqHandle, params.cast());

        if (result == 0) {
          final err = _bass.BASS_ErrorGetCode();
          log.bass.warn(
            'legacy',
            'Failed to set BFX EQ parameters for band $band: Error $err',
          );
        }
      } catch (e) {
        log.bass.error('legacy', 'Error updating BFX EQ band $band: $e');
      } finally {
        calloc.free(params);
      }
      return;
    }

    if (band >= _eqHandles.length) return;

    final fx = _eqHandles[band];
    if (fx == 0) return;

    final params = calloc<bass.BASS_DX8_PARAMEQ>();
    try {
      final center = eqDx8CenterForSampleRate(
        eqBandFrequenciesHz[band],
        _streamSampleRate,
      );
      final bandwidth = eqDx8BandwidthSemitonesFromQ(eqBandQ);
      final gain = _appliedEqGains[band];

      params.ref.fCenter = center;
      params.ref.fBandwidth = bandwidth;
      params.ref.fGain = gain;

      final result = _bass.BASS_FXSetParameters(fx, params.cast());

      if (result == 0) {
        final err = _bass.BASS_ErrorGetCode();
        log.bass.warn(
          'legacy',
          'Failed to set EQ parameters for band $band: Error $err',
        );
      }
    } catch (e) {
      log.bass.error('legacy', 'Error updating EQ band $band: $e');
    } finally {
      calloc.free(params);
    }
  }

  void _cancelEqSmoothing() {
    _eqRemovalTimer?.cancel();
    _eqRemovalTimer = null;
    for (var i = 0; i < _eqSmoothingTimers.length; i++) {
      _eqSmoothingTimers[i]?.cancel();
      _eqSmoothingTimers[i] = null;
    }
  }

  void _removeEQ() {
    _cancelEqSmoothing();
    final channel = _eqChannel;
    if (channel == null) {
      _bfxEqHandle = 0;
      _eqHandles.clear();
      return;
    }
    if (_bfxEqHandle != 0) {
      _bass.BASS_ChannelRemoveFX(channel, _bfxEqHandle);
      _bfxEqHandle = 0;
    }
    for (final fx in _eqHandles) {
      if (fx == 0) continue;
      _bass.BASS_ChannelRemoveFX(channel, fx);
    }
    _eqHandles.clear();
    _eqChannel = null;
  }

  void refreshAudioEffects() {
    _refreshStreamSampleRate();
    final channel = _effectHandle;
    if (channel == null ||
        _isDspNeutral ||
        _bassFx == null ||
        wasapiExclusive) {
      _removeAudioEffects();
      return;
    }
    if (_dspChannel != channel) {
      _removeAudioEffects();
      _dspChannel = channel;
    } else {
      _dspChannel ??= channel;
    }

    final desiredPriorities = <int>{};
    if (_audioEffects.enabled) {
      final nyquist = math.max(20.0, _streamSampleRate * 0.5);
      final maxHighPassHz = math.min(dspHighPassMaxHz, nyquist * 0.8);
      final maxLowPassHz = math.min(dspLowPassMaxHz, nyquist * 0.95);
      final highPassHz = maxHighPassHz >= dspHighPassMinHz
          ? _audioEffects.highPassHz
                .clamp(dspHighPassMinHz, maxHighPassHz)
                .toDouble()
          : null;
      final lowPassHz = maxLowPassHz >= dspLowPassMinHz
          ? _audioEffects.lowPassHz
                .clamp(dspLowPassMinHz, maxLowPassHz)
                .toDouble()
          : null;
      if (_audioEffects.highPassHz > dspHighPassMinHz &&
          highPassHz != null &&
          lowPassHz != null &&
          highPassHz < lowPassHz) {
        desiredPriorities.add(_highPassFxPriority);
        _attachBiquad(
          channel,
          bass.BASS_BFX_BQF_HIGHPASS,
          highPassHz,
          priority: _highPassFxPriority,
        );
      }
      if (_audioEffects.lowPassHz < dspLowPassMaxHz &&
          lowPassHz != null &&
          (highPassHz == null || lowPassHz > highPassHz)) {
        desiredPriorities.add(_lowPassFxPriority);
        _attachBiquad(
          channel,
          bass.BASS_BFX_BQF_LOWPASS,
          lowPassHz,
          priority: _lowPassFxPriority,
        );
      }
      if (_audioEffects.drive > 0.0001) {
        desiredPriorities.add(_driveFxPriority);
        _attachDrive(channel);
      }
      if (_audioEffects.reverb > 0.0001) {
        desiredPriorities.add(_reverbFxPriority);
        _attachReverb(channel);
      }
      if (_audioEffects.punch > 0.0001) {
        desiredPriorities.add(_punchFxPriority);
        _attachCompressor(channel);
      }
    }
    if (_audioEffects.limiterEnabled) {
      desiredPriorities.add(_limiterFxPriority);
      _attachLimiter(channel);
    }

    final obsoletePriorities = _dspFxHandles.keys
        .where((priority) => !desiredPriorities.contains(priority))
        .toList(growable: false);
    for (final priority in obsoletePriorities) {
      _removeDspEffect(channel, priority);
    }
    if (_dspFxHandles.isEmpty) _dspChannel = null;
  }

  int? _ensureDspEffect(int channel, int type, int priority) {
    final existing = _dspFxHandles[priority];
    if (existing != null && existing != 0) return existing;
    final handle = _bass.BASS_ChannelSetFX(channel, type, priority);
    if (handle == 0) {
      log.bass.warn(
        'legacy',
        '[bass] failed to create DSP effect: type=$type '
            'priority=$priority error=${_bass.BASS_ErrorGetCode()}',
      );
      return null;
    }
    _dspFxHandles[priority] = handle;
    return handle;
  }

  void _removeDspEffect(int channel, int priority) {
    final handle = _dspFxHandles.remove(priority);
    if (handle == null || handle == 0) return;
    _bass.BASS_ChannelRemoveFX(channel, handle);
  }

  void _discardDspEffect(int channel, int priority, int handle) {
    if (_dspFxHandles[priority] == handle) {
      _dspFxHandles.remove(priority);
    }
    _bass.BASS_ChannelRemoveFX(channel, handle);
  }

  void _attachBiquad(
    int channel,
    int type,
    double center, {
    required int priority,
  }) {
    final handle = _ensureDspEffect(channel, bass.BASS_FX_BFX_BQF, priority);
    if (handle == null) return;
    final params = calloc<bass.BASS_BFX_BQF>();
    try {
      params.ref
        ..lFilter = type
        ..fCenter = center
        ..fGain = 0
        ..fBandwidth = 0
        ..fQ = 0.707
        ..fS = 1
        ..lChannel = bass.BASS_BFX_CHANALL;
      if (_bass.BASS_FXSetParameters(handle, params.cast()) == bass.FALSE) {
        log.bass.warn(
          'legacy',
          '[bass] failed to configure DSP filter: type=$type error=${_bass.BASS_ErrorGetCode()}',
        );
        _discardDspEffect(channel, priority, handle);
      }
    } catch (error, trace) {
      log.bass.warn(
        'legacy',
        '[bass] failed to configure DSP filter: type=$type',
        error: error,
        stackTrace: trace,
      );
      _discardDspEffect(channel, priority, handle);
    } finally {
      calloc.free(params);
    }
  }

  void _attachDrive(int channel) {
    const priority = _driveFxPriority;
    final amount = _audioEffects.drive;
    final wetMix = amount * 0.45;
    final handle = _ensureDspEffect(
      channel,
      bass.BASS_FX_BFX_DISTORTION,
      priority,
    );
    if (handle == null) return;
    final params = calloc<bass.BASS_BFX_DISTORTION>();
    try {
      params.ref
        ..fDrive = amount.clamp(0.0, 1.0).toDouble()
        ..fDryMix = 1.0 - wetMix
        ..fWetMix = wetMix
        ..fFeedback = 0
        ..fVolume = 1 / (1 + amount * 0.2)
        ..lChannel = bass.BASS_BFX_CHANALL;
      if (_bass.BASS_FXSetParameters(handle, params.cast()) == bass.FALSE) {
        _discardDspEffect(channel, priority, handle);
      }
    } catch (error, trace) {
      log.bass.warn(
        'legacy',
        '[bass] failed to configure distortion',
        error: error,
        stackTrace: trace,
      );
      _discardDspEffect(channel, priority, handle);
    } finally {
      calloc.free(params);
    }
  }

  void _attachReverb(int channel) {
    const priority = _reverbFxPriority;
    final amount = _audioEffects.reverb;
    final handle = _ensureDspEffect(channel, bass.BASS_FX_BFX_REVERB, priority);
    if (handle == null) return;
    final params = calloc<bass.BASS_BFX_REVERB>();
    final mix = math.sqrt(amount) * 38.0;
    try {
      params.ref
        ..fInGain = 0
        ..fReverbMix = -48 + mix
        ..fReverbTime = 220 + amount * 1280
        ..fHighFreqRTRatio = 0.25 + amount * 0.35;
      if (_bass.BASS_FXSetParameters(handle, params.cast()) == bass.FALSE) {
        _discardDspEffect(channel, priority, handle);
      }
    } catch (error, trace) {
      log.bass.warn(
        'legacy',
        '[bass] failed to configure reverb',
        error: error,
        stackTrace: trace,
      );
      _discardDspEffect(channel, priority, handle);
    } finally {
      calloc.free(params);
    }
  }

  void _attachCompressor(int channel) {
    const priority = _punchFxPriority;
    final amount = _audioEffects.punch;
    final handle = _ensureDspEffect(
      channel,
      bass.BASS_FX_BFX_COMPRESSOR2,
      priority,
    );
    if (handle == null) return;
    final params = calloc<bass.BASS_BFX_COMPRESSOR2>();
    try {
      params.ref
        ..fGain = amount * 3.0
        ..fThreshold = -12 - amount * 6
        ..fRatio = 1.5 + amount * 4.5
        ..fAttack = 20.0 - amount * 15.0
        ..fRelease = 260 - amount * 110
        ..lChannel = bass.BASS_BFX_CHANALL;
      if (_bass.BASS_FXSetParameters(handle, params.cast()) == bass.FALSE) {
        _discardDspEffect(channel, priority, handle);
      }
    } catch (error, trace) {
      log.bass.warn(
        'legacy',
        '[bass] failed to configure compressor',
        error: error,
        stackTrace: trace,
      );
      _discardDspEffect(channel, priority, handle);
    } finally {
      calloc.free(params);
    }
  }

  void _attachLimiter(int channel) {
    const priority = _limiterFxPriority;
    final handle = _ensureDspEffect(
      channel,
      bass.BASS_FX_BFX_COMPRESSOR2,
      priority,
    );
    if (handle == null) return;
    final params = calloc<bass.BASS_BFX_COMPRESSOR2>();
    try {
      params.ref
        ..fGain = 0
        ..fThreshold = _audioEffects.limiterCeilingDb
        ..fRatio = 100.0
        ..fAttack = 0.1
        ..fRelease = 100.0
        ..lChannel = bass.BASS_BFX_CHANALL;
      if (_bass.BASS_FXSetParameters(handle, params.cast()) == bass.FALSE) {
        _discardDspEffect(channel, priority, handle);
      }
    } catch (error, trace) {
      log.bass.warn(
        'legacy',
        '[bass] failed to configure limiter',
        error: error,
        stackTrace: trace,
      );
      _discardDspEffect(channel, priority, handle);
    } finally {
      calloc.free(params);
    }
  }

  void _removeAudioEffects() {
    final channel = _dspChannel;
    if (channel != null) {
      for (final handle in _dspFxHandles.values) {
        _bass.BASS_ChannelRemoveFX(channel, handle);
      }
    }
    _dspFxHandles.clear();
    _dspChannel = null;
  }

  void _resetBassHandles() {
    _cancelPendingPause();
    _cancelOutputGainFade(keepTarget: true);
    _fadeInTimer?.cancel();
    _fadeInTimer = null;
    _cancelEqSmoothing();
    _fadeOutTimer?.cancel();
    _fadeOutTimer = null;
    _fadeOutHandle = null;
    _fadeOutRemoveFromMixer = false;
    _transitionGeneration++;
    _transitionTimer?.cancel();
    _transitionTimer = null;
    _transitionOldStream = null;
    _positionUpdaterVersion++;
    _positionUpdater?.cancel();
    _positionUpdater = null;
    _mixerGeneration++;
    _unreportedGaplessTransition = null;
    _mixerStream = null;
    _mixerUsesQueue = false;
    _queuedStream = null;
    _queuedStreamAttached = false;
    _queuedPath = null;
    _queuedLengthSeconds = null;
    _queuedReplayGainDb = null;
    _queuedTransitionId = null;
    _queuedTransitionMode = null;
    _activeGaplessTransitionId = null;
    _smartPreparation = null;
    _smartIncomingNativeOwned = false;
    _activeSmartTransitionId = null;
    _smartOutgoingStream = null;
    _fstream = null;
    _cachedLengthSeconds = null;
    _streamWasapiExclusive = false;
    wasapiExclusive = false;
    _wasapiOutputInfo = 'off';
    _eqChannel = null;
    _bfxEqHandle = 0;
    _eqHandles.clear();
    _dspFxHandles.clear();
    _dspChannel = null;
  }

  void _bassInit({bool resetHandles = true}) {
    // 先释放旧设备，确保可以使用 -1 (默认设备) 重新初始化
    _bass.BASS_Free();
    if (resetHandles) _resetBassHandles();
    _applyOutputBufferConfig();

    final savedDevice =
        AppPreference.instance.playbackPref.sharedOutputDevice;
    final resolvedDevice = _resolveSharedDeviceIndex(savedDevice);
    final outputDevice = resolvedDevice ?? -1;
    if (savedDevice.isNotEmpty && resolvedDevice == null) {
      log.bass.warn(
        'legacy',
        '[bass] shared output device is unavailable, using system default',
      );
    }
    if (_bass.BASS_Init(
          outputDevice,
          44100,
          0,
          ffi.nullptr,
          ffi.nullptr,
        ) ==
        0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_DEVICE:
          throw const FormatException('device is invalid.');
        case bass.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
            'The BASS_DEVICE_REINIT flag cannot be used when device is -1. Use the real device number instead.',
          );
        case bass.BASS_ERROR_ALREADY:
          throw const FormatException(
            'The device has already been initialized. The BASS_DEVICE_REINIT flag can be used to request reinitialization.',
          );
        case bass.BASS_ERROR_ILLPARAM:
          throw const FormatException('win is not a valid window handle.');
        case bass.BASS_ERROR_DRIVER:
          throw const FormatException('There is no available device driver.');
        case bass.BASS_ERROR_BUSY:
          throw const FormatException(
            'Something else has exclusive use of the device.',
          );
        case bass.BASS_ERROR_FORMAT:
          throw const FormatException(
            'The specified format is not supported by the device. Try changing the freq parameter.',
          );
        case bass.BASS_ERROR_MEM:
          throw const FormatException('There is insufficient memory.');
        case bass.BASS_ERROR_UNKNOWN:
          throw const FormatException(
            'Some other mystery problem! Maybe Something else has exclusive use of the device.',
          );
      }
    }

    // BASS_Free() 会释放所有 BASS 对象，包括 bass_fx.dll 创建的 tempo 流。
    _bassFx = null;
    _bassFxLib?.close();
    _bassFxLib = null;
    _loadBassFx();
    if (_bass.BASS_SetConfig(bass.BASS_CONFIG_ASYNCFILE_BUFFER, 1024 * 1024) ==
        bass.FALSE) {
      log.bass.warn('legacy', '[bass] failed to set async file buffer to 1MB');
    } else {
      log.bass.debug('legacy', '[bass] async file buffer=1MB');
    }
    _reapplyMidiSoundfont();
  }

  void _applyOutputBufferConfig() {
    _bass.BASS_SetConfig(bass.BASS_CONFIG_BUFFER, _playbackBufferMs);
    _bass.BASS_SetConfig(bass.BASS_CONFIG_DEV_BUFFER, _deviceBufferMs);
  }

  bool _startDevice() {
    if (_bass.BASS_Start() == bass.FALSE) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_INIT:
          _bassInit();
          return false;
        case bass.BASS_ERROR_BUSY:
          throw const FormatException(
            "The app's audio has been interrupted and cannot be resumed yet. (iOS only)",
          );
        case bass.BASS_ERROR_REINIT:
          throw const FormatException(
            'The device is currently being reinitialized or needs to be.',
          );
        case bass.BASS_ERROR_UNKNOWN:
          throw const FormatException(
            'Some other mystery problem! Maybe Something else has exclusive use of the device.',
          );
      }
    }
    return true;
  }

  void _restoreSharedSource(String audioPath, double position) {
    _fPath = audioPath;
    _createSharedStream(audioPath, position);
  }

  /// load bass.dll from the exe's path\\dll\\BASS
  /// ensure that there's bass.dll at path of .exe\\dll\\BASS
  /// leave the device's output freq as it is
  BassPlayer() {
    _positionStreamController = StreamController<double>.broadcast(
      onListen: _syncPositionUpdaterPeriod,
      onCancel: _syncPositionUpdaterPeriod,
    );
    _spectrumStreamController = StreamController<Float32List>.broadcast(
      onListen: _syncPositionUpdaterPeriod,
      onCancel: _syncPositionUpdaterPeriod,
    );
    _spectrumDisplayStreamController = StreamController<Float32List>.broadcast(
      onListen: _syncPositionUpdaterPeriod,
      onCancel: _syncPositionUpdaterPeriod,
    );
    _gaplessTransitionStreamController =
        StreamController<GaplessTransition>.broadcast();

    // ─── 1. 确定 BASS DLL 目录 ─────────────────────────────────────────────
    final exeBassDir = path.join(
      path.dirname(Platform.resolvedExecutable),
      'dll',
      'BASS',
    );
    final cwdBassDir = path.join(Directory.current.path, 'dll', 'BASS');
    final sourceBassDir = path.join(Directory.current.path, 'BASS');
    final exeBassDll = File(path.join(exeBassDir, 'bass.dll'));
    final cwdBassDll = File(path.join(cwdBassDir, 'bass.dll'));
    final sourceBassDll = File(path.join(sourceBassDir, 'bass.dll'));
    _bassDir = exeBassDll.existsSync()
        ? exeBassDir
        : (cwdBassDll.existsSync()
              ? cwdBassDir
              : (sourceBassDll.existsSync() ? sourceBassDir : exeBassDir));

    // ─── 2. 确保 Windows 能找到 BASS 目录下的依赖 DLL ──────────────────────
    if (Platform.isWindows) {
      // 防线 A: SetDllDirectoryW — 将 BASS 目录加入标准 DLL 搜索路径
      bool dllDirSet = false;
      try {
        final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
        _windowsSleep = kernel32
            .lookupFunction<ffi.Void Function(ffi.Uint32), void Function(int)>(
              'Sleep',
            );

        final setDllDirectory = kernel32
            .lookupFunction<
              ffi.Int32 Function(ffi.Pointer<Utf16>),
              int Function(ffi.Pointer<Utf16>)
            >('SetDllDirectoryW');
        final bassDir = _bassDir.toNativeUtf16();
        dllDirSet = setDllDirectory(bassDir) != 0;
        malloc.free(bassDir);

        if (!dllDirSet) {
          log.bass.warn(
            'legacy',
            '[bass] SetDllDirectoryW failed, falling back to PATH',
          );
        }
      } catch (e) {
        log.bass.warn('legacy', '[bass] SetDllDirectoryW exception: $e');
      }

      // 防线 B: 将 BASS 目录加入 PATH — 终极保底，不受 SetDefaultDllDirectories 影响
      if (!dllDirSet) {
        try {
          final currentPath = Platform.environment['PATH'] ?? '';
          if (!currentPath.contains(_bassDir)) {
            final newPath = '$_bassDir;$currentPath';
            // 通过 SetEnvironmentVariableW 设置
            final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
            final setEnv = kernel32
                .lookupFunction<
                  ffi.Int32 Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>),
                  int Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>)
                >('SetEnvironmentVariableW');
            final nameP = 'PATH'.toNativeUtf16();
            final valueP = newPath.toNativeUtf16();
            setEnv(nameP, valueP);
            malloc.free(nameP);
            malloc.free(valueP);
            log.bass.debug(
              'legacy',
              '[bass] Added BASS dir to PATH as fallback',
            );
          }
        } catch (e) {
          log.bass.warn('legacy', '[bass] Failed to update PATH: $e');
        }
      }
    }

    // ─── 3. 加载 bass.dll（核心） ───────────────────────────────────────────
    ffi.DynamicLibrary bassLib;
    try {
      bassLib = ffi.DynamicLibrary.open(path.join(_bassDir, 'bass.dll'));
    } catch (e) {
      log.bass.error(
        'legacy',
        '[bass] FATAL: Cannot load bass.dll from $_bassDir: $e',
      );
      rethrow;
    }
    _bassLib = bassLib;
    _bass = bass.Bass(bassLib);
    _bassUrl = BassUrl(bassLib);
    try {
      _bassChannelGetData = bassLib
          .lookupFunction<
            ffi.UnsignedLong Function(
              ffi.UnsignedLong,
              ffi.Pointer<ffi.Void>,
              ffi.UnsignedLong,
            ),
            int Function(int, ffi.Pointer<ffi.Void>, int)
          >('BASS_ChannelGetData');
    } catch (_) {
      _bassChannelGetData = null;
    }

    // ─── 4. 加载 basswasapi.dll ─────────────────────────────────────────────
    try {
      final wasapiLib = ffi.DynamicLibrary.open(
        path.join(_bassDir, 'basswasapi.dll'),
      );
      _bassWasapi = bass_wasapi.BassWasapi(wasapiLib);
    } catch (e) {
      log.bass.error('legacy', '[bass] FATAL: Cannot load basswasapi.dll: $e');
      rethrow;
    }

    // ─── 5. 加载其他 BASS 插件（bassflac.dll 等，通过 BASS_PluginLoad） ─────
    final coreDlls = {
      'bass.dll',
      'basswasapi.dll',
      'bass_fx.dll',
      'bassmix.dll',
    };
    if (Directory(_bassDir).existsSync()) {
      final entries = Directory(_bassDir).listSync(followLinks: false);
      for (final e in entries) {
        if (e is! File) continue;
        final name = path.basename(e.path).toLowerCase();
        if (!name.endsWith('.dll')) continue;
        if (!name.startsWith('bass')) continue;
        if (coreDlls.contains(name)) continue;

        final pluginFullPath = e.path;
        final pluginPathP = pluginFullPath.toNativeUtf16().cast<ffi.Char>();
        final hplugin = _bass.BASS_PluginLoad(pluginPathP, bass.BASS_UNICODE);
        if (hplugin == 0) {
          final errCode = _bass.BASS_ErrorGetCode();
          log.bass.warn(
            'legacy',
            '[bass] Plugin load failed: $pluginFullPath (error $errCode)',
          );
        } else {
          log.bass.debug('legacy', '[bass] Plugin loaded: $name');
        }
        malloc.free(pluginPathP);
      }
    }

    // ─── 6. BASS 初始化 ─────────────────────────────────────────────────────
    try {
      _bassInit(resetHandles: false);
    } catch (err) {
      log.bass.error('legacy', '[bass] Init failed: $err');
    }

    // ─── 7. 预加载 BASS_FX（在 bass.dll 已就绪时加载，避免后续依赖解析问题） ─
    _loadBassFx();
    _loadBassMix();
  }

  void _loadBassFx() {
    if (_bassFx != null) return; // 已加载，跳过
    final bassFxLibPath = path.join(_bassDir, 'bass_fx.dll');
    ffi.DynamicLibrary? bassFxLib;
    try {
      bassFxLib = ffi.DynamicLibrary.open(bassFxLibPath);
      final bassFx = BassFx(bassFxLib);
      final version = bassFx.BASS_FX_GetVersion();
      _bassFxLib = bassFxLib;
      _bassFx = bassFx;
      log.bass.debug(
        'legacy',
        'BASS_FX loaded (version: ${version.toRadixString(16)})',
      );
    } catch (e) {
      bassFxLib?.close();
      _bassFxLib = null;
      _bassFx = null;
      log.bass.warn(
        'legacy',
        'BASS_FX not available: $e; tempo/pitch control disabled',
      );
    }
  }

  void _loadBassMix() {
    if (_bassMix != null) return;
    ffi.DynamicLibrary? mixLib;
    ffi.NativeCallable<BassSyncProc>? queueSyncCallback;
    ffi.NativeCallable<BassSyncProc>? posSyncCallback;
    try {
      mixLib = ffi.DynamicLibrary.open(path.join(_bassDir, 'bassmix.dll'));
      final mix = BassMix(mixLib);
      final version = mix.getVersion();
      if (version < 0x02040c00) {
        throw UnsupportedError(
          'BASSmix 2.4.12 or newer is required for queued playback',
        );
      }
      final sync = BassSync(_bassLib);
      final channel = BassChannel(_bassLib);
      final queueCallback = ffi.NativeCallable<BassSyncProc>.listener(
        _onMixerSourceDequeued,
      )..keepIsolateAlive = false;
      queueSyncCallback = queueCallback;
      final posCallback = ffi.NativeCallable<BassSyncProc>.listener(
        _onAutoTransitionPos,
      )..keepIsolateAlive = false;
      posSyncCallback = posCallback;
      log.bass.debug(
        'legacy',
        'BASSmix loaded (version: ${version.toRadixString(16)})',
      );
      _bassMixLib = mixLib;
      _bassMix = mix;
      _bassSync = sync;
      _bassChannel = channel;
      _queueSyncCallback = queueCallback;
      _posSyncCallback = posCallback;
    } catch (error) {
      queueSyncCallback?.close();
      posSyncCallback?.close();
      mixLib?.close();
      _queueSyncCallback = null;
      _posSyncCallback = null;
      _bassMixLib = null;
      _bassMix = null;
      _bassSync = null;
      _bassChannel = null;
      log.bass.warn(
        'legacy',
        'BASSmix not available: $error; gapless playback disabled',
      );
    }
  }

  double _dbToLinear(double db) => math.pow(10.0, db / 20.0).toDouble();

  double _sourceGain(double? gainDb) {
    if (!AppPreference.instance.playbackPref.replayGainEnabled) return 1.0;
    return _dbToLinear(gainDb ?? 0.0).clamp(0.0, 8.0).toDouble();
  }

  void _setDspVolumePriority(int channel) {
    final result = _bass.BASS_ChannelSetAttribute(
      channel,
      bass.BASS_ATTRIB_VOLDSP_PRIORITY,
      _dspVolumePriority.toDouble(),
    );
    if (result == bass.FALSE) {
      log.bass.warn('legacy', '[bass] failed to set DSP volume priority');
    }
  }

  void _applySourceGain(int stream, double? gainDb) {
    _bass.BASS_ChannelSetAttribute(
      stream,
      bass.BASS_ATTRIB_VOLDSP,
      _sourceGain(gainDb),
    );
  }

  void _applyPlaybackGains() {
    final current = _fstream;
    if (current == null) return;
    if (_mixerStream == null || wasapiExclusive || _streamWasapiExclusive) {
      _bass.BASS_ChannelSetAttribute(
        current,
        bass.BASS_ATTRIB_VOLDSP,
        _baseOutputVolume * _pauseFadeGain * _sourceGain(_replayGainDb),
      );
      return;
    }
    _bass.BASS_ChannelSetAttribute(
      _mixerStream!,
      bass.BASS_ATTRIB_VOLDSP,
      _baseOutputVolume * _pauseFadeGain,
    );
    _applySourceGain(current, _replayGainDb);
    final queued = _queuedStream;
    if (queued != null) {
      _applySourceGain(queued, _queuedReplayGainDb);
    }
    final smartIncoming = _smartPreparation?.incomingHandle;
    if (smartIncoming != null) {
      _applySourceGain(smartIncoming, _smartPreparation?.replayGainDb);
    }
  }

  int _createSharedSource(String audioPath) {
    const flags =
        bass.BASS_UNICODE |
        bass.BASS_SAMPLE_FLOAT |
        bass.BASS_ASYNCFILE |
        bass.BASS_STREAM_DECODE;
    var handle = 0;
    if (_isUrl(audioPath)) {
      handle = _createUrlStream(
        audioPath,
        flags: bass.BASS_SAMPLE_FLOAT | bass.BASS_STREAM_DECODE,
      );
    } else {
      final pathPointer = audioPath.toNativeUtf16() as ffi.Pointer<ffi.Void>;
      handle = _bass.BASS_StreamCreateFile(
        bass.FALSE,
        pathPointer,
        0,
        0,
        flags,
      );
      malloc.free(pathPointer);
    }
    if (handle == 0) return 0;

    if (_bassFx != null) {
      final tempoHandle = _bassFx!.BASS_FX_TempoCreate(
        handle,
        BASS_FX_FREESOURCE | bass.BASS_STREAM_DECODE,
      );
      if (tempoHandle != 0) {
        handle = tempoHandle;
      }
    }
    if (_rate != 1.0) {
      _bass.BASS_ChannelSetAttribute(
        handle,
        BASS_ATTRIB_TEMPO,
        (_rate - 1.0) * 100.0,
      );
    }
    if (_pitch != 0.0) {
      _bass.BASS_ChannelSetAttribute(handle, BASS_ATTRIB_TEMPO_PITCH, _pitch);
    }
    return handle;
  }

  int _createDirectSharedStream(String audioPath) {
    if (_bassFx != null) {
      final source = _createDecodeStream(audioPath);
      if (source != 0) {
        try {
          final tempoHandle = _bassFx!.BASS_FX_TempoCreate(
            source,
            BASS_FX_FREESOURCE,
          );
          if (tempoHandle != 0) {
            if (_rate != 1.0) {
              _bass.BASS_ChannelSetAttribute(
                tempoHandle,
                BASS_ATTRIB_TEMPO,
                (_rate - 1.0) * 100.0,
              );
            }
            if (_pitch != 0.0) {
              _bass.BASS_ChannelSetAttribute(
                tempoHandle,
                BASS_ATTRIB_TEMPO_PITCH,
                _pitch,
              );
            }
            return tempoHandle;
          }
        } catch (error) {
          log.bass.warn(
            'legacy',
            '[bass] direct tempo stream unavailable: $error',
          );
        }
        _bass.BASS_StreamFree(source);
      }
    }

    if (_isUrl(audioPath)) {
      return _createUrlStream(
        audioPath,
        flags: bass.BASS_SAMPLE_FLOAT,
      );
    }

    const playableFlags =
        bass.BASS_UNICODE | bass.BASS_SAMPLE_FLOAT | bass.BASS_ASYNCFILE;
    final pathPointer = audioPath.toNativeUtf16() as ffi.Pointer<ffi.Void>;
    final handle = _bass.BASS_StreamCreateFile(
      bass.FALSE,
      pathPointer,
      0,
      0,
      playableFlags,
    );
    malloc.free(pathPointer);
    return handle;
  }

  int _createSharedPlaybackSource(String audioPath) {
    if (_bassMix != null) {
      final source = _createSharedSource(audioPath);
      if (source == 0) return 0;
      if (_createMixerForSource(source)) {
        _muteSharedOutputForFadeIn();
        return source;
      }
      _bass.BASS_StreamFree(source);
      log.bass.warn(
        'legacy',
        '[bass] mixer creation failed; using direct shared output',
      );
    }
    final direct = _createDirectSharedStream(audioPath);
    if (direct != 0) {
      _setDspVolumePriority(direct);
      _bass.BASS_ChannelSetAttribute(direct, bass.BASS_ATTRIB_VOL, 0.0);
    }
    return direct;
  }

  void _muteSharedOutputForFadeIn() {
    final output = _sharedOutputHandle;
    if (output != null) {
      _bass.BASS_ChannelSetAttribute(output, bass.BASS_ATTRIB_VOL, 0.0);
    }
  }

  bool _createMixerForSource(int source) {
    final mix = _bassMix;
    final channel = _bassChannel;
    final sync = _bassSync;
    final callback = _queueSyncCallback;
    if (mix == null || channel == null || sync == null || callback == null) {
      return false;
    }

    final info = calloc<BassChannelInfo>();
    try {
      if (!channel.getInfo(source, info)) return false;
      final frequency = info.ref.frequency;
      final sourceChannels = info.ref.channels;
      if (frequency <= 0 || sourceChannels <= 0) return false;

      var outputFrequency = frequency;
      var outputChannels = 2;
      final deviceInfo = calloc<bass.BASS_INFO>();
      try {
        if (_bass.BASS_GetInfo(deviceInfo) != 0) {
          if (deviceInfo.ref.freq > 0) outputFrequency = deviceInfo.ref.freq;
          if (deviceInfo.ref.speakers > 0) {
            outputChannels = deviceInfo.ref.speakers;
          }
        }
      } finally {
        calloc.free(deviceInfo);
      }

      final seamless =
          AppPreference.instance.playbackPref.transitionMode ==
          TransitionMode.seamless;
      final flags =
          bass.BASS_SAMPLE_FLOAT |
          bassMixerPosex |
          bassMixerResume |
          bassMixerEnd |
          (seamless ? bassMixerQueue : 0);
      final output = mix.streamCreate(outputFrequency, outputChannels, flags);
      if (output == 0) return false;
      _mixerGeneration++;
      int? syncHandle;
      if (seamless) {
        syncHandle = sync.channelSetSync(
          output,
          bassSyncMixerQueue,
          0,
          callback.nativeFunction,
          ffi.Pointer<ffi.Void>.fromAddress(_mixerGeneration),
        );
        if (syncHandle == 0) {
          _bass.BASS_StreamFree(output);
          return false;
        }
      }
      if (!mix.streamAddChannel(
        output,
        source,
        bassMixerChanDownmix |
            bassMixerChanNoRampIn |
            (seamless ? bassStreamAutofree : 0),
      )) {
        _bass.BASS_StreamFree(output);
        return false;
      }

      _mixerStream = output;
      _mixerUsesQueue = seamless;
      _setDspVolumePriority(output);
      _bass.BASS_ChannelSetAttribute(
        output,
        bass.BASS_ATTRIB_VOLDSP,
        _baseOutputVolume,
      );
      _applySourceGain(source, _replayGainDb);
      return true;
    } finally {
      calloc.free(info);
    }
  }

  bool prepareGaplessSource(
    String audioPath, {
    required int transitionId,
    double? replayGainDb,
    TransitionMode? transitionMode,
  }) {
    if (!canUseGaplessPlayback || _fstream == null) return false;
    if (_queuedTransitionId == transitionId && _queuedStream != null) {
      _queuedReplayGainDb = replayGainDb;
      if (transitionMode != null) _queuedTransitionMode = transitionMode;
      _applySourceGain(_queuedStream!, replayGainDb);
      return true;
    }

    final selectedMode =
        transitionMode ?? AppPreference.instance.playbackPref.transitionMode;
    final seamless = selectedMode == TransitionMode.seamless;
    clearGaplessSource();
    _cancelTransition();
    if (seamless != _mixerUsesQueue) {
      log.bass.debug(
        'legacy',
        '[bass] transition mode will apply after the next source rebuild',
      );
      _transitionHandledCompletion = false;
      return false;
    }
    final nextStream = _createSharedSource(audioPath);
    if (nextStream == 0) return false;
    final nextLength = _bass.BASS_ChannelBytes2Seconds(
      nextStream,
      _bass.BASS_ChannelGetLength(nextStream, bass.BASS_POS_BYTE),
    );
    _applySourceGain(nextStream, replayGainDb);
    var ownedByMixer = false;

    try {
      if (_mixerStream == null) {
        _bass.BASS_StreamFree(nextStream);
        return false;
      }
      if (!seamless) {
        // 淡化模式只预建解码流，避免它在触发前静音播放。
        _bass.BASS_ChannelSetAttribute(nextStream, bass.BASS_ATTRIB_VOL, 0.0);
      }
      if (seamless) {
        final added = _bassMix!.streamAddChannel(
          _mixerStream!,
          nextStream,
          bassMixerChanDownmix |
              bassMixerChanNoRampIn |
              (seamless ? bassStreamAutofree : 0),
        );
        if (!added) {
          _bass.BASS_StreamFree(nextStream);
          return false;
        }
        ownedByMixer = true;
      }
      _queuedStream = nextStream;
      _queuedStreamAttached = ownedByMixer;
      _queuedPath = audioPath;
      _queuedLengthSeconds = nextLength > 0 ? nextLength : null;
      _queuedReplayGainDb = replayGainDb;
      _queuedTransitionId = transitionId;
      _queuedTransitionMode = selectedMode;
      if (!seamless) {
        _scheduleAutoTransition();
      }
      _publishAudioFiles();
      return true;
    } catch (error, trace) {
      log.bass.warn(
        'legacy',
        '[bass] preparing gapless source failed: $error',
        stackTrace: trace,
      );
      if (_queuedStream == nextStream) {
        _queuedStream = null;
        _queuedStreamAttached = false;
        _queuedPath = null;
        _queuedLengthSeconds = null;
        _queuedReplayGainDb = null;
        _queuedTransitionId = null;
        _queuedTransitionMode = null;
      }
      if (ownedByMixer) {
        _bassMix?.channelRemove(nextStream);
      } else {
        _bass.BASS_StreamFree(nextStream);
      }
      _publishAudioFiles();
      return false;
    }
  }

  SmartTransitionPreparation? prepareSmartTransition(
    String audioPath, {
    required int transitionId,
    double? replayGainDb,
  }) {
    if (!canUseSmartTransition || _fstream == null || _mixerStream == null) {
      return null;
    }
    _cancelTransition();
    final incoming = _createSharedSource(audioPath);
    if (incoming == 0) return null;
    final incomingLength = _bass.BASS_ChannelBytes2Seconds(
      incoming,
      _bass.BASS_ChannelGetLength(incoming, bass.BASS_POS_BYTE),
    );
    _applySourceGain(incoming, replayGainDb);
    final preparation = SmartTransitionPreparation(
      transitionId: transitionId,
      sourceGeneration: _mixerGeneration,
      mixerHandle: _mixerStream!,
      outgoingHandle: _fstream!,
      incomingHandle: incoming,
      path: audioPath,
      lengthSeconds: incomingLength > 0 ? incomingLength : null,
      replayGainDb: replayGainDb,
    );
    _smartPreparation = preparation;
    _smartIncomingNativeOwned = false;
    _publishAudioFiles();
    return preparation;
  }

  bool markSmartTransitionTransferred(int transitionId) {
    if (_smartPreparation?.transitionId != transitionId) return false;
    _smartIncomingNativeOwned = true;
    return true;
  }

  void discardSmartTransition(
    int transitionId, {
    required bool incomingReleasedByNative,
  }) {
    final preparation = _smartPreparation;
    if (preparation == null || preparation.transitionId != transitionId) return;
    if (!incomingReleasedByNative && !_smartIncomingNativeOwned) {
      _bass.BASS_StreamFree(preparation.incomingHandle);
    }
    _smartPreparation = null;
    _smartIncomingNativeOwned = false;
    _publishAudioFiles();
  }

  GaplessTransition? adoptSmartTransition(int transitionId) {
    final preparation = _smartPreparation;
    if (preparation == null || preparation.transitionId != transitionId) {
      return null;
    }
    _smartOutgoingPath = _fPath;
    _fstream = preparation.incomingHandle;
    _fPath = preparation.path;
    _cachedLengthSeconds = preparation.lengthSeconds;
    _replayGainDb = preparation.replayGainDb;
    _smartOutgoingStream = preparation.outgoingHandle;
    _activeSmartTransitionId = transitionId;
    _activeGaplessTransitionId = null;
    _smartPreparation = null;
    _smartIncomingNativeOwned = false;
    _refreshStreamSampleRate();
    _resetSpectrumSmoothing();
    _emitPositionSnapshot();
    _publishAudioFiles();
    return GaplessTransition(
      id: transitionId,
      path: preparation.path,
      replayGainDb: preparation.replayGainDb,
    );
  }

  void completeSmartTransition(int transitionId) {
    if (_activeSmartTransitionId != transitionId) return;
    final outgoing = _smartOutgoingStream;
    _smartOutgoingStream = null;
    _activeSmartTransitionId = null;
    if (outgoing != null && outgoing != _fstream) {
      _bass.BASS_ChannelStop(outgoing);
      _bass.BASS_StreamFree(outgoing);
    }
    _smartOutgoingPath = null;
    _publishAudioFiles();
  }

  int? _detachGaplessMixer() {
    final mixer = _mixerStream;
    if (mixer == null) return null;
    final detachedQueuedStream = _queuedStreamAttached ? null : _queuedStream;
    _mixerGeneration++;
    _unreportedGaplessTransition = null;
    _handledCompletionClearTimer?.cancel();
    _handledCompletionClearTimer = null;
    _transitionHandledCompletion = false;
    _cancelTransition();
    _mixerStream = null;
    _mixerUsesQueue = false;
    _queuedStream = null;
    _queuedStreamAttached = false;
    _queuedPath = null;
    _queuedLengthSeconds = null;
    _queuedReplayGainDb = null;
    _queuedTransitionId = null;
    _queuedTransitionMode = null;
    _queuedTransitionMode = null;
    _activeGaplessTransitionId = null;
    _fstream = null;
    _eqChannel = null;
    _bfxEqHandle = 0;
    _eqHandles.clear();
    _dspChannel = null;
    _dspFxHandles.clear();
    if (detachedQueuedStream != null) {
      _bass.BASS_StreamFree(detachedQueuedStream);
    }
    return mixer;
  }

  void _dropGaplessMixer() {
    _removeAudioEffects();
    _removeEQ();
    final mixer = _detachGaplessMixer();
    if (mixer == null) return;
    _bass.BASS_ChannelStop(mixer);
    _bass.BASS_StreamFree(mixer);
  }

  GaplessTransition? clearGaplessSource() {
    final transition =
        _promoteDequeuedSource(emit: false) ?? _unreportedGaplessTransition;
    _unreportedGaplessTransition = null;
    _cancelTransition();
    if (transition != null) return transition;
    _dropQueuedGaplessSource();
    return null;
  }

  void discardQueuedGaplessSource() {
    _unreportedGaplessTransition = null;
    _cancelTransition();
    _dropQueuedGaplessSource();
  }

  void _dropQueuedGaplessSource() {
    final queued = _queuedStream;
    final queuedWasAttached = _queuedStreamAttached;
    _queuedStream = null;
    _queuedStreamAttached = false;
    _queuedPath = null;
    _queuedLengthSeconds = null;
    _queuedReplayGainDb = null;
    _queuedTransitionId = null;
    _queuedTransitionMode = null;
    if (queued == null) return;
    if (queuedWasAttached) {
      _bassMix?.channelRemove(queued);
    } else {
      _bass.BASS_StreamFree(queued);
    }
    _publishAudioFiles();
  }

  bool _attachQueuedStream(int generation, int stream) {
    if (generation != _mixerGeneration || stream != _queuedStream) {
      return false;
    }
    if (_queuedStreamAttached) return true;
    final mixer = _mixerStream;
    if (mixer == null) return false;
    final added = _bassMix!.streamAddChannel(
      mixer,
      stream,
      bassMixerChanDownmix |
          bassMixerChanNoRampIn |
          (_mixerUsesQueue ? bassStreamAutofree : 0),
    );
    if (added) {
      _queuedStreamAttached = true;
      _resumeOutputIfNeeded();
      return true;
    }
    log.bass.warn(
      'legacy',
      '[bass] attaching prepared transition source failed: '
          '${_bass.BASS_ErrorGetCode()}',
    );
    _bass.BASS_StreamFree(stream);
    _queuedStream = null;
    _queuedStreamAttached = false;
    _queuedPath = null;
    _queuedLengthSeconds = null;
    _queuedReplayGainDb = null;
    _queuedTransitionId = null;
    _queuedTransitionMode = null;
    return false;
  }

  void _onMixerSourceDequeued(
    int handle,
    int channel,
    int data,
    ffi.Pointer<ffi.Void> user,
  ) {
    final generation = user.address;
    if (generation != _mixerGeneration || data != _queuedStream) return;
    _activateQueuedStream(generation, data);
  }

  void _cancelTransition() {
    _transitionGeneration++;
    final syncHandle = _transitionSyncHandle;
    final syncChannel = _transitionSyncChannel;
    _transitionSyncHandle = null;
    _transitionSyncChannel = null;
    if (syncHandle != null && syncChannel != null) {
      _bassSync?.channelRemoveSync(syncChannel, syncHandle);
    }
    _transitionTimer?.cancel();
    _transitionTimer = null;
    final oldStream = _transitionOldStream;
    _transitionOldStream = null;
    if (oldStream != null && oldStream == _fstream) {
      _bass.BASS_ChannelSetAttribute(oldStream, bass.BASS_ATTRIB_VOL, 1.0);
    }
  }

  /// 曲尾提前量。定时器按墙上时钟走，播完检测按解码时钟走，
  /// 淡出拉满时两者会在曲尾错开，混音器先被停掉。
  static const int transitionEndMarginMs = 120;

  static int transitionTriggerLeadMs({
    required bool crossfade,
    required int fadeOutMs,
    required int fadeInMs,
  }) {
    final fadeLead = crossfade ? math.max(fadeOutMs, fadeInMs) : fadeOutMs;
    return math.max(1, fadeLead) + transitionEndMarginMs;
  }

  static bool shouldRestartStoppedMixer(int activeState) =>
      activeState == bass.BASS_ACTIVE_STOPPED;

  static bool shouldReleaseFadedSource({
    required int handle,
    required int? currentHandle,
    required int? queuedHandle,
  }) => handle != currentHandle && handle != queuedHandle;

  /// 仍在播的流只在过渡已取消，或这不是自动过渡时保留。
  /// 交叉淡化的清理定时器会比切歌早几十毫秒，这时旧流还是当前流，必须拆掉。
  static bool shouldKeepLiveFadedSource({
    required bool stillLive,
    required int? scheduledGeneration,
    required int currentGeneration,
  }) {
    if (!stillLive) return false;
    if (scheduledGeneration == null) return true;
    return scheduledGeneration != currentGeneration;
  }

  /// 过渡期间混音器会先停再起。停播不能记成“已经通知过完成”，
  /// 否则标记解除后不会再发出完成事件，下一首就一直不走。
  static PlayerState? playbackStateToEmit({
    required PlayerState? lastNotified,
    required PlayerState current,
    required bool suppressCompletion,
  }) {
    if (current == PlayerState.stopped) {
      if (suppressCompletion) return null;
      if (lastNotified == PlayerState.completed) return null;
      return PlayerState.completed;
    }
    if (lastNotified != current) return current;
    return null;
  }

  void _scheduleAutoTransition() {
    final current = _fstream;
    final sync = _bassSync;
    final callback = _posSyncCallback;
    final queuedPath = _queuedPath;
    if (current == null ||
        sync == null ||
        callback == null ||
        queuedPath == null) {
      return;
    }
    final pref = AppPreference.instance.playbackPref;
    final mode = _queuedTransitionMode ?? pref.transitionMode;
    final fadeOutMs = pref.transitionFadeOutMs;
    final fadeInMs = pref.transitionFadeInMs;
    final crossfade = mode == TransitionMode.crossfade;
    final leadMs = transitionTriggerLeadMs(
      crossfade: crossfade,
      fadeOutMs: fadeOutMs,
      fadeInMs: fadeInMs,
    );
    // 触发位置基于当前播放流自身的长度。提前一点，避免定时器
    // 落到曲尾之后，混音器先被 BASS_MIXER_END 停掉。
    final currentLength = _bass.BASS_ChannelBytes2Seconds(
      current,
      _bass.BASS_ChannelGetLength(current, bass.BASS_POS_BYTE),
    );
    if (currentLength <= 0) return;
    final triggerPos = math.max(0.0, currentLength - leadMs / 1000.0);

    _transitionGeneration++;
    final generation = _transitionGeneration;
    final currentPositionBytes = _bassMix!.channelGetPosition(
      current,
      bass.BASS_POS_BYTE,
    );
    final currentPosition = currentPositionBytes < 0
        ? 0.0
        : _bass.BASS_ChannelBytes2Seconds(current, currentPositionBytes);
    if (triggerPos <= currentPosition) {
      scheduleMicrotask(() => _beginAutoTransition(generation, current));
      return;
    }
    final triggerBytes = _bass.BASS_ChannelSeconds2Bytes(current, triggerPos);
    final syncHandle = sync.channelSetSync(
      current,
      bassSyncPos | bassSyncOnetime,
      triggerBytes,
      callback.nativeFunction,
      ffi.Pointer<ffi.Void>.fromAddress(generation),
    );
    if (syncHandle == 0) {
      log.bass.warn(
        'legacy',
        '[bass] auto transition sync failed: ${_bass.BASS_ErrorGetCode()}',
      );
      return;
    }
    _transitionSyncHandle = syncHandle;
    _transitionSyncChannel = current;
    log.bass.info(
      'legacy',
      '[bass] auto transition scheduled: mode=${mode.name} '
          'fadeOut=${fadeOutMs}ms fadeIn=${fadeInMs}ms '
          'triggerAt=${triggerPos.toStringAsFixed(2)}s len=${currentLength.toStringAsFixed(2)}s',
    );
  }

  void _onAutoTransitionPos(
    int syncHandle,
    int channel,
    int data,
    ffi.Pointer<ffi.Void> user,
  ) {
    if (_transitionSyncHandle == syncHandle) {
      _transitionSyncHandle = null;
      _transitionSyncChannel = null;
    }
    _beginAutoTransition(user.address, channel);
  }

  void _beginAutoTransition(int generation, int channel) {
    if (generation != _transitionGeneration) return;
    if (channel != _fstream) return;
    _lingeringPath = _fPath;
    final newStream = _queuedStream;
    if (newStream == null) return;
    _transitionTimer?.cancel();
    final pref = AppPreference.instance.playbackPref;
    final mode = _queuedTransitionMode ?? pref.transitionMode;
    log.bass.info(
      'legacy',
      '[bass] auto transition triggered: mode=${mode.name}',
    );
    final fadeOutMs = pref.transitionFadeOutMs;
    final fadeInMs = pref.transitionFadeInMs;
    final crossfade = mode == TransitionMode.crossfade;
    final oldStream = _fstream!;
    final gen = generation;
    _transitionHandledCompletion = true;
    // 交叉淡化会提前切到下一首并取消下面的激活定时器。
    // 完成标记必须在这里先挂上，否则曲尾停播会被永久吞掉。
    _armHandledCompletionClear(
      hold: Duration(milliseconds: math.max(fadeOutMs, fadeInMs) + 1500),
    );

    if (crossfade) {
      if (!_attachQueuedStream(_mixerGeneration, newStream) ||
          !_isOutputActive()) {
        _failHandledAutoTransition();
        return;
      }
      _transitionOldStream = oldStream;
      _fadeOutOldStream(
        oldStream,
        durationMs: fadeOutMs,
        delayCleanup: true,
        removeFromMixer: true,
        transitionGeneration: gen,
      );
      _fadeInNewStream(newStream, durationMs: fadeInMs);
      _transitionTimer = Timer(Duration(milliseconds: fadeOutMs + 50), () {
        if (gen != _transitionGeneration) return;
        _transitionTimer = null;
        if (_activateQueuedStream(_mixerGeneration, newStream) == null) {
          _failHandledAutoTransition();
          return;
        }
      });
    } else {
      _transitionOldStream = oldStream;
      _fadeOutOldStream(
        oldStream,
        durationMs: fadeOutMs,
        delayCleanup: true,
        removeFromMixer: true,
        transitionGeneration: gen,
      );
      _transitionTimer = Timer(Duration(milliseconds: fadeOutMs), () {
        if (gen != _transitionGeneration) return;
        _transitionTimer = null;
        if (!_attachQueuedStream(_mixerGeneration, newStream) ||
            !_isOutputActive()) {
          _failHandledAutoTransition();
          return;
        }
        _fadeInNewStream(newStream, durationMs: fadeInMs);
        if (_activateQueuedStream(_mixerGeneration, newStream) == null) {
          _failHandledAutoTransition();
          return;
        }
      });
    }
  }

  void _failHandledAutoTransition() {
    _handledCompletionClearTimer?.cancel();
    _handledCompletionClearTimer = null;
    _transitionHandledCompletion = false;
    _cancelTransition();
    // 完成事件只走位置轮询。这里再推一次的话，解除抑制后会连跳两首。
  }

  void _armHandledCompletionClear({Duration? hold}) {
    _handledCompletionClearTimer?.cancel();
    _handledCompletionClearTimer = Timer(
      hold ?? const Duration(seconds: 2),
      () {
        _handledCompletionClearTimer = null;
        _resumeOutputIfNeeded();
        _transitionHandledCompletion = false;
      },
    );
  }

  void _markTransitionOutputHealthy() {
    _handledCompletionClearTimer?.cancel();
    _handledCompletionClearTimer = null;
    _transitionHandledCompletion = false;
  }

  void _resumeOutputIfNeeded() {
    final output = _mixerStream;
    if (output == null || wasapiExclusive) return;
    final state = _bass.BASS_ChannelIsActive(output);
    if (!shouldRestartStoppedMixer(state)) return;
    if (_bass.BASS_ChannelStart(output) == 0) {
      log.bass.warn(
        'legacy',
        '[bass] resuming mixer after transition failed: '
            '${_bass.BASS_ErrorGetCode()}',
      );
      return;
    }
    log.bass.debug('legacy', '[bass] resumed mixer after transition');
  }

  bool _isOutputActive() {
    final output = _mixerStream;
    if (output == null) return false;
    return _bass.BASS_ChannelIsActive(output) != bass.BASS_ACTIVE_STOPPED;
  }

  bool consumeTransitionHandledCompletion() {
    if (!_transitionHandledCompletion) return false;
    _transitionHandledCompletion = false;
    return true;
  }

  GaplessTransition? _promoteDequeuedSource({bool emit = true}) {
    final queued = _queuedStream;
    if (queued == null ||
        !_queuedStreamAttached ||
        (_bassMix?.channelGetPosition(queued, bass.BASS_POS_BYTE) ?? -1) <= 0) {
      return null;
    }
    return _activateQueuedStream(_mixerGeneration, queued, emit: emit);
  }

  GaplessTransition? _activateQueuedStream(
    int generation,
    int stream, {
    bool emit = true,
  }) {
    if (generation != _mixerGeneration ||
        stream != _queuedStream ||
        !_queuedStreamAttached) {
      return null;
    }
    final queuedPath = _queuedPath;
    final queuedReplayGainDb = _queuedReplayGainDb;
    final transitionId = _queuedTransitionId;
    if (queuedPath == null || transitionId == null || _mixerStream == null) {
      return null;
    }

    _fstream = stream;
    _fPath = queuedPath;
    _cachedLengthSeconds = _queuedLengthSeconds;
    _queuedStream = null;
    _queuedStreamAttached = false;
    _queuedPath = null;
    _queuedLengthSeconds = null;
    _queuedReplayGainDb = null;
    _queuedTransitionId = null;
    _queuedTransitionMode = null;
    _activeGaplessTransitionId = transitionId;
    _transitionOldStream = null;
    _replayGainDb = queuedReplayGainDb;
    _refreshStreamSampleRate();
    _resetSpectrumSmoothing();
    final transition = GaplessTransition(
      id: transitionId,
      path: queuedPath,
      replayGainDb: queuedReplayGainDb,
    );
    _unreportedGaplessTransition = transition;
    if (emit) {
      scheduleMicrotask(() {
        if (_unreportedGaplessTransition != transition) return;
        _gaplessTransitionStreamController.add(transition);
      });
    }
    _emitPositionSnapshot();
    _publishAudioFiles();
    return transition;
  }

  void acknowledgeGaplessTransition(int transitionId) {
    if (_unreportedGaplessTransition?.id == transitionId) {
      _unreportedGaplessTransition = null;
    }
  }

  bool updateGaplessReplayGain(int transitionId, double? replayGainDb) {
    final queued = _queuedStream;
    if (_queuedTransitionId == transitionId && queued != null) {
      _queuedReplayGainDb = replayGainDb;
      _applySourceGain(queued, replayGainDb);
      return true;
    }

    if (_activeGaplessTransitionId != transitionId || _fstream == null) {
      return false;
    }
    _replayGainDb = replayGainDb;
    _applyPlaybackGains();
    return true;
  }

  /// true: 操作成功；false: 操作失败
  bool useExclusiveMode(bool exclusive) {
    _cancelPendingPause();
    _cancelOutputGainFade(keepTarget: true);
    final prevState = wasapiExclusive;
    if (exclusive == prevState) return true;
    try {
      if (exclusive && !hasAudioSource) {
        const message = '独占模式未切换：当前没有可用的音频流';
        log.bass.warn('legacy', '[bass] $message');
        showTextOnSnackBar(message, variant: ToastVariant.error);
        return false;
      }
      if (exclusive) {
        final conflicts = exclusiveModeConflicts;
        if (conflicts.isNotEmpty) {
          log.bass.info(
            'legacy',
            '[bass] exclusive mode requested with upper-layer conflicts: '
                '${conflicts.join('、')}',
          );
        }
      }
      final lastPos = position;
      final wasPlaying = playerState == PlayerState.playing;
      final targetVolume = _baseOutputVolume;

      if (exclusive && !prevState) {
        if (_fstream == null || _fPath == null) return false;
        // 1) 建解码流（旧流仍在播放，文件 I/O 对用户透明）
        final decodeHandle = _createSharedSource(_fPath!);
        if (decodeHandle == 0) {
          throw Exception('Failed to create decode stream');
        }

        // 2) 预初始化 WASAPI，旧流继续通过 BASS 播放
        _positionUpdaterVersion++;
        _positionUpdater?.cancel();
        _positionUpdater = null;
        final oldHandle = _sharedOutputHandle!;
        final oldSource = _fstream!;
        _fstream = decodeHandle;
        _streamWasapiExclusive = true;
        wasapiExclusive = true;
        try {
          _bassWasapiInit();
        } catch (err) {
          _bass.BASS_StreamFree(decodeHandle);
          _fstream = oldSource;
          _streamWasapiExclusive = false;
          wasapiExclusive = false;
          refreshEQ();
          if (wasPlaying) _startPositionUpdater();
          showTextOnSnackBar('独占模式初始化失败', variant: ToastVariant.error);
          return false;
        }

        // 3) WASAPI 准备就绪，停旧流（间隙极短，仅 Start 耗时）
        _fadeOutOldStream(oldHandle);
        _removeEQ();
        _removeAudioEffects();
        if (_mixerStream != null) {
          _dropGaplessMixer();
        } else {
          _bass.BASS_ChannelStop(oldHandle);
          _bass.BASS_StreamFree(oldHandle);
        }

        // 4) 启动 WASAPI 输出
        _fstream = decodeHandle;
        _bass.BASS_ChannelSetAttribute(
          decodeHandle,
          bass.BASS_ATTRIB_VOLDSP,
          0.0,
        );
        if (lastPos > 0) seek(lastPos);
        if (wasPlaying && _bassWasapi.BASS_WASAPI_Start() == bass.FALSE) {
          _fallbackFromExclusive();
          onExclusiveModeChanged?.call(false);
          return false;
        }
        if (wasPlaying) {
          _fadeInWasapiVolume(targetVolume);
        } else {
          setVolumeDsp(targetVolume);
        }
        _playerStateStreamController.add(
          wasPlaying ? playerState : PlayerState.paused,
        );
        _refreshStreamSampleRate();
        _spectrumTickPeriod = _computeSpectrumTickPeriod();
        _lastSpectrumUpdateUs = 0;
        if (wasPlaying) _startPositionUpdater();
      } else if (!exclusive && prevState) {
        _removeEQ();
        _removeAudioEffects();
        _positionUpdaterVersion++;
        _positionUpdater?.cancel();
        _positionUpdater = null;
        _releaseWasapiOutput();
        _bass.BASS_StreamFree(_fstream!);
        _fstream = null;
        _streamWasapiExclusive = false;
        wasapiExclusive = false;
        _bassInit(resetHandles: false);
        if (_fPath != null) {
          _createSharedStream(_fPath!, lastPos, startPlayback: wasPlaying);
        }
      } else {
        wasapiExclusive = exclusive;
        if (_fstream != null && _fPath != null) {
          _rebuildStream(_fPath!, lastPos, startPlayback: wasPlaying);
        }
      }

      onExclusiveModeChanged?.call(wasapiExclusive);
      return wasapiExclusive == exclusive;
    } catch (err, trace) {
      log.bass.error('legacy', '切换独占模式失败', error: err, stackTrace: trace);
      showTextOnSnackBar('切换独占模式失败，请查看日志');
      _playerStateStreamController.add(playerState);
    }
    wasapiExclusive = _fstream != null && _streamWasapiExclusive;
    onExclusiveModeChanged?.call(wasapiExclusive);
    return false;
  }

  void _stopWasapiOutputIfNeeded() {
    if (!wasapiExclusive &&
        !_streamWasapiExclusive &&
        !_wasapiInitialized &&
        !_wasapiStarted) {
      return;
    }
    _releaseWasapiOutput();
  }

  void _releaseWasapiOutput({bool updateInfo = true}) {
    if (_wasapiStarted) {
      _bassWasapi.BASS_WASAPI_Stop(bass.TRUE);
    }
    if (_wasapiInitialized || _wasapiStarted) {
      _bassWasapi.BASS_WASAPI_Free();
    }
    _wasapiInitialized = false;
    _wasapiStarted = false;
    if (updateInfo) _wasapiOutputInfo = 'off';
  }

  /// Rebuilds the audio stream after output-mode changes.
  void _rebuildStream(
    String path,
    double seekTo, {
    required bool startPlayback,
  }) {
    _logAudioState('_rebuildStream(begin)');
    _positionUpdaterVersion++;
    _positionUpdater?.cancel();
    _positionUpdater = null;

    final oldHandle = _sharedOutputHandle!;
    final oldWasapiExclusive = wasapiExclusive || _streamWasapiExclusive;
    if (oldWasapiExclusive) {
      _fadeInTimer?.cancel();
      _fadeInTimer = null;
      _stopWasapiOutputIfNeeded();
    } else {
      _fadeOutOldStream(oldHandle);
    }
    _removeEQ();
    _removeAudioEffects();
    if (_mixerStream != null) {
      _dropGaplessMixer();
    } else {
      _bass.BASS_ChannelStop(oldHandle);
      _bass.BASS_StreamFree(oldHandle);
      _fstream = null;
    }
    _cachedLengthSeconds = null;

    wasapiExclusive
        ? _createWasapiStream(path, seekTo, startPlayback: startPlayback)
        : _createSharedStream(path, seekTo, startPlayback: startPlayback);
    _logAudioState('_rebuildStream(done)');
  }

  static bool _isUrl(String value) {
    final lower = value.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  int _createUrlStream(String url, {required int flags}) {
    final handle = _bassUrl.streamCreateUrl(url, flags: flags);
    if (handle == 0) {
      log.bass.warn(
        'legacy',
        '[bass] URL stream failed: ${_redactUrlForLog(url)}',
      );
    }
    return handle;
  }

  static String _redactUrlForLog(String url) {
    final newline = url.indexOf('\r\n');
    final address = newline < 0 ? url : url.substring(0, newline);
    final uri = Uri.tryParse(address);
    if (uri == null || uri.host.isEmpty) return '<url>';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port${uri.path}';
  }

  int _createDecodeStream(String path) {
    if (_isUrl(path)) {
      return _createUrlStream(
        path,
        flags: bass.BASS_SAMPLE_FLOAT | bass.BASS_STREAM_DECODE,
      );
    }
    const flags =
        bass.BASS_UNICODE |
        bass.BASS_SAMPLE_FLOAT |
        bass.BASS_ASYNCFILE |
        bass.BASS_STREAM_DECODE;
    final pathPointer = path.toNativeUtf16() as ffi.Pointer<ffi.Void>;
    final handle = _bass.BASS_StreamCreateFile(
      bass.FALSE,
      pathPointer,
      0,
      0,
      flags,
    );
    malloc.free(pathPointer);
    return handle;
  }

  /// 创建独占模式流
  void _createWasapiStream(
    String path,
    double seekTo, {
    bool startPlayback = true,
  }) {
    final handle = _createDecodeStream(path);
    if (handle == 0) {
      throw Exception('Failed to create WASAPI exclusive stream');
    }

    _fstream = handle;
    _streamWasapiExclusive = true;
    _refreshStreamSampleRate();
    _refreshCachedLength();

    if (seekTo > 0.0) {
      seek(seekTo);
    }
    if (startPlayback) {
      start();
    } else {
      _applyPlaybackGains();
      _playerStateStreamController.add(PlayerState.paused);
    }
  }

  /// 创建共享模式流
  void _createSharedStream(
    String path,
    double seekTo, {
    bool startPlayback = true,
  }) {
    final handle = _createSharedPlaybackSource(path);
    if (handle == 0) {
      throw Exception('Failed to create shared source');
    }

    _fstream = handle;
    _streamWasapiExclusive = false;
    _refreshStreamSampleRate();
    _refreshCachedLength();
    if (seekTo > 0.0) {
      seek(seekTo);
    }
    if (!_isEqFlat) {
      refreshEQ();
    }
    refreshAudioEffects();
    _applyPlaybackGains();
    if (startPlayback) {
      start();
    } else {
      _playerStateStreamController.add(PlayerState.paused);
    }
  }

  /// Crossfade: 淡出旧流
  /// [durationMs] 淡出时长；[delayCleanup] 为 true 时延迟释放资源，用于曲间 crossfade
  void _fadeOutOldStream(
    int handle, {
    int durationMs = 100,
    bool delayCleanup = false,
    bool removeFromMixer = false,
    int? transitionGeneration,
  }) {
    final sliding = _bass.BASS_ChannelSlideAttribute(
      handle,
      bass.BASS_ATTRIB_VOL,
      0.0,
      durationMs,
    );
    if (sliding == bass.FALSE) {
      _bass.BASS_ChannelSetAttribute(handle, bass.BASS_ATTRIB_VOL, 0.0);
    }

    if (!delayCleanup) return;

    // 清理上一条未释放的旧流
    _fadeOutTimer?.cancel();
    if (_fadeOutHandle != null && _fadeOutHandle != handle) {
      final previous = _fadeOutHandle!;
      final previousRemove = _fadeOutRemoveFromMixer;
      _fadeOutHandle = null;
      _fadeOutRemoveFromMixer = false;
      _discardFadedSource(previous, removeFromMixer: previousRemove);
    }
    _fadeOutHandle = handle;
    _fadeOutRemoveFromMixer = removeFromMixer;

    _fadeOutTimer = Timer(Duration(milliseconds: durationMs + 20), () {
      if (_fadeOutHandle != handle) return;
      _fadeOutHandle = null;
      _fadeOutRemoveFromMixer = false;
      _fadeOutTimer = null;
      _discardFadedSource(
        handle,
        removeFromMixer: removeFromMixer,
        completeTransition: true,
        transitionGeneration: transitionGeneration,
      );
    });
  }

  /// 淡出结束后拆掉旧源。旧源被拆掉时如果新源还没出声，
  /// BASS_MIXER_END 会把整路输出停掉，这里把混音器拉起来。
  /// 过渡被取消且这首仍在播时不能拆，否则会把当前歌释放掉。
  void _discardFadedSource(
    int handle, {
    required bool removeFromMixer,
    bool completeTransition = false,
    int? transitionGeneration,
  }) {
    final stillLive = !shouldReleaseFadedSource(
      handle: handle,
      currentHandle: _fstream,
      queuedHandle: _queuedStream,
    );
    if (shouldKeepLiveFadedSource(
      stillLive: stillLive,
      scheduledGeneration: transitionGeneration,
      currentGeneration: _transitionGeneration,
    )) {
      _bass.BASS_ChannelSetAttribute(handle, bass.BASS_ATTRIB_VOL, 1.0);
      return;
    }
    if (removeFromMixer) {
      _bassMix?.channelRemove(handle);
    }
    _bass.BASS_ChannelStop(handle);
    _bass.BASS_StreamFree(handle);
    if (_fadeOutHandle == null) _lingeringPath = null;
    _publishAudioFiles();
    _resumeOutputIfNeeded();
    if (completeTransition && removeFromMixer && _isOutputActive()) {
      _markTransitionOutputHealthy();
    }
  }

  /// Crossfade: 淡入新流 - 从静音滑到正常播放音量（手动切歌防爆音用，固定短时长）
  void _fadeInNewStream(int handle, {int durationMs = 200}) {
    if (durationMs <= 0) {
      _bass.BASS_ChannelSetAttribute(handle, bass.BASS_ATTRIB_VOL, 1.0);
      return;
    }
    _bass.BASS_ChannelSetAttribute(handle, bass.BASS_ATTRIB_VOL, 0.0);
    final sliding = _bass.BASS_ChannelSlideAttribute(
      handle,
      bass.BASS_ATTRIB_VOL,
      1.0,
      durationMs,
    );
    if (sliding == bass.FALSE) {
      _bass.BASS_ChannelSetAttribute(handle, bass.BASS_ATTRIB_VOL, 1.0);
    }
  }

  /// if setSource has been called once,
  /// it will pause current channel and free current stream.
  void setSource(String path) {
    _cancelPendingPause();
    _cancelOutputGainFade(keepTarget: true);
    _replayGainDb = null;
    _activeGaplessTransitionId = null;
    _handledCompletionClearTimer?.cancel();
    _handledCompletionClearTimer = null;
    _transitionHandledCompletion = false;
    _logAudioState('setSource(begin)');
    if (_fstream != null) {
      _positionUpdaterVersion++;
      _positionUpdater?.cancel();
      _positionUpdater = null;
      _removeEQ();
      _removeAudioEffects();
      final oldHandle = _sharedOutputHandle!;
      final oldWasapiExclusive = wasapiExclusive || _streamWasapiExclusive;

      if (oldWasapiExclusive) {
        _fadeInTimer?.cancel();
        _fadeInTimer = null;
        _stopWasapiOutputIfNeeded();
        _bass.BASS_ChannelStop(oldHandle);
        _bass.BASS_StreamFree(oldHandle);
      } else {
        final output = _mixerStream == null
            ? oldHandle
            : _detachGaplessMixer()!;
        // 手动切歌防爆音：固定短淡出（300ms），新歌立即淡入。
        // 旧文件还要等淡出结束才松开。
        _lingeringPath = _fPath;
        _fadeOutOldStream(output, durationMs: 300, delayCleanup: true);
      }
      _fstream = null;
      _cachedLengthSeconds = null;
      _streamWasapiExclusive = false;
    }
    final handle = wasapiExclusive
        ? _createDecodeStream(path)
        : _createSharedPlaybackSource(path);

    if (handle != 0) {
      _fstream = handle;
      _fPath = path;
      // 标记当前流是否为独占模式流
      _streamWasapiExclusive = wasapiExclusive;
      _refreshStreamSampleRate();
      _refreshCachedLength();

      try {
        refreshEQ();
        refreshAudioEffects();
      } catch (e) {
        log.bass.error('legacy', 'SetSource refreshEQ failed: $e');
      }

      _applyPlaybackGains();
      _logAudioState('setSource(ok)');
    } else {
      _fstream = null;
      _fPath = null;
      _cachedLengthSeconds = null;
      _streamWasapiExclusive = false;
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_INIT:
          _bassInit();
          setSource(path);
          break;
        case bass.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
            'The BASS_STREAM_AUTOFREE flag cannot be combined with the BASS_STREAM_DECODE flag.',
          );
        case bass.BASS_ERROR_ILLPARAM:
          throw const FormatException(
            'The length must be specified when streaming from memory.',
          );
        case bass.BASS_ERROR_FILEOPEN:
          throw const FormatException('The file could not be opened.');
        case bass.BASS_ERROR_FILEFORM:
          throw const FormatException(
            "The file's format is not recognised/supported.",
          );
        case bass.BASS_ERROR_NOTAUDIO:
          throw const FormatException(
            'The file does not contain audio, or it also contains video and videos are disabled.',
          );
        case bass.BASS_ERROR_CODEC:
          throw const FormatException(
            'The file uses a codec that is not available/supported. This can apply to WAV and AIFF files.',
          );
        case bass.BASS_ERROR_FORMAT:
          throw const FormatException('The sample format is not supported.');
        case bass.BASS_ERROR_SPEAKER:
          throw const FormatException(
            'The specified SPEAKER flags are invalid.',
          );
        case bass.BASS_ERROR_MEM:
          throw const FormatException('There is insufficient memory.');
        case bass.BASS_ERROR_NO3D:
          throw const FormatException('Could not initialize 3D support.');
        case bass.BASS_ERROR_UNKNOWN:
          throw const FormatException('Some other mystery problem!');
      }
    }
    _publishAudioFiles();
  }

  /// [BASS_ATTRIB_VOLDSP] attribute does have direct effect on decoding/recording channels.
  void setVolumeDsp(double volume) {
    _cancelOutputGainFade();
    _baseOutputVolume = volume.isFinite
        ? volume.clamp(0.0, eqOutputVolumeMax).toDouble()
        : 0.0;
    _applyPlaybackGains();
  }

  void fadeToVolumeDsp(double volume, {int durationMs = 80}) {
    final target = volume.isFinite
        ? volume.clamp(0.0, eqOutputVolumeMax).toDouble()
        : 0.0;
    _cancelOutputGainFade();
    final start = _baseOutputVolume;
    if (_fstream == null || !start.isFinite || (start - target).abs() < 0.001) {
      _baseOutputVolume = target;
      _applyPlaybackGains();
      return;
    }

    final steps = math.max(2, (durationMs / 10).round());
    final intervalMs = math.max(10, (durationMs / steps).round());
    var step = 0;
    _outputGainFadeTarget = target;
    _outputGainFadeTimer = Timer.periodic(Duration(milliseconds: intervalMs), (
      timer,
    ) {
      step++;
      final progress = (step / steps).clamp(0.0, 1.0).toDouble();
      _baseOutputVolume = start + (target - start) * progress;
      _applyPlaybackGains();
      if (step >= steps) {
        _baseOutputVolume = target;
        _outputGainFadeTarget = null;
        timer.cancel();
        _outputGainFadeTimer = null;
        _applyPlaybackGains();
      }
    });
  }

  void _cancelOutputGainFade({bool keepTarget = false}) {
    _outputGainFadeTimer?.cancel();
    _outputGainFadeTimer = null;
    final target = _outputGainFadeTarget;
    _outputGainFadeTarget = null;
    if (keepTarget && target != null) _baseOutputVolume = target;
  }

  void setRate(double rate) {
    _rate = rate;
    if (_fstream == null) return;

    // bass_fx.dll 已在构造时预加载，直接使用
    if (wasapiExclusive && _rate != 1.0) {
      log.bass.warn(
        'legacy',
        '[bass] rate change in exclusive mode, fallback to shared mode',
      );
      useExclusiveMode(false);
      return;
    }

    // 尝试设置 Tempo (百分比变化)
    // 1.0 -> 0%, 1.5 -> 50%, 0.5 -> -50%
    final tempo = (_rate - 1.0) * 100.0;

    // 优先尝试使用 BASS_FX 的 Tempo 属性
    if (_bass.BASS_ChannelSetAttribute(_fstream!, BASS_ATTRIB_TEMPO, tempo) ==
        0) {
      final freqPtr = malloc.allocate<ffi.Float>(ffi.sizeOf<ffi.Float>());
      try {
        if (_bass.BASS_ChannelGetAttribute(
              _fstream!,
              bass.BASS_ATTRIB_FREQ,
              freqPtr,
            ) !=
            0) {
          log.bass.warn(
            'legacy',
            'BASS_ATTRIB_TEMPO failed, and fallback implementation is skipped.',
          );
        }
      } finally {
        malloc.free(freqPtr);
      }
    }
    final queued = _queuedStream;
    if (queued != null) {
      _bass.BASS_ChannelSetAttribute(queued, BASS_ATTRIB_TEMPO, tempo);
    }
  }

  void setPitch(double pitch) {
    _pitch = pitch;
    if (_fstream == null) return;

    // bass_fx.dll 已在构造时预加载，直接使用
    if (wasapiExclusive && _pitch != 0.0) {
      log.bass.warn(
        'legacy',
        '[bass] pitch change in exclusive mode, fallback to shared mode',
      );
      useExclusiveMode(false);
      return;
    }

    _bass.BASS_ChannelSetAttribute(_fstream!, BASS_ATTRIB_TEMPO_PITCH, pitch);
    final queued = _queuedStream;
    if (queued != null) {
      _bass.BASS_ChannelSetAttribute(queued, BASS_ATTRIB_TEMPO_PITCH, pitch);
    }
  }

  void _bassWasapiInit() {
    if (_fstream == null) return;

    // 重置WASAPI状态
    _wasapiOutputInfo = 'initializing';
    _releaseWasapiOutput(updateInfo: false);

    // 添加 AUTOFORMAT 和 BUFFER 标志
    const flags =
        bass_wasapi.BASS_WASAPI_EXCLUSIVE |
        bass_wasapi.BASS_WASAPI_AUTOFORMAT |
        bass_wasapi.BASS_WASAPI_EVENT |
        bass_wasapi.BASS_WASAPI_BUFFER |
        bass_wasapi.BASS_WASAPI_ASYNC;
    // 根据音频采样率动态计算缓冲区，高码率文件自动获得更大缓冲
    final bufferSec = _computeWasapiBufferSec();
    const initFreq = 0; // 让 WASAPI 自动选择合适的采样率

    // WASAPI 初始化重试机制：最多重试 3 次以解决 BASS_ERROR_BUSY
    final savedDevice =
        AppPreference.instance.playbackPref.wasapiOutputDevice;
    final resolvedDevice = _resolveWasapiDeviceIndex(savedDevice);
    final wasapiDevice = resolvedDevice ?? -1;
    if (savedDevice.isNotEmpty && resolvedDevice == null) {
      log.bass.warn(
        'legacy',
        '[bass] WASAPI output device is unavailable, using system default',
      );
    }
    int result = bass.FALSE;
    for (int attempt = 0; attempt < 3; attempt++) {
      result = _bassWasapi.BASS_WASAPI_Init(
        wasapiDevice, // 选定的设备；-1 表示系统默认
        initFreq,
        0, // 自动选择声道数
        flags,
        bufferSec,
        0.0,
        ffi.Pointer<bass_wasapi.WASAPIPROC>.fromAddress(-1), // -1 表示无自定义回调
        ffi.Pointer<ffi.Void>.fromAddress(_fstream!), // 使用整数 handle
      );

      if (result != bass.FALSE) break; // 成功，跳出循环

      final errCode = _bass.BASS_ErrorGetCode();
      if (errCode != bass.BASS_ERROR_BUSY) break; // 非 BUSY 错误，不重试

      // 等待 50ms 让流完全释放后再重试
      _sleepSync(50);
    }

    if (result == bass.FALSE) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass_wasapi.BASS_ERROR_WASAPI:
          throw const FormatException('WASAPI is not available.');
        case bass.BASS_ERROR_DEVICE:
          throw const FormatException('device is invalid.');
        case bass.BASS_ERROR_ALREADY:
          _releaseWasapiOutput(updateInfo: false);
          _bassWasapiInit();
          break;
        case bass.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
            'Exclusive mode and/or event-driven buffering is unavailable on the device, or WASAPIPROC_PUSH is unavailable on input devices and when using event-driven buffering.',
          );
        case bass.BASS_ERROR_DRIVER:
          throw const FormatException('The driver could not be initialized.');
        case bass.BASS_ERROR_HANDLE:
          throw const FormatException(
            'The BASS channel handle in user is invalid, or not of the required type.',
          );
        case bass.BASS_ERROR_FORMAT:
          throw const FormatException(
            'The specified format (or that of the BASS channel) is not supported by the device. If the BASS_WASAPI_AUTOFORMAT flag was specified, no other format could be found either.',
          );
        case bass.BASS_ERROR_BUSY:
          throw const FormatException(
            'The device is already in use, eg. another process may have initialized it in exclusive mode.',
          );
        case bass.BASS_ERROR_INIT:
          throw const FormatException('BASS is not initialized.');
        case bass_wasapi.BASS_ERROR_WASAPI_BUFFER:
          throw const FormatException(
            'buffer is too large or small (exclusive mode only).',
          );
        case bass_wasapi.BASS_ERROR_WASAPI_CATEGORY:
          throw const FormatException(
            'The category/raw mode could not be set.',
          );
        case bass_wasapi.BASS_ERROR_WASAPI_DENIED:
          throw const FormatException(
            'Access to the device is denied. This could be due to privacy settings.',
          );
        case bass.BASS_ERROR_UNKNOWN:
          throw const FormatException('Some other mystery problem!');
      }
    } else {
      _wasapiInitialized = true;
      _wasapiStarted = false;
      _refreshWasapiOutputInfo(bufferSec);
    }
  }

  void _startWasapiExclusive() {
    try {
      _bassWasapiInit();
    } catch (err) {
      log.bass.warn(
        'legacy',
        '[bass] wasapi exclusive init failed, fallback to shared: $err',
      );
      showTextOnSnackBar('独占模式初始化失败，已切回共享模式', variant: ToastVariant.error);
      _fallbackFromExclusive();
      onExclusiveModeChanged?.call(false);
      return;
    }

    if (_bassWasapi.BASS_WASAPI_Start() == bass.FALSE) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_INIT:
          _bassWasapiInit();
          _startWasapiExclusive();
          return;
        case bass.BASS_ERROR_UNKNOWN:
          throw const FormatException('Some other mystery problem!');
      }
    } else {
      _wasapiStarted = true;
    }

    // 正常启动（切歌/恢复），直接应用当前输出增益，不做淡入
    _applyPlaybackGains();

    _playerStateStreamController.add(playerState);
    _positionUpdater?.cancel();
    _positionUpdater = null;
    _refreshStreamSampleRate();
    _spectrumTickPeriod = _computeSpectrumTickPeriod();
    _lastSpectrumUpdateUs = 0;
    _startPositionUpdater();
  }

  void _fallbackFromExclusive() {
    _cancelPendingPause();
    final seekPos = position;
    final sourcePath = _fPath;
    _releaseWasapiOutput();
    if (_fstream != null) {
      _bass.BASS_StreamFree(_fstream!);
      _fstream = null;
    }
    wasapiExclusive = false;
    _streamWasapiExclusive = false;
    _bassInit();
    if (sourcePath != null) {
      _positionUpdaterVersion++;
      _positionUpdater?.cancel();
      _positionUpdater = null;
      _restoreSharedSource(sourcePath, seekPos);
    }
  }

  void _fadeInWasapiVolume(double target) {
    _fadeInTimer?.cancel();
    const steps = 10;
    const stepMs = 20;
    int step = 0;
    _fadeInTimer = Timer.periodic(const Duration(milliseconds: stepMs), (
      timer,
    ) {
      step++;
      if (step >= steps) {
        setVolumeDsp(target);
        timer.cancel();
        _fadeInTimer = null;
      } else {
        setVolumeDsp(target * (step / steps));
      }
    });
  }

  /// start/resume channel
  ///
  /// do nothing if [setSource] hasn't been called
  void start() {
    if (_fstream == null) return;
    _cancelPendingPause();

    if (wasapiExclusive) {
      _logAudioState('start(wasapi)');
      return _startWasapiExclusive();
    }
    _logAudioState('start(normal)');

    final output = _sharedOutputHandle!;
    _bass.BASS_ChannelSetAttribute(output, bass.BASS_ATTRIB_VOL, 0.0);

    if (_bass.BASS_ChannelStart(output) == 0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_HANDLE:
          throw const FormatException('handle is not a valid channel.');
        case bass.BASS_ERROR_DECODE:
          throw const FormatException(
            'handle is a decoding channel, so cannot be played.',
          );
        case bass.BASS_ERROR_START:
          final restartPath = _fPath;
          final restartPosition = position;
          if (!_startDevice()) {
            if (restartPath == null) {
              throw const FormatException('BASS source is unavailable.');
            }
            _restoreSharedSource(restartPath, restartPosition);
            return;
          }
          if (_bass.BASS_ChannelStart(output) == 0) {
            throw const FormatException('Failed to start output device.');
          }
          break;
      }
    }

    // Crossfade: fade in the new stream.
    _fadeInNewStream(output);

    _playerStateStreamController.add(playerState);
    _positionUpdater?.cancel();
    _positionUpdater = null;
    _refreshStreamSampleRate();
    _spectrumTickPeriod = _computeSpectrumTickPeriod();
    _lastSpectrumUpdateUs = 0;
    _startPositionUpdater();
    _logAudioState('start(done)');
  }

  void _pauseWasapiExclusive() {
    if (_bassWasapi.BASS_WASAPI_Stop(bass.FALSE) == bass.TRUE) {
      _wasapiStarted = false;
      _playerStateStreamController.add(playerState);
      _positionUpdater?.cancel();
      _emitPositionSnapshot();
    }
  }

  void _startWasapiPauseFade() {
    _pauseFadeHandle = _fstream;
    _playerStateStreamController.add(PlayerState.paused);
    _logAudioState('pause(wasapi-fade)');
    const steps = 8;
    const stepMs = 18;
    var step = 0;
    _pauseFadeTimer = Timer.periodic(
      const Duration(milliseconds: stepMs),
      (timer) {
        step++;
        _pauseFadeGain = math.max(0.0, 1.0 - step / steps);
        _applyPlaybackGains();
        if (step < steps) return;
        timer.cancel();
        _finishWasapiPause();
      },
    );
  }

  void _finishWasapiPause() {
    _pauseFadeTimer = null;
    final handle = _pauseFadeHandle;
    _pauseFadeHandle = null;
    final stopped =
        handle != null &&
        _fstream == handle &&
        _bassWasapi.BASS_WASAPI_Stop(bass.FALSE) == bass.TRUE;
    if (stopped) _wasapiStarted = false;
    _pauseFadeGain = 1.0;
    _applyPlaybackGains();
    _playerStateStreamController.add(playerState);
    _positionUpdater?.cancel();
    _emitPositionSnapshot();
    if (stopped) _logAudioState('pause(wasapi-fade-done)');
  }

  /// 取消待执行的暂停淡出，输出增益立即回到正常
  void _cancelPendingPause() {
    _pauseFadeTimer?.cancel();
    _pauseFadeTimer = null;
    _pauseFadeHandle = null;
    if (_pauseFadeGain != 1.0) {
      _pauseFadeGain = 1.0;
      _applyPlaybackGains();
    }
  }

  /// pause channel, call [start] to resume channel
  ///
  /// do nothing if [setSource] hasn't been called
  void pause() {
    if (_fstream == null) return;
    if (_pauseFadeTimer != null) return;

    final state = playerState;
    final fading = state == PlayerState.playing || state == PlayerState.stalled;

    if (wasapiExclusive) {
      _logAudioState('pause(wasapi)');
      if (!fading) return _pauseWasapiExclusive();
      return _startWasapiPauseFade();
    }
    _logAudioState('pause(normal)');

    if (!fading) return _pauseSharedImmediate();
    _startSharedPauseFade();
  }

  void _pauseSharedImmediate() {
    final output = _sharedOutputHandle!;
    if (_bass.BASS_ChannelPause(output) == 0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_HANDLE:
          throw const FormatException('handle is not a valid channel.');
        case bass.BASS_ERROR_DECODE:
          throw const FormatException(
            'handle is a decoding channel, so cannot be played or paused.',
          );
        case bass.BASS_ERROR_NOPLAY:
          _playerStateStreamController.add(playerState);
          _positionUpdater?.cancel();
          _emitPositionSnapshot();
          _logAudioState('pause(noplay)');
          return;
      }
    }

    _playerStateStreamController.add(playerState);
    _positionUpdater?.cancel();
    _emitPositionSnapshot();
    _logAudioState('pause(done)');
  }

  void _startSharedPauseFade() {
    final output = _sharedOutputHandle!;
    final sliding = _bass.BASS_ChannelSlideAttribute(
      output,
      bass.BASS_ATTRIB_VOL,
      0.0,
      _pauseFadeMs,
    );
    if (sliding == bass.FALSE) {
      _bass.BASS_ChannelSetAttribute(output, bass.BASS_ATTRIB_VOL, 0.0);
    }
    _playerStateStreamController.add(PlayerState.paused);
    _logAudioState('pause(fade)');
    _pauseFadeTimer = Timer(
      const Duration(milliseconds: _pauseFadeMs + 20),
      _finishSharedPause,
    );
  }

  void _finishSharedPause() {
    _pauseFadeTimer = null;
    final output = _sharedOutputHandle;
    if (output == null) return;
    final paused = _bass.BASS_ChannelPause(output);
    if (paused == 0) {
      // 定时器内不能向上抛，记录错误并恢复音量，避免停在 0 音量
      final code = _bass.BASS_ErrorGetCode();
      _bass.BASS_ChannelSetAttribute(output, bass.BASS_ATTRIB_VOL, 1.0);
      _playerStateStreamController.add(playerState);
      _positionUpdater?.cancel();
      _emitPositionSnapshot();
      log.bass.warn('legacy', '[bass] pause(fade) failed: $code');
      return;
    }
    _bass.BASS_ChannelSetAttribute(output, bass.BASS_ATTRIB_VOL, 1.0);
    _playerStateStreamController.add(PlayerState.paused);
    _positionUpdater?.cancel();
    _emitPositionSnapshot();
    _logAudioState('pause(fade-done)');
  }

  /// set channel's position to given [position]
  /// don't check if the position is valid.
  ///
  /// do nothing if [setSource] hasn't been called
  void seek(double position) {
    if (_fstream == null) return;
    _logAudioState('seek(begin,$position)');

    final source = _fstream!;
    final pos = _bass.BASS_ChannelSeconds2Bytes(source, position);
    final positioned = _mixerStream == null
        ? _bass.BASS_ChannelSetPosition(source, pos, bass.BASS_POS_BYTE) != 0
        : _bassMix!.channelSetPosition(
            source,
            pos,
            bass.BASS_POS_BYTE | bassPosMixerReset,
          );
    if (!positioned) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_HANDLE:
          throw const FormatException('handle is not a valid channel.');
        case bass.BASS_ERROR_NOTFILE:
          throw const FormatException('The stream is not a file stream.');
        case bass.BASS_ERROR_POSITION:
          throw const FormatException(
            'The requested position is invalid, eg. it is beyond the end or the download has not yet reached it.',
          );
        case bass.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
            'The requested mode is not available. Invalid flags are ignored and do not result in this error.',
          );
        case bass.BASS_ERROR_UNKNOWN:
          throw const FormatException('Some other mystery problem!');
      }
    }
    _resetSpectrumSmoothing();
    _emitPositionSnapshot();
    _logAudioState('seek(end,$position)');
  }

  /// It is not necessary to individually free the samples/streams/musics
  /// as these are all automatically freed after [setSource] or [free] is called.
  ///
  /// do nothing if [setSource] hasn't been called
  void freeFStream() {
    _cancelOutputGainFade(keepTarget: true);
    _fadeInTimer?.cancel();
    _fadeInTimer = null;
    _fadeOutTimer?.cancel();
    _fadeOutTimer = null;
    _handledCompletionClearTimer?.cancel();
    _handledCompletionClearTimer = null;
    _transitionHandledCompletion = false;
    if (_fadeOutHandle != null) {
      if (_fadeOutRemoveFromMixer) {
        _bassMix?.channelRemove(_fadeOutHandle!);
      }
      _bass.BASS_ChannelStop(_fadeOutHandle!);
      _bass.BASS_StreamFree(_fadeOutHandle!);
      _fadeOutHandle = null;
      _fadeOutRemoveFromMixer = false;
    }
    _cancelTransition();
    final smartPreparation = _smartPreparation;
    if (smartPreparation != null && !_smartIncomingNativeOwned) {
      _bass.BASS_StreamFree(smartPreparation.incomingHandle);
    }
    _smartPreparation = null;
    _smartIncomingNativeOwned = false;
    final smartOutgoing = _smartOutgoingStream;
    _smartOutgoingStream = null;
    _activeSmartTransitionId = null;
    if (smartOutgoing != null && smartOutgoing != _fstream) {
      _bass.BASS_StreamFree(smartOutgoing);
    }
    _lingeringPath = null;
    _smartOutgoingPath = null;

    if (_fstream == null) {
      _publishAudioFiles();
      return;
    }

    _stopWasapiOutputIfNeeded();
    _removeAudioEffects();
    _removeEQ();

    if (_mixerStream != null) {
      _dropGaplessMixer();
      _fPath = null;
      _cachedLengthSeconds = null;
      _streamWasapiExclusive = false;
      _eqHandles.clear();
      _publishAudioFiles();
      return;
    }

    if (_bass.BASS_StreamFree(_fstream!) == 0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_HANDLE:
          log.bass.warn('legacy', 'StreamFree is called on a invalid handle.');
          break;
        case bass.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
            'Device streams (STREAMPROC_DEVICE) cannot be freed.',
          );
      }
    }
    _fstream = null;
    _fPath = null;
    _cachedLengthSeconds = null;
    _streamWasapiExclusive = false;
    _eqHandles.clear();
    _publishAudioFiles();
  }

  /// Frees all resources used by the output device,
  /// including all its samples, streams and MOD musics.
  ///
  /// Also free the bass.dll.
  void free() {
    if (_freed) return;
    _freed = true;
    _cancelPendingPause();
    _cancelOutputGainFade(keepTarget: true);
    _fadeInTimer?.cancel();
    _fadeInTimer = null;
    _cancelEqSmoothing();
    _fadeOutTimer?.cancel();
    _fadeOutTimer = null;
    if (_fadeOutHandle != null) {
      if (_fadeOutRemoveFromMixer) {
        _bassMix?.channelRemove(_fadeOutHandle!);
      }
      _bass.BASS_ChannelStop(_fadeOutHandle!);
      _bass.BASS_StreamFree(_fadeOutHandle!);
      _fadeOutHandle = null;
      _fadeOutRemoveFromMixer = false;
    }
    _positionUpdaterVersion++;
    _positionUpdater?.cancel();
    _positionUpdater = null;
    final smartPreparation = _smartPreparation;
    if (smartPreparation != null && !_smartIncomingNativeOwned) {
      _bass.BASS_StreamFree(smartPreparation.incomingHandle);
    }
    _smartPreparation = null;
    _smartIncomingNativeOwned = false;
    final smartOutgoing = _smartOutgoingStream;
    _smartOutgoingStream = null;
    _activeSmartTransitionId = null;
    if (smartOutgoing != null && smartOutgoing != _fstream) {
      _bass.BASS_StreamFree(smartOutgoing);
    }

    // 如果当前是独占模式，需要先清理 WASAPI
    _stopWasapiOutputIfNeeded();
    _removeAudioEffects();
    if (_mixerStream != null) {
      _removeEQ();
      _dropGaplessMixer();
    }
    wasapiExclusive = false;
    _streamWasapiExclusive = false;
    _fstream = null;
    _fPath = null;
    _cachedLengthSeconds = null;
    _lingeringPath = null;
    _smartOutgoingPath = null;
    _queuedPath = null;
    _publishAudioFiles();

    _releaseMidiFontPointer();
    _midiFontPath = null;
    _hasMidiSoundfont = false;

    if (_bass.BASS_Free() == 0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_INIT:
          log.bass.warn(
            'legacy',
            'BASS_Free is called before BASS_Init complete normally.',
          );
          break;
        case bass.BASS_ERROR_BUSY:
          throw const FormatException(
            'The device is currently being reinitialized.',
          );
      }
    }

    _queueSyncCallback?.close();
    _queueSyncCallback = null;
    _posSyncCallback?.close();
    _posSyncCallback = null;
    _bassMixLib?.close();
    _bassMixLib = null;
    _bassFxLib?.close();
    _bassFxLib = null;
    _bassFx = null;
    // BASS_WASAPI 可能仍有系统音频回调，进程内不卸载其 DLL。
    _bassLib.close();
    _playerStateStreamController.close();
    _positionStreamController.close();
    _spectrumStreamController.close();
    _spectrumDisplayStreamController.close();
    _gaplessTransitionStreamController.close();
    if (_fftBuffer != null) {
      malloc.free(_fftBuffer!);
      _fftBuffer = null;
    }
    if (_wasapiFftBuffer != null) {
      malloc.free(_wasapiFftBuffer!);
      _wasapiFftBuffer = null;
    }
    if (_freqAttrPtr != null) {
      malloc.free(_freqAttrPtr!);
      _freqAttrPtr = null;
    }
  }
}
