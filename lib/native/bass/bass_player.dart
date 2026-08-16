// ignore_for_file: constant_identifier_names

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/native/bass/bass.dart' as bass;
import 'package:pure_music/native/bass/bass_fx.dart';
import 'package:pure_music/native/bass/bass_mix.dart';
import 'package:pure_music/native/bass/bass_wasapi.dart' as bass_wasapi;
import 'package:pure_music/core/utils.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

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

class BassPlayer {
  late final ffi.DynamicLibrary _bassLib;
  late final ffi.DynamicLibrary _bassWasapiLib;
  late final bass.Bass _bass;
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

  double? _replayGainDb;
  double _baseOutputVolume = 1.0;

  double? get replayGainDb => _replayGainDb;

  set replayGainDb(double? value) {
    _replayGainDb = value;
    _applyPlaybackGains();
  }

  // Equalizer
  final List<int> _eqHandles = [];
  int _bfxEqHandle = 0;
  final List<double> _eqGains = List.filled(10, 0.0);
  List<double> get eqGains => List.unmodifiable(_eqGains);
  static const _eqCenters = [
    80.0,
    100.0,
    125.0,
    250.0,
    500.0,
    1000.0,
    2000.0,
    4000.0,
    8000.0,
    16000.0,
  ];

  double _calculateBandwidth(double centerFreq) {
    const minFreq = 80.0;
    const maxFreq = 16000.0;
    const minBandwidth = 8.0;
    const maxBandwidth = 28.0;

    final clampedFreq = centerFreq.clamp(minFreq, maxFreq);
    final factor = (clampedFreq - minFreq) / (maxFreq - minFreq);
    final bandwidth = maxBandwidth + (minBandwidth - maxBandwidth) * factor;

    return bandwidth.clamp(1.0, 36.0);
  }

  double _rate = 1.0;
  double _pitch = 0.0;

  double get rate => _rate;

  bool get _isEqFlat => _eqGains.every((g) => g.abs() < 1e-6);

  /// 是否启用 wasapi 独占模式
  bool wasapiExclusive = false;
  String _wasapiOutputInfo = 'off';

  Timer? _fadeInTimer;

  /// 淡出旧流时延迟释放资源的定时器
  Timer? _fadeOutTimer;
  int? _fadeOutHandle;
  bool _fadeOutRemoveFromMixer = false;

  /// 自动切歌过渡（淡入淡出/交叉淡化）状态
  Timer? _transitionTimer;
  int? _transitionOldStream;
  int? _transitionSyncHandle;
  int? _transitionSyncChannel;
  int _transitionGeneration = 0;

  /// 独占模式状态变化回调
  Function(bool)? onExclusiveModeChanged;

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
  late final StreamController<double> _positionStreamController;
  late final StreamController<Float32List> _spectrumStreamController;
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

  int get sourceGeneration => _mixerGeneration;

  bool get hasGaplessMixer => _mixerStream != null;

  Stream<GaplessTransition> get gaplessTransitionStream =>
      _gaplessTransitionStreamController.stream;

  void _logAudioState(String tag) {
    final wasapiStarted = _bassWasapi.BASS_WASAPI_IsStarted() == bass.TRUE;
    final eqCount =
        (_bfxEqHandle != 0 ? 1 : 0) + _eqHandles.where((e) => e != 0).length;
    logger.i(
      '[bass] $tag | exclusive=$wasapiExclusive streamExclusive=$_streamWasapiExclusive '
      'wasapiStarted=$wasapiStarted handle=$_fstream mixer=$_mixerStream queued=$_queuedStream '
      'smart=${_smartPreparation?.transitionId ?? _activeSmartTransitionId} '
      'eq=$eqCount eqFlat=${_isEqFlat ? 1 : 0} '
      'rate=$_rate pitch=$_pitch wasapi=$_wasapiOutputInfo',
    );
  }

  String get debugStateLine {
    final wasapiStarted = _bassWasapi.BASS_WASAPI_IsStarted() == bass.TRUE;
    final eqCount =
        (_bfxEqHandle != 0 ? 1 : 0) + _eqHandles.where((e) => e != 0).length;
    return 'exclusive=$wasapiExclusive streamExclusive=$_streamWasapiExclusive '
        'wasapiStarted=$wasapiStarted handle=$_fstream mixer=$_mixerStream queued=$_queuedStream '
        'smart=${_smartPreparation?.transitionId ?? _activeSmartTransitionId} '
        'eq=$eqCount eqFlat=${_isEqFlat ? 1 : 0} '
        'rate=$_rate pitch=$_pitch wasapi=$_wasapiOutputInfo';
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

  Stream<PlayerState> get playerStateStream =>
      _playerStateStreamController.stream;

  static const int _bassDataFft512 = 0x80000001;
  int Function(int, ffi.Pointer<ffi.Void>, int)? _bassChannelGetData;
  ffi.Pointer<ffi.Float>? _fftBuffer;
  ffi.Pointer<ffi.Float>? _wasapiFftBuffer;
  double? _cachedLengthSeconds;
  double _streamSampleRate = 44100.0;
  int _lastSpectrumUpdateUs = 0;
  final Stopwatch _spectrumClock = Stopwatch()..start();
  Duration _spectrumTickPeriod = const Duration(milliseconds: 16);
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
      if (currentState == PlayerState.stopped) {
        if (lastNotifiedState != PlayerState.completed) {
          lastNotifiedState = PlayerState.completed;
          _playerStateStreamController.add(PlayerState.completed);
        }
      } else {
        if (lastNotifiedState != currentState) {
          lastNotifiedState = currentState;
          _playerStateStreamController.add(currentState);
        }
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
    if (_positionStreamController.hasListener) {
      return _computePlayingTickPeriod();
    }
    if (_spectrumStreamController.hasListener) {
      return _computeSpectrumTickPeriod();
    }
    return _computeIdleTickPeriod();
  }

  void _startPositionUpdater() {
    if (_fstream == null) return;
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
    final freqPtr = malloc.allocate<ffi.Float>(ffi.sizeOf<ffi.Float>());
    try {
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
    } finally {
      malloc.free(freqPtr);
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
      logger.i('[bass] wasapi output $_wasapiOutputInfo');
    } finally {
      calloc.free(info);
    }
  }

  void _maybeUpdateSpectrum({PlayerState? knownState}) {
    if (_fstream == null) return;
    if (!_spectrumStreamController.hasListener) return;
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
    if (!_spectrumStreamController.hasListener) return;
    final getData = _bassChannelGetData;
    if (getData == null) return;

    _fftBuffer ??= malloc.allocate<ffi.Float>(256 * ffi.sizeOf<ffi.Float>());
    final bytesRead = getData(
      handle,
      _fftBuffer!.cast<ffi.Void>(),
      _bassDataFft512,
    );
    if (bytesRead <= 0) return;

    final fft = _fftBuffer!.asTypedList(256);
    _computeSpectrum8Into(fft, _streamSampleRate, _spectrumBands);
    _emitSmoothedSpectrum();
  }

  void _emitWasapiSpectrumFrame() {
    if (!_spectrumStreamController.hasListener) return;

    _wasapiFftBuffer ??= malloc.allocate<ffi.Float>(
      256 * ffi.sizeOf<ffi.Float>(),
    );
    final bytesRead = _bassWasapi.BASS_WASAPI_GetData(
      _wasapiFftBuffer!.cast<ffi.Void>(),
      bass_wasapi.BASS_DATA_FFT512,
    );
    // BASS_WASAPI_GetData returns the number of bytes written; negative means error
    if (bytesRead <= 0) return;

    final fft = _wasapiFftBuffer!.asTypedList(256);
    _computeSpectrum8Into(fft, _streamSampleRate, _spectrumBands);
    _emitSmoothedSpectrum();
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

  void _resetSpectrumSmoothing() {
    _spectrumBands.fillRange(0, _spectrumBands.length, 0.0);
    _spectrumSmoothed.fillRange(0, _spectrumSmoothed.length, 0.0);
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

  void setEQ(int band, double gain) {
    if (band < 0 || band >= 10) return;
    final wasFlat = _isEqFlat;
    _eqGains[band] = gain;
    if (_fstream == null) return;

    if (wasapiExclusive) {
      if (!_isEqFlat) {
        logger.w('[bass] EQ enabled in exclusive mode, keep shared mode');
        useExclusiveMode(false);
      }
      return;
    }

    if (_isEqFlat) {
      if (!wasFlat) {
        _removeEQ();
      }
      return;
    }

    if (_eqHandles.isEmpty && _bfxEqHandle == 0) {
      _initEQ();
    }

    _updateEQ(band);
  }

  void refreshEQ() {
    if (_fstream == null) return;
    if (wasapiExclusive || _isEqFlat) {
      _removeEQ();
      return;
    }
    if (_eqHandles.isEmpty && _bfxEqHandle == 0) {
      _initEQ();
    } else {
      for (int i = 0; i < 10; i++) {
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
        0,
      );
      if (_bfxEqHandle != 0) {
        for (int i = 0; i < 10; i++) {
          _updateEQ(i);
        }
        return;
      }
      logger.w('Failed to set BFX EQ: BASS Error ${_bass.BASS_ErrorGetCode()}');
      _bfxEqHandle = 0;
      return;
    }

    _eqHandles
      ..clear()
      ..addAll(List.filled(10, 0));

    try {
      for (int i = 0; i < 10; i++) {
        final fx = _bass.BASS_ChannelSetFX(
          channel,
          bass.BASS_FX_DX8_PARAMEQ,
          0,
        );

        if (fx == 0) {
          final err = _bass.BASS_ErrorGetCode();
          logger.w('Failed to set EQ band $i: BASS Error $err');
          continue;
        }

        _eqHandles[i] = fx;
        _updateEQ(i);
      }
    } catch (e) {
      logger.e('Error initializing EQ: $e');
    }
  }

  void _updateEQ(int band) {
    if (band < 0 || band >= 10) return;

    if (_bfxEqHandle != 0) {
      try {
        final params = calloc<bass.BASS_BFX_PEAKEQ>();
        final center = _eqCenters[band];
        final bandwidth = (_calculateBandwidth(center) / 12.0).clamp(0.1, 10.0);
        final gain = _eqGains[band];

        params.ref.lBand = band;
        params.ref.fCenter = center;
        params.ref.fBandwidth = bandwidth;
        params.ref.fQ = 0.0;
        params.ref.fGain = gain;
        params.ref.lChannel = bass.BASS_BFX_CHANALL;

        final result = _bass.BASS_FXSetParameters(_bfxEqHandle, params.cast());

        logger.i(
          'EQ Update (BFX) - Band: $band, Freq: $center Hz, Gain: $gain dB, Bandwidth: $bandwidth, Result: $result',
        );

        if (result == 0) {
          final err = _bass.BASS_ErrorGetCode();
          logger.w(
            'Failed to set BFX EQ parameters for band $band: Error $err',
          );
        }

        calloc.free(params);
      } catch (e) {
        logger.e('Error updating BFX EQ band $band: $e');
      }
      return;
    }

    if (band >= _eqHandles.length) return;

    final fx = _eqHandles[band];
    if (fx == 0) return;

    try {
      final params = calloc<bass.BASS_DX8_PARAMEQ>();
      final center = _eqCenters[band];
      final bandwidth = _calculateBandwidth(center);
      final gain = _eqGains[band];

      params.ref.fCenter = center;
      params.ref.fBandwidth = bandwidth;
      params.ref.fGain = gain;

      final result = _bass.BASS_FXSetParameters(fx, params.cast());

      logger.i(
        'EQ Update (DX8) - Band: $band, Freq: $center Hz, Gain: $gain dB, Bandwidth: $bandwidth, Result: $result',
      );

      if (result == 0) {
        final err = _bass.BASS_ErrorGetCode();
        logger.w('Failed to set EQ parameters for band $band: Error $err');
      }
      calloc.free(params);
    } catch (e) {
      logger.e('Error updating EQ band $band: $e');
    }
  }

  void _removeEQ() {
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

  void _resetBassHandles() {
    _fadeInTimer?.cancel();
    _fadeInTimer = null;
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
  }

  void _bassInit({bool resetHandles = true}) {
    // 先释放旧设备，确保可以使用 -1 (默认设备) 重新初始化
    _bass.BASS_Free();
    if (resetHandles) _resetBassHandles();

    if (_bass.BASS_Init(-1, 44100, 0, ffi.nullptr, ffi.nullptr) == 0) {
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

    _bass.BASS_SetConfig(bass.BASS_CONFIG_BUFFER, 500);
    _bass.BASS_SetConfig(bass.BASS_CONFIG_DEV_BUFFER, 500);
    if (_bass.BASS_SetConfig(bass.BASS_CONFIG_ASYNCFILE_BUFFER, 1024 * 1024) ==
        bass.FALSE) {
      logger.w('[bass] failed to set async file buffer to 1MB');
    } else {
      logger.i('[bass] async file buffer=1MB');
    }
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
          logger.w('[bass] SetDllDirectoryW failed, falling back to PATH');
        }
      } catch (e) {
        logger.w('[bass] SetDllDirectoryW exception: $e');
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
            logger.i('[bass] Added BASS dir to PATH as fallback');
          }
        } catch (e) {
          logger.w('[bass] Failed to update PATH: $e');
        }
      }
    }

    // ─── 3. 加载 bass.dll（核心） ───────────────────────────────────────────
    ffi.DynamicLibrary bassLib;
    try {
      bassLib = ffi.DynamicLibrary.open(path.join(_bassDir, 'bass.dll'));
    } catch (e) {
      logger.e('[bass] FATAL: Cannot load bass.dll from $_bassDir: $e');
      rethrow;
    }
    _bassLib = bassLib;
    _bass = bass.Bass(bassLib);
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
      _bassWasapiLib = wasapiLib;
      _bassWasapi = bass_wasapi.BassWasapi(wasapiLib);
    } catch (e) {
      logger.e('[bass] FATAL: Cannot load basswasapi.dll: $e');
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
          logger.w(
            '[bass] Plugin load failed: $pluginFullPath (error $errCode)',
          );
        } else {
          logger.i('[bass] Plugin loaded: $name');
        }
        malloc.free(pluginPathP);
      }
    }

    // ─── 6. BASS 初始化 ─────────────────────────────────────────────────────
    try {
      _bassInit(resetHandles: false);
    } catch (err) {
      logger.e('[bass] Init failed: $err');
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
      logger.i('BASS_FX loaded (version: ${version.toRadixString(16)})');
    } catch (e) {
      bassFxLib?.close();
      _bassFxLib = null;
      _bassFx = null;
      logger.w('BASS_FX not available: $e; tempo/pitch control disabled');
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
      logger.i('BASSmix loaded (version: ${version.toRadixString(16)})');
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
      logger.w('BASSmix not available: $error; gapless playback disabled');
    }
  }

  double _dbToLinear(double db) => math.pow(10.0, db / 20.0).toDouble();

  double _sourceGain(double? gainDb) {
    if (!AppPreference.instance.playbackPref.replayGainEnabled) return 1.0;
    return _dbToLinear(gainDb ?? 0.0).clamp(0.0, 8.0).toDouble();
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
        _baseOutputVolume * _sourceGain(_replayGainDb),
      );
      return;
    }
    _bass.BASS_ChannelSetAttribute(
      _mixerStream!,
      bass.BASS_ATTRIB_VOLDSP,
      _baseOutputVolume,
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
    final pathPointer = audioPath.toNativeUtf16() as ffi.Pointer<ffi.Void>;
    var handle = _bass.BASS_StreamCreateFile(
      bass.FALSE,
      pathPointer,
      0,
      0,
      flags,
    );
    malloc.free(pathPointer);
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
    const playableFlags =
        bass.BASS_UNICODE | bass.BASS_SAMPLE_FLOAT | bass.BASS_ASYNCFILE;

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
          logger.w('[bass] direct tempo stream unavailable: $error');
        }
        _bass.BASS_StreamFree(source);
      }
    }

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
      logger.w('[bass] mixer creation failed; using direct shared output');
    }
    final direct = _createDirectSharedStream(audioPath);
    if (direct != 0) {
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
      logger.i(
        '[bass] transition mode will apply after the next source rebuild',
      );
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
      return true;
    } catch (error, trace) {
      logger.w(
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
  }

  GaplessTransition? adoptSmartTransition(int transitionId) {
    final preparation = _smartPreparation;
    if (preparation == null || preparation.transitionId != transitionId) {
      return null;
    }
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
  }

  int? _detachGaplessMixer() {
    final mixer = _mixerStream;
    if (mixer == null) return null;
    final detachedQueuedStream = _queuedStreamAttached ? null : _queuedStream;
    _mixerGeneration++;
    _unreportedGaplessTransition = null;
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
    if (detachedQueuedStream != null) {
      _bass.BASS_StreamFree(detachedQueuedStream);
    }
    return mixer;
  }

  void _dropGaplessMixer() {
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
    final queued = _queuedStream;
    final queuedWasAttached = _queuedStreamAttached;
    _queuedStream = null;
    _queuedStreamAttached = false;
    _queuedPath = null;
    _queuedLengthSeconds = null;
    _queuedReplayGainDb = null;
    _queuedTransitionId = null;
    _queuedTransitionMode = null;
    if (queued == null) return null;
    if (queuedWasAttached) {
      _bassMix?.channelRemove(queued);
    } else {
      _bass.BASS_StreamFree(queued);
    }
    return null;
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
      return true;
    }
    logger.w(
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
    final leadMs = crossfade ? math.max(fadeOutMs, fadeInMs) : fadeOutMs;
    // 触发位置基于当前播放流自身的长度
    final currentLength = _bass.BASS_ChannelBytes2Seconds(
      current,
      _bass.BASS_ChannelGetLength(current, bass.BASS_POS_BYTE),
    );
    if (currentLength <= 0) return;
    final triggerPos = math.max(
      0.0,
      currentLength - math.max(1, leadMs) / 1000.0,
    );

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
      logger.w(
        '[bass] auto transition sync failed: ${_bass.BASS_ErrorGetCode()}',
      );
      return;
    }
    _transitionSyncHandle = syncHandle;
    _transitionSyncChannel = current;
    logger.i(
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
    final newStream = _queuedStream;
    if (newStream == null) return;
    _transitionTimer?.cancel();
    final pref = AppPreference.instance.playbackPref;
    final mode = _queuedTransitionMode ?? pref.transitionMode;
    logger.i('[bass] auto transition triggered: mode=${mode.name}');
    final fadeOutMs = pref.transitionFadeOutMs;
    final fadeInMs = pref.transitionFadeInMs;
    final crossfade = mode == TransitionMode.crossfade;
    final oldStream = _fstream!;
    final gen = generation;

    if (crossfade) {
      if (!_attachQueuedStream(_mixerGeneration, newStream)) return;
      _transitionOldStream = oldStream;
      _fadeOutOldStream(
        oldStream,
        durationMs: fadeOutMs,
        delayCleanup: true,
        removeFromMixer: true,
      );
      _fadeInNewStream(newStream, durationMs: fadeInMs);
      _transitionTimer = Timer(Duration(milliseconds: fadeOutMs + 50), () {
        if (gen != _transitionGeneration) return;
        _transitionTimer = null;
        _activateQueuedStream(_mixerGeneration, newStream);
      });
    } else {
      _transitionOldStream = oldStream;
      _fadeOutOldStream(
        oldStream,
        durationMs: fadeOutMs,
        delayCleanup: true,
        removeFromMixer: true,
      );
      _transitionTimer = Timer(Duration(milliseconds: fadeOutMs), () {
        if (gen != _transitionGeneration) return;
        _transitionTimer = null;
        if (!_attachQueuedStream(_mixerGeneration, newStream)) {
          _cancelTransition();
          return;
        }
        _fadeInNewStream(newStream, durationMs: fadeInMs);
        _activateQueuedStream(_mixerGeneration, newStream);
      });
    }
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
    final prevState = wasapiExclusive;
    try {
      if (exclusive && !_isEqFlat) {
        logger.w('[bass] Cannot enable exclusive mode while EQ is enabled');
        showTextOnSnackBar(
          '独占模式与均衡器冲突，请先关闭均衡器（全部归零）',
          variant: ToastVariant.error,
        );
        return false;
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
        _positionUpdaterVersion++;
        _positionUpdater?.cancel();
        _positionUpdater = null;
        _bassWasapi.BASS_WASAPI_Stop(bass.TRUE);
        _bassWasapi.BASS_WASAPI_Free();
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
      logger.e('切换独占模式失败', error: err, stackTrace: trace);
      showTextOnSnackBar('切换独占模式失败，请查看日志');
      _playerStateStreamController.add(playerState);
    }
    wasapiExclusive = _fstream != null && _streamWasapiExclusive;
    onExclusiveModeChanged?.call(wasapiExclusive);
    return false;
  }

  void _stopWasapiOutputIfNeeded() {
    if (!wasapiExclusive && !_streamWasapiExclusive) return;
    _bassWasapi.BASS_WASAPI_Stop(bass.TRUE);
    _bassWasapi.BASS_WASAPI_Free();
    _wasapiOutputInfo = 'off';
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

  int _createDecodeStream(String path) {
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
    _refreshCachedLength();
    if (seekTo > 0.0) {
      seek(seekTo);
    }
    if (!_isEqFlat) {
      refreshEQ();
    }
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
      if (_fadeOutRemoveFromMixer) {
        _bassMix?.channelRemove(_fadeOutHandle!);
      }
      _bass.BASS_ChannelStop(_fadeOutHandle!);
      _bass.BASS_StreamFree(_fadeOutHandle!);
    }
    _fadeOutHandle = handle;
    _fadeOutRemoveFromMixer = removeFromMixer;

    _fadeOutTimer = Timer(Duration(milliseconds: durationMs + 20), () {
      if (_fadeOutHandle == handle) {
        if (_fadeOutRemoveFromMixer) {
          _bassMix?.channelRemove(handle);
        }
        _bass.BASS_ChannelStop(handle);
        _bass.BASS_StreamFree(handle);
        _fadeOutHandle = null;
        _fadeOutRemoveFromMixer = false;
        _fadeOutTimer = null;
      }
    });
  }

  /// Crossfade: 淡入新流 - 从静音滑到正常播放音量（手动切歌防爆音用，固定短时长）
  void _fadeInNewStream(int handle, {int durationMs = 200}) {
    if (_bass.BASS_ChannelSetAttribute(handle, bass.BASS_ATTRIB_VOL, 0.0) ==
        bass.FALSE) {
      return;
    }
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
    _replayGainDb = null;
    _activeGaplessTransitionId = null;
    _logAudioState('setSource(begin)');
    if (_fstream != null) {
      _positionUpdaterVersion++;
      _positionUpdater?.cancel();
      _positionUpdater = null;
      _removeEQ();
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
        // 手动切歌防爆音：固定短淡出（300ms），新歌立即淡入
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
      _refreshCachedLength();

      try {
        refreshEQ();
      } catch (e) {
        logger.e('SetSource refreshEQ failed: $e');
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
  }

  /// [BASS_ATTRIB_VOLDSP] attribute does have direct effect on decoding/recording channels.
  void setVolumeDsp(double volume) {
    _baseOutputVolume = volume;
    _applyPlaybackGains();
  }

  void setRate(double rate) {
    _rate = rate;
    if (_fstream == null) return;

    // bass_fx.dll 已在构造时预加载，直接使用
    if (wasapiExclusive && _rate != 1.0) {
      logger.w('[bass] rate change in exclusive mode, fallback to shared mode');
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
          logger.w(
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
      logger.w(
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
    _bassWasapi.BASS_WASAPI_Stop(bass.TRUE);
    _bassWasapi.BASS_WASAPI_Free();

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
    int result = bass.FALSE;
    for (int attempt = 0; attempt < 3; attempt++) {
      result = _bassWasapi.BASS_WASAPI_Init(
        -1, // 默认设备
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
          _bassWasapi.BASS_WASAPI_Stop(bass.TRUE);
          _bassWasapi.BASS_WASAPI_Free();
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
      _refreshWasapiOutputInfo(bufferSec);
    }
  }

  void _startWasapiExclusive() {
    try {
      _bassWasapiInit();
    } catch (err) {
      logger.w('[bass] wasapi exclusive init failed, fallback to shared: $err');
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
    final seekPos = position;
    final sourcePath = _fPath;
    _bassWasapi.BASS_WASAPI_Stop(bass.TRUE);
    _bassWasapi.BASS_WASAPI_Free();
    _wasapiOutputInfo = 'off';
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
      _playerStateStreamController.add(playerState);
      _positionUpdater?.cancel();
      _emitPositionSnapshot();
    }
  }

  /// pause channel, call [start] to resume channel
  ///
  /// do nothing if [setSource] hasn't been called
  void pause() {
    if (_fstream == null) return;

    if (wasapiExclusive) {
      _logAudioState('pause(wasapi)');
      return _pauseWasapiExclusive();
    }
    _logAudioState('pause(normal)');

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
          throw const FormatException('The channel is not playing.');
      }
    }

    _playerStateStreamController.add(playerState);
    _positionUpdater?.cancel();
    _emitPositionSnapshot();
    _logAudioState('pause(done)');
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
    _fadeInTimer?.cancel();
    _fadeInTimer = null;
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

    if (_fstream == null) return;

    _stopWasapiOutputIfNeeded();

    if (_mixerStream != null) {
      _removeEQ();
      _dropGaplessMixer();
      _fPath = null;
      _cachedLengthSeconds = null;
      _streamWasapiExclusive = false;
      _eqHandles.clear();
      return;
    }

    if (_bass.BASS_StreamFree(_fstream!) == 0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_HANDLE:
          logger.w('StreamFree is called on a invalid handle.');
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
  }

  /// Frees all resources used by the output device,
  /// including all its samples, streams and MOD musics.
  ///
  /// Also free the bass.dll.
  void free() {
    _fadeInTimer?.cancel();
    _fadeInTimer = null;
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
    if (_mixerStream != null) {
      _removeEQ();
      _dropGaplessMixer();
    }
    wasapiExclusive = false;
    _streamWasapiExclusive = false;
    _fstream = null;
    _fPath = null;
    _cachedLengthSeconds = null;

    if (_bass.BASS_Free() == 0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_INIT:
          logger.w('BASS_Free is called before BASS_Init complete normally.');
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
    _bassWasapiLib.close();
    _bassLib.close();
    _playerStateStreamController.close();
    _positionStreamController.close();
    _spectrumStreamController.close();
    _gaplessTransitionStreamController.close();
    if (_fftBuffer != null) {
      malloc.free(_fftBuffer!);
      _fftBuffer = null;
    }
    if (_wasapiFftBuffer != null) {
      malloc.free(_wasapiFftBuffer!);
      _wasapiFftBuffer = null;
    }
  }
}
