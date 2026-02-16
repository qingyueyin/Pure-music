// ignore_for_file: constant_identifier_names

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pure_music/app_preference.dart';
import 'package:pure_music/src/bass/bass.dart' as bass;
import 'package:pure_music/src/bass/bass_fx.dart';
import 'package:pure_music/src/bass/bass_wasapi.dart' as bass_wasapi;
import 'package:pure_music/utils.dart';
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

class BassPlayer {
  late final ffi.DynamicLibrary _bassLib;
  late final ffi.DynamicLibrary _bassWasapiLib;
  late final bass.Bass _bass;
  late final bass_wasapi.BassWasapi _bassWasapi;
  BassFx? _bassFx;
  bool get isBassFxLoaded => _bassFx != null;

  late final String _bassDir;

  String? _fPath;
  int? _fstream;
  bool _streamWasapiExclusive = false;

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
    16000.0
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
  bool get _eqBypass => AppPreference.instance.playbackPref.eqBypass;

  /// 是否启用 wasapi 独占模式
  bool wasapiExclusive = false;

  /// 独占模式状态变化回调
  Function(bool)? onExclusiveModeChanged;

  Timer? _positionUpdater;
  final _positionStreamController = StreamController<double>.broadcast();
  final _spectrumStreamController = StreamController<Float32List>.broadcast();
  final _playerStateStreamController =
      StreamController<PlayerState>.broadcast();

  void _logAudioState(String tag) {
    final wasapiStarted = _bassWasapi.BASS_WASAPI_IsStarted() == bass.TRUE;
    final eqCount =
        (_bfxEqHandle != 0 ? 1 : 0) + _eqHandles.where((e) => e != 0).length;
    LOGGER.d(
      "[bass] $tag | exclusive=$wasapiExclusive streamExclusive=$_streamWasapiExclusive "
      "wasapiStarted=$wasapiStarted handle=$_fstream eq=$eqCount eqFlat=${_isEqFlat ? 1 : 0} "
      "rate=$_rate pitch=$_pitch",
    );
  }

  String get debugStateLine {
    final wasapiStarted = _bassWasapi.BASS_WASAPI_IsStarted() == bass.TRUE;
    final eqCount =
        (_bfxEqHandle != 0 ? 1 : 0) + _eqHandles.where((e) => e != 0).length;
    return "exclusive=$wasapiExclusive streamExclusive=$_streamWasapiExclusive "
        "wasapiStarted=$wasapiStarted handle=$_fstream eq=$eqCount eqFlat=${_isEqFlat ? 1 : 0} "
        "rate=$_rate pitch=$_pitch";
  }

  /// audio's length in seconds
  double get length {
    if (_fstream == null) return 1.0;
    final len = _bass.BASS_ChannelBytes2Seconds(
      _fstream!,
      _bass.BASS_ChannelGetLength(_fstream!, bass.BASS_POS_BYTE),
    );
    return len > 0 ? len : 1.0;
  }

  /// current position in seconds
  double get position => _fstream == null
      ? 0.0
      : _bass.BASS_ChannelBytes2Seconds(
          _fstream!,
          _bass.BASS_ChannelGetPosition(_fstream!, bass.BASS_POS_BYTE),
        );

  PlayerState get playerState {
    if (_fstream == null) {
      return PlayerState.unknown;
    }

    switch (_bass.BASS_ChannelIsActive(_fstream!)) {
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
    if (_fstream == null) return 0;

    final volDsp = malloc.allocate<ffi.Float>(ffi.sizeOf<ffi.Float>());
    _bass.BASS_ChannelGetAttribute(_fstream!, bass.BASS_ATTRIB_VOLDSP, volDsp);
    return volDsp.value;
  }

  /// update every 33ms
  Stream<double> get positionStream => _positionStreamController.stream;

  Stream<Float32List> get spectrumStream => _spectrumStreamController.stream;

  Stream<PlayerState> get playerStateStream =>
      _playerStateStreamController.stream;

  static const int _bassDataFft2048 = 0x80000003;
  int Function(int, ffi.Pointer<ffi.Void>, int)? _bassChannelGetData;
  ffi.Pointer<ffi.Float>? _fftBuffer;
  double _streamSampleRate = 44100.0;
  int _lastSpectrumUpdateUs = 0;
  Duration _spectrumTickPeriod = const Duration(milliseconds: 16);
  SpectrumUpdateMode spectrumUpdateMode = SpectrumUpdateMode.auto;
  final Float32List _spectrumSmoothed = Float32List(8);

  void setSpectrumUpdateMode(SpectrumUpdateMode mode) {
    spectrumUpdateMode = mode;
    _spectrumTickPeriod = _computeSpectrumTickPeriod();
    _lastSpectrumUpdateUs = 0;
  }

  double _getDisplayRefreshRate() {
    double refreshRate = 60.0;
    try {
      final views = ui.PlatformDispatcher.instance.views;
      if (views.isNotEmpty) {
        final r = views.first.display.refreshRate;
        if (r.isFinite && r > 0) refreshRate = r;
      }
    } catch (_) {}
    return refreshRate;
  }

  Timer _getPositionUpdater(Duration period) {
    return Timer.periodic(period, (timer) {
      _positionStreamController.add(position);
      _maybeUpdateSpectrum();

      /// check if the channel has completed
      if (playerState == PlayerState.stopped) {
        _playerStateStreamController.add(PlayerState.completed);
      }
    });
  }

  Duration _computePlayingTickPeriod() {
    final refreshRate = _getDisplayRefreshRate();
    final ms = (1000.0 / refreshRate).round().clamp(8, 33);
    return Duration(milliseconds: ms);
  }

  Duration _computeSpectrumTickPeriod() {
    final displayHz = _getDisplayRefreshRate();
    final targetHz = switch (spectrumUpdateMode) {
      SpectrumUpdateMode.hz60 => 60.0,
      SpectrumUpdateMode.hz90 => 90.0,
      SpectrumUpdateMode.hz120 => 120.0,
      SpectrumUpdateMode.auto =>
        displayHz >= 110.0 ? 120.0 : (displayHz >= 80.0 ? 90.0 : 60.0),
    };
    final ms = (1000.0 / targetHz).round().clamp(8, 33);
    return Duration(milliseconds: ms);
  }

  void _refreshStreamSampleRate() {
    if (_fstream == null) return;
    final freqPtr = malloc.allocate<ffi.Float>(ffi.sizeOf<ffi.Float>());
    try {
      final ok =
          _bass.BASS_ChannelGetAttribute(_fstream!, bass.BASS_ATTRIB_FREQ, freqPtr);
      if (ok != 0 && freqPtr.value.isFinite && freqPtr.value > 1.0) {
        _streamSampleRate = freqPtr.value.toDouble();
      }
    } finally {
      malloc.free(freqPtr);
    }
  }

  void _maybeUpdateSpectrum() {
    if (_fstream == null) return;
    if (_bassChannelGetData == null) return;
    if (playerState != PlayerState.playing) return;

    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final intervalUs = _spectrumTickPeriod.inMicroseconds;
    if (nowUs - _lastSpectrumUpdateUs < intervalUs) return;
    _lastSpectrumUpdateUs = nowUs;
    _emitSpectrumFrame();
  }

  void _emitSpectrumFrame() {
    final handle = _fstream;
    if (handle == null) return;
    final getData = _bassChannelGetData;
    if (getData == null) return;

    _fftBuffer ??= malloc.allocate<ffi.Float>(1024 * ffi.sizeOf<ffi.Float>());
    final bytesRead = getData(handle, _fftBuffer!.cast<ffi.Void>(), _bassDataFft2048);
    if (bytesRead <= 0) return;

    final fft = _fftBuffer!.asTypedList(1024);
    final bands = _computeSpectrum8(fft, _streamSampleRate);
    final out = Float32List(8);
    for (int i = 0; i < 8; i++) {
      final target = bands[i];
      final prev = _spectrumSmoothed[i];
      final a = target > prev ? 0.35 : 0.18;
      final next = (prev + (target - prev) * a).clamp(0.0, 1.0).toDouble();
      _spectrumSmoothed[i] = next;
      out[i] = next;
    }
    _spectrumStreamController.add(out);
  }

  Float32List _computeSpectrum8(Float32List fft, double sampleRate) {
    const fftSize = 2048.0;
    const minF = 45.0;
    const maxF = 16000.0;
    const bands = 8;

    final out = Float32List(bands);
    final nyquist = sampleRate * 0.5;
    final clampedMaxF = math.min(maxF, nyquist - 1.0);
    if (clampedMaxF <= minF || nyquist <= 1.0) return out;

    for (int i = 0; i < bands; i++) {
      final a = i / bands;
      final b = (i + 1) / bands;
      final fa = minF * math.pow(clampedMaxF / minF, a).toDouble();
      final fb = minF * math.pow(clampedMaxF / minF, b).toDouble();
      final ia = ((fa / sampleRate) * fftSize).floor().clamp(1, 1023).toInt();
      final ib = ((fb / sampleRate) * fftSize)
          .ceil()
          .clamp(ia + 1, 1023)
          .toInt();

      double m = 0.0;
      for (int k = ia; k < ib; k++) {
        final v = fft[k];
        if (v.isFinite && v > m) m = v.toDouble();
      }
      final scaled = (math.log(1.0 + m * 18.0) / math.log(19.0))
          .clamp(0.0, 1.0)
          .toDouble();
      out[i] = scaled;
    }
    return out;
  }

  void setEQ(int band, double gain) {
    if (band < 0 || band >= 10) return;
    final wasFlat = _isEqFlat;
    _eqGains[band] = gain;
    if (_fstream == null) return;

    if (wasapiExclusive) {
      if (!_isEqFlat) {
        LOGGER.w("[bass] EQ enabled in exclusive mode, keep shared mode");
        useExclusiveMode(false);
      }
      return;
    }

    if (_eqBypass) {
      _removeEQ();
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
    if (wasapiExclusive || _eqBypass || _isEqFlat) {
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
    if (_fstream == null) return;

    if (_bassFx != null) {
      _bfxEqHandle =
          _bass.BASS_ChannelSetFX(_fstream!, bass.BASS_FX_BFX_PEAKEQ, 0);
      if (_bfxEqHandle != 0) {
        for (int i = 0; i < 10; i++) {
          _updateEQ(i);
        }
        return;
      }
      LOGGER.w(
        "Failed to set BFX EQ: BASS Error ${_bass.BASS_ErrorGetCode()}",
      );
      _bfxEqHandle = 0;
      return;
    }

    _eqHandles
      ..clear()
      ..addAll(List.filled(10, 0));

    try {
      for (int i = 0; i < 10; i++) {
        final fx =
            _bass.BASS_ChannelSetFX(_fstream!, bass.BASS_FX_DX8_PARAMEQ, 0);

        if (fx == 0) {
          final err = _bass.BASS_ErrorGetCode();
          LOGGER.w("Failed to set EQ band $i: BASS Error $err");
          continue;
        }

        _eqHandles[i] = fx;
        _updateEQ(i);
      }
    } catch (e) {
      LOGGER.e("Error initializing EQ: $e");
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

        LOGGER.i(
          "EQ Update (BFX) - Band: $band, Freq: $center Hz, Gain: $gain dB, Bandwidth: $bandwidth, Result: $result",
        );

        if (result == 0) {
          final err = _bass.BASS_ErrorGetCode();
          LOGGER
              .w("Failed to set BFX EQ parameters for band $band: Error $err");
        }

        calloc.free(params);
      } catch (e) {
        LOGGER.e("Error updating BFX EQ band $band: $e");
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

      LOGGER.i(
        "EQ Update (DX8) - Band: $band, Freq: $center Hz, Gain: $gain dB, Bandwidth: $bandwidth, Result: $result",
      );

      if (result == 0) {
        final err = _bass.BASS_ErrorGetCode();
        LOGGER.w("Failed to set EQ parameters for band $band: Error $err");
      }
      calloc.free(params);
    } catch (e) {
      LOGGER.e("Error updating EQ band $band: $e");
    }
  }

  void _removeEQ() {
    if (_fstream == null) return;
    if (_bfxEqHandle != 0) {
      _bass.BASS_ChannelRemoveFX(_fstream!, _bfxEqHandle);
      _bfxEqHandle = 0;
    }
    for (final fx in _eqHandles) {
      if (fx == 0) continue;
      _bass.BASS_ChannelRemoveFX(_fstream!, fx);
    }
    _eqHandles.clear();
  }

  void _bassInit() {
    // 先释放旧设备，确保可以使用 -1 (默认设备) 重新初始化
    _bass.BASS_Free();

    if (_bass.BASS_Init(
          -1,
          44100,
          0,
          ffi.nullptr,
          ffi.nullptr,
        ) ==
        0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_DEVICE:
          throw const FormatException("device is invalid.");
        case bass.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
            "The BASS_DEVICE_REINIT flag cannot be used when device is -1. Use the real device number instead.",
          );
        case bass.BASS_ERROR_ALREADY:
          throw const FormatException(
            "The device has already been initialized. The BASS_DEVICE_REINIT flag can be used to request reinitialization.",
          );
        case bass.BASS_ERROR_ILLPARAM:
          throw const FormatException("win is not a valid window handle.");
        case bass.BASS_ERROR_DRIVER:
          throw const FormatException("There is no available device driver.");
        case bass.BASS_ERROR_BUSY:
          throw const FormatException(
            "Something else has exclusive use of the device.",
          );
        case bass.BASS_ERROR_FORMAT:
          throw const FormatException(
            "The specified format is not supported by the device. Try changing the freq parameter.",
          );
        case bass.BASS_ERROR_MEM:
          throw const FormatException("There is insufficient memory.");
        case bass.BASS_ERROR_UNKNOWN:
          throw const FormatException(
            "Some other mystery problem! Maybe Something else has exclusive use of the device.",
          );
      }
    }
  }

  void _startDevice() {
    if (_bass.BASS_Start() == bass.FALSE) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_INIT:
          _bassInit();
          _startDevice();
          break;
        case bass.BASS_ERROR_BUSY:
          throw const FormatException(
            "The app's audio has been interrupted and cannot be resumed yet. (iOS only)",
          );
        case bass.BASS_ERROR_REINIT:
          throw const FormatException(
            "The device is currently being reinitialized or needs to be.",
          );
        case bass.BASS_ERROR_UNKNOWN:
          throw const FormatException(
            "Some other mystery problem! Maybe Something else has exclusive use of the device.",
          );
      }
    }
  }

  /// load bass.dll from the exe's path\\dll\\BASS
  /// ensure that there's bass.dll at path of .exe\\dll\\BASS
  /// leave the device's output freq as it is
  BassPlayer() {
    final exeBassDir =
        path.join(path.dirname(Platform.resolvedExecutable), "dll", "BASS");
    final cwdBassDir = path.join(Directory.current.path, "dll", "BASS");
    final exeBassDll = File(path.join(exeBassDir, "bass.dll"));
    final cwdBassDll = File(path.join(cwdBassDir, "bass.dll"));
    _bassDir = exeBassDll.existsSync()
        ? exeBassDir
        : (cwdBassDll.existsSync() ? cwdBassDir : exeBassDir);

    if (Platform.isWindows) {
      try {
        final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
        final setDllDirectory = kernel32.lookupFunction<
            ffi.Int32 Function(ffi.Pointer<Utf16>),
            int Function(ffi.Pointer<Utf16>)>('SetDllDirectoryW');
        final bassDir = _bassDir.toNativeUtf16();
        setDllDirectory(bassDir);
        malloc.free(bassDir);
      } catch (e) {
        LOGGER.e("Failed to SetDllDirectory: $e");
      }
    }

    final bassLibPath = path.join(_bassDir, "bass.dll");
    _bassLib = ffi.DynamicLibrary.open(bassLibPath);
    _bass = bass.Bass(_bassLib);
    try {
      _bassChannelGetData = _bassLib.lookupFunction<
          ffi.UnsignedLong Function(
            ffi.UnsignedLong,
            ffi.Pointer<ffi.Void>,
            ffi.UnsignedLong,
          ),
          int Function(int, ffi.Pointer<ffi.Void>, int)>('BASS_ChannelGetData');
    } catch (_) {
      _bassChannelGetData = null;
    }

    final bassWasapiLibPath = path.join(_bassDir, "basswasapi.dll");
    _bassWasapiLib = ffi.DynamicLibrary.open(bassWasapiLibPath);
    _bassWasapi = bass_wasapi.BassWasapi(_bassWasapiLib);

    final coreDlls = {
      "bass.dll",
      "basswasapi.dll",
      "bass_fx.dll",
    };
    final entries = Directory(_bassDir).listSync(followLinks: false);
    for (final e in entries) {
      if (e is! File) continue;
      final name = path.basename(e.path).toLowerCase();
      if (!name.endsWith(".dll")) continue;
      if (!name.startsWith("bass")) continue;
      if (coreDlls.contains(name)) continue;

      final pluginFullPath = e.path;
      final pluginPathP = pluginFullPath.toNativeUtf16().cast<ffi.Char>();
      final hplugin = _bass.BASS_PluginLoad(pluginPathP, bass.BASS_UNICODE);
      if (hplugin == 0) {
        final errCode = _bass.BASS_ErrorGetCode();
        LOGGER.w("Failed to load plugin $pluginFullPath: Error $errCode");
      }
      malloc.free(pluginPathP);
    }

    try {
      _bassInit();
    } catch (err) {
      LOGGER.e("[bass init] $err");
    }

    // BASS_FX - 加载bass_fx必须在bass初始化之后
    _loadBassFx();
  }

  void _loadBassFx() {
    try {
      final bassFxLibPath = path.join(_bassDir, "bass_fx.dll");
      final bassFxFile = File(bassFxLibPath);
      if (!bassFxFile.existsSync()) {
        LOGGER.w("bass_fx.dll file not found at: $bassFxLibPath");
        return;
      }

      LOGGER.i("Attempting to load bass_fx.dll from: $bassFxLibPath");

      // 方法1: 使用DynamicLibrary.process() - 利用已加载的库符号
      try {
        LOGGER.d("Method 1: Loading with DynamicLibrary.process()");
        final processSym = ffi.DynamicLibrary.process();
        final tempBassFx = BassFx(processSym);
        final version = tempBassFx.BASS_FX_GetVersion();
        _bassFx = tempBassFx;
        LOGGER.i(
            "✓ BASS_FX loaded via process symbols! Version: ${version.toRadixString(16)}");
        return;
      } catch (e) {
        LOGGER.w("Method 1 failed: $e");
      }

      // 方法2: 直接用绝对路径加载
      try {
        LOGGER.d("Method 2: Loading with absolute path");
        final bassFxLib = ffi.DynamicLibrary.open(bassFxLibPath);
        final tempBassFx = BassFx(bassFxLib);
        final version = tempBassFx.BASS_FX_GetVersion();
        _bassFx = tempBassFx;
        LOGGER.i(
            "✓ BASS_FX loaded successfully! Version: ${version.toRadixString(16)}");
        return;
      } catch (e) {
        LOGGER.w("Method 2 failed: $e");
      }

      // 方法3: 用相对路径加载
      try {
        LOGGER.d("Method 3: Loading with relative path");
        final bassFxLib = ffi.DynamicLibrary.open("bass_fx.dll");
        final tempBassFx = BassFx(bassFxLib);
        final version = tempBassFx.BASS_FX_GetVersion();
        _bassFx = tempBassFx;
        LOGGER.i(
            "✓ BASS_FX loaded successfully! Version: ${version.toRadixString(16)}");
        return;
      } catch (e) {
        LOGGER.w("Method 3 failed: $e");
      }

      // 方法4: 尝试只加载dll而不立即验证函数
      try {
        LOGGER.d("Method 4: Loading without immediate version check");
        final bassFxLib = ffi.DynamicLibrary.open(bassFxLibPath);
        _bassFx = BassFx(bassFxLib);
        LOGGER.i("✓ BASS_FX library loaded (version check deferred)");
        return;
      } catch (e) {
        LOGGER.w("Method 4 failed: $e");
      }

      LOGGER.e("❌ All methods to load bass_fx.dll have failed");
    } catch (e) {
      LOGGER.e("Unexpected error during bass_fx loading: $e");
    }
  }

  /// true: 操作成功；false: 操作失败
  bool useExclusiveMode(bool exclusive) {
    final prevState = wasapiExclusive;
    try {
      _logAudioState("useExclusiveMode(begin,$exclusive)");
      if (exclusive && !_eqBypass && !_isEqFlat) {
        LOGGER.w("[bass] Cannot enable exclusive mode while EQ is enabled");
        showTextOnSnackBar("独占模式与均衡器冲突，请先关闭均衡器（全部归零）");
        return false;
      }
      final pathToReload = _fPath;
      final lastPos = position;
      if (_fstream != null) {
        _positionUpdater?.cancel();
        _removeEQ();
        if (_streamWasapiExclusive) {
          _bassWasapi.BASS_WASAPI_Stop(bass.TRUE);
          _bassWasapi.BASS_WASAPI_Free();
        } else {
          _bass.BASS_ChannelStop(_fstream!);
        }
        freeFStream();
      }
      if (prevState) {
        _bassWasapi.BASS_WASAPI_Stop(bass.TRUE);
        _bassWasapi.BASS_WASAPI_Free();
        _bassInit();
      }
      wasapiExclusive = exclusive;
    // 通知独占模式状态变化
    onExclusiveModeChanged?.call(exclusive);
    if (pathToReload != null) {
        setSource(pathToReload);
        setVolumeDsp(AppPreference.instance.playbackPref.volumeDsp);
        seek(lastPos);
        start();
    }
    _logAudioState("useExclusiveMode(end,$exclusive)");
    return true;
    } catch (err) {
      LOGGER.e("[use exclusive mode] $err");
      showTextOnSnackBar(err.toString());
    }
    wasapiExclusive = prevState;
    return false;
  }

  /// if setSource has been called once,
  /// it will pause current channel and free current stream.
  void setSource(String path) {
    _logAudioState("setSource(begin)");
    if (_fstream != null) {
      _positionUpdater?.cancel();
      _removeEQ();
      final oldHandle = _fstream!;
      if (_streamWasapiExclusive) {
        _bassWasapi.BASS_WASAPI_Stop(bass.TRUE);
        _bassWasapi.BASS_WASAPI_Free();
      } else {
        final stopped = _bass.BASS_ChannelStop(oldHandle);
        if (stopped == 0) {
          LOGGER.w(
            "[bass] cleanup stop failed: err=${_bass.BASS_ErrorGetCode()} handle=$oldHandle",
          );
        }
      }
      final freed = _bass.BASS_StreamFree(oldHandle);
      if (freed == 0) {
        LOGGER.w(
          "[bass] cleanup free failed: err=${_bass.BASS_ErrorGetCode()} handle=$oldHandle",
        );
      }
      _fstream = null;
    }
    final pathPointer = path.toNativeUtf16() as ffi.Pointer<ffi.Void>;

    if (!wasapiExclusive &&
        AppPreference.instance.playbackPref.reinitOnSetSource) {
      try {
        _bassInit();
      } catch (_) {}
    }

    /// 设置 flags 为 BASS_UNICODE 才可以找到文件。
    const flags =
        bass.BASS_UNICODE | bass.BASS_SAMPLE_FLOAT | bass.BASS_ASYNCFILE;
    const exclusiveFlags = flags | bass.BASS_STREAM_DECODE;
    // 如果要使用 FX，源流必须是 DECODE 的
    const decodeFlags = flags | bass.BASS_STREAM_DECODE;

    var handle = _bass.BASS_StreamCreateFile(
      bass.FALSE,
      pathPointer,
      0,
      0,
      wasapiExclusive ? exclusiveFlags : decodeFlags,
    );

    if (handle != 0 && !wasapiExclusive) {
      // 创建 Tempo 流
      // 如果没有加载 bass_fx 或者创建失败，就回退到原始流（但原始流是 decode 的，不能直接播，需要重新创建）
      try {
        if (_bassFx != null) {
          final tempoHandle =
              _bassFx!.BASS_FX_TempoCreate(handle, BASS_FX_FREESOURCE);
          if (tempoHandle != 0) {
            handle = tempoHandle;
          } else {
            // FX 创建失败，回退
            _bass.BASS_StreamFree(handle);
            handle = _bass.BASS_StreamCreateFile(
              bass.FALSE,
              pathPointer,
              0,
              0,
              flags,
            );
          }
        } else {
          // bass_fx 未加载
          _bass.BASS_StreamFree(handle);
          handle = _bass.BASS_StreamCreateFile(
            bass.FALSE,
            pathPointer,
            0,
            0,
            flags,
          );
        }
      } catch (e) {
        // bass_fx 未加载等情况
        _bass.BASS_StreamFree(handle);
        handle = _bass.BASS_StreamCreateFile(
          bass.FALSE,
          pathPointer,
          0,
          0,
          flags,
        );
      }
    } else if (handle != 0 && wasapiExclusive) {
      // exclusive 模式本身就需要 decode 流，不需要 FX
    }

    if (handle != 0) {
      _fstream = handle;
      _fPath = path;
      _streamWasapiExclusive = wasapiExclusive;

      try {
        refreshEQ();
      } catch (e) {
        LOGGER.e("SetSource refreshEQ failed: $e");
      }

      if (_rate != 1.0) {
        setRate(_rate);
      }
      if (_pitch != 0.0) {
        setPitch(_pitch);
      }
      _logAudioState("setSource(ok)");
    } else {
      _fstream = null;
      _fPath = null;
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_INIT:
          _bassInit();
          setSource(path);
          break;
        case bass.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
            "The BASS_STREAM_AUTOFREE flag cannot be combined with the BASS_STREAM_DECODE flag.",
          );
        case bass.BASS_ERROR_ILLPARAM:
          throw const FormatException(
            "The length must be specified when streaming from memory.",
          );
        case bass.BASS_ERROR_FILEOPEN:
          throw const FormatException("The file could not be opened.");
        case bass.BASS_ERROR_FILEFORM:
          throw const FormatException(
            "The file's format is not recognised/supported.",
          );
        case bass.BASS_ERROR_NOTAUDIO:
          throw const FormatException(
            "The file does not contain audio, or it also contains video and videos are disabled.",
          );
        case bass.BASS_ERROR_CODEC:
          throw const FormatException(
            "The file uses a codec that is not available/supported. This can apply to WAV and AIFF files.",
          );
        case bass.BASS_ERROR_FORMAT:
          throw const FormatException("The sample format is not supported.");
        case bass.BASS_ERROR_SPEAKER:
          throw const FormatException(
            "The specified SPEAKER flags are invalid.",
          );
        case bass.BASS_ERROR_MEM:
          throw const FormatException("There is insufficient memory.");
        case bass.BASS_ERROR_NO3D:
          throw const FormatException("Could not initialize 3D support.");
        case bass.BASS_ERROR_UNKNOWN:
          throw const FormatException("Some other mystery problem!");
      }
    }
  }

  /// [BASS_ATTRIB_VOLDSP] attribute does have direct effect on decoding/recording channels.
  void setVolumeDsp(double volume) {
    if (_fstream == null) return;

    if (_bass.BASS_ChannelSetAttribute(
          _fstream!,
          bass.BASS_ATTRIB_VOLDSP,
          volume,
        ) ==
        0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_HANDLE:
          throw const FormatException("handle is not a valid channel.");
        case bass.BASS_ERROR_ILLTYPE:
          throw const FormatException("attrib is not valid.");
        case bass.BASS_ERROR_ILLPARAM:
          throw const FormatException("value is not valid.");
      }
    }
  }

  void setRate(double rate) {
    _rate = rate;
    if (_fstream == null) return;

    if (wasapiExclusive && _rate != 1.0) {
      LOGGER.w("[bass] rate change in exclusive mode, fallback to shared mode");
      useExclusiveMode(false);
      return;
    }

    // 尝试设置 Tempo (百分比变化)
    // 1.0 -> 0%, 1.5 -> 50%, 0.5 -> -50%
    final tempo = (_rate - 1.0) * 100.0;

    // 优先尝试使用 BASS_FX 的 Tempo 属性
    if (_bass.BASS_ChannelSetAttribute(
          _fstream!,
          BASS_ATTRIB_TEMPO,
          tempo,
        ) ==
        0) {
      // 如果失败（例如不是 Tempo 流），回退到原来的采样率改变方式 (变速变调)
      // 获取当前流的原始采样率
      final freqPtr = malloc.allocate<ffi.Float>(ffi.sizeOf<ffi.Float>());
      // 注意：这里我们无法轻易获取"原始"采样率，如果已经改变过。
      // 但通常 BASS_ATTRIB_FREQ 读出来的是当前的。
      // 简便起见，如果不支持 Tempo，我们暂时不做处理，或者需要在创建流时记录原始采样率。
      // 考虑到兼容性，如果 bass_fx 不存在，_fstream 就是普通流，
      // 这时我们应该读取当前 freq 然后根据 _rate 调整。
      // 但由于 _baseFreq 在重构中移除了，这里为了稳健，先尝试获取当前频率

      if (_bass.BASS_ChannelGetAttribute(
              _fstream!, bass.BASS_ATTRIB_FREQ, freqPtr) !=
          0) {
        // 这里有个问题：如果多次调用 setRate，基于当前 freq 修改会导致累积误差。
        // 理想情况是我们在 setSource 时保存了 _baseFreq。
        // 但由于我们现在主推 bass_fx，这里作为 fallback 可以暂不实现复杂逻辑，
        // 或者仅仅在控制台输出警告。
        malloc.free(freqPtr);
        LOGGER.w(
            "BASS_ATTRIB_TEMPO failed, and fallback implementation is skipped.");
      } else {
        malloc.free(freqPtr);
      }
    }
  }

  void setPitch(double pitch) {
    _pitch = pitch;
    if (_fstream == null) return;

    if (wasapiExclusive && _pitch != 0.0) {
      LOGGER
          .w("[bass] pitch change in exclusive mode, fallback to shared mode");
      useExclusiveMode(false);
      return;
    }

    _bass.BASS_ChannelSetAttribute(
      _fstream!,
      BASS_ATTRIB_TEMPO_PITCH,
      pitch,
    );
  }

  void _bassWasapiInit() {
    if (_fstream == null) return;

    final pref = AppPreference.instance.playbackPref;
    final bufferSec = pref.wasapiBufferSec.clamp(0.05, 0.30).toDouble();
    final flags = bass_wasapi.BASS_WASAPI_EXCLUSIVE;

    // 重置WASAPI状态
    _bassWasapi.BASS_WASAPI_Stop(bass.TRUE);
    _bassWasapi.BASS_WASAPI_Free();

    // 使用默认采样率 44100，让BASS自动选择合适的格式
    const initFreq = 44100;

    // 正确转换句柄为指针类型
    if (_bassWasapi.BASS_WASAPI_Init(
          -1, // 默认设备
          initFreq,
          0, // 自动选择声道数
          flags,
          bufferSec,
          0.0,
          ffi.Pointer<bass_wasapi.WASAPIPROC>.fromAddress(0), // 空指针
          ffi.Pointer<ffi.Void>.fromAddress(_fstream!), // 正确转换句柄为指针
        ) ==
        bass.FALSE) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass_wasapi.BASS_ERROR_WASAPI:
          throw const FormatException("WASAPI is not available.");
        case bass.BASS_ERROR_DEVICE:
          throw const FormatException("device is invalid.");
        case bass.BASS_ERROR_ALREADY:
          _bassWasapi.BASS_WASAPI_Stop(bass.TRUE);
          _bassWasapi.BASS_WASAPI_Free();
          _bassWasapiInit();
          break;
        case bass.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
            "Exclusive mode and/or event-driven buffering is unavailable on the device, or WASAPIPROC_PUSH is unavailable on input devices and when using event-driven buffering.",
          );
        case bass.BASS_ERROR_DRIVER:
          throw const FormatException("The driver could not be initialized.");
        case bass.BASS_ERROR_HANDLE:
          throw const FormatException(
            "The BASS channel handle in user is invalid, or not of the required type.",
          );
        case bass.BASS_ERROR_FORMAT:
          throw const FormatException(
            "The specified format (or that of the BASS channel) is not supported by the device. If the BASS_WASAPI_AUTOFORMAT flag was specified, no other format could be found either.",
          );
        case bass.BASS_ERROR_BUSY:
          throw const FormatException(
            "The device is already in use, eg. another process may have initialized it in exclusive mode.",
          );
        case bass.BASS_ERROR_INIT:
          _bassInit();
          _bassWasapiInit();
          break;
        case bass_wasapi.BASS_ERROR_WASAPI_BUFFER:
          throw const FormatException(
            "buffer is too large or small (exclusive mode only).",
          );
        case bass_wasapi.BASS_ERROR_WASAPI_CATEGORY:
          throw const FormatException(
            "The category/raw mode could not be set.",
          );
        case bass_wasapi.BASS_ERROR_WASAPI_DENIED:
          throw const FormatException(
            "Access to the device is denied. This could be due to privacy settings.",
          );
        case bass.BASS_ERROR_UNKNOWN:
          throw const FormatException("Some other mystery problem!");
      }
    }
  }

  void _start_wasapiExclusive() {
    try {
      _bassWasapiInit();
    } catch (err) {
      LOGGER.w("[bass] wasapi exclusive init failed, fallback to shared: $err");
      showTextOnSnackBar("独占模式初始化失败，已切回共享模式");
      useExclusiveMode(false);
      return;
    }

    if (_bassWasapi.BASS_WASAPI_Start() == bass.FALSE) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_INIT:
          _bassWasapiInit();
          _start_wasapiExclusive();
          break;
        case bass.BASS_ERROR_UNKNOWN:
          throw const FormatException("Some other mystery problem!");
      }
    }
    _playerStateStreamController.add(playerState);
    _positionUpdater?.cancel();
    _refreshStreamSampleRate();
    _spectrumTickPeriod = _computeSpectrumTickPeriod();
    _lastSpectrumUpdateUs = 0;
    _positionUpdater = _getPositionUpdater(_computePlayingTickPeriod());
  }

  /// start/resume channel
  ///
  /// do nothing if [setSource] hasn't been called
  void start() {
    if (_fstream == null) return;

    if (wasapiExclusive) {
      _logAudioState("start(wasapi)");
      return _start_wasapiExclusive();
    }
    _logAudioState("start(normal)");
    if (_bass.BASS_ChannelStart(_fstream!) == 0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_HANDLE:
          throw const FormatException("handle is not a valid channel.");
        case bass.BASS_ERROR_DECODE:
          throw const FormatException(
            "handle is a decoding channel, so cannot be played.",
          );
        case bass.BASS_ERROR_START:
          _startDevice();
          start();
          break;
      }
    }

    _playerStateStreamController.add(playerState);
    _positionUpdater?.cancel();
    _refreshStreamSampleRate();
    _spectrumTickPeriod = _computeSpectrumTickPeriod();
    _lastSpectrumUpdateUs = 0;
    _positionUpdater = _getPositionUpdater(_computePlayingTickPeriod());
    _logAudioState("start(done)");
  }

  void _pause_wasapiExclusive() {
    if (_bassWasapi.BASS_WASAPI_Stop(bass.TRUE) == bass.TRUE) {
      _playerStateStreamController.add(playerState);
      _positionUpdater?.cancel();
      _positionUpdater = _getPositionUpdater(const Duration(milliseconds: 120));
      _positionStreamController.add(position);
    }
  }

  /// pause channel, call [start] to resume channel
  ///
  /// do nothing if [setSource] hasn't been called
  void pause() {
    if (_fstream == null) return;

    if (wasapiExclusive) {
      _logAudioState("pause(wasapi)");
      return _pause_wasapiExclusive();
    }
    _logAudioState("pause(normal)");

    if (_bass.BASS_ChannelPause(_fstream!) == 0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_HANDLE:
          throw const FormatException("handle is not a valid channel.");
        case bass.BASS_ERROR_DECODE:
          throw const FormatException(
            "handle is a decoding channel, so cannot be played or paused.",
          );
        case bass.BASS_ERROR_NOPLAY:
          throw const FormatException("The channel is not playing.");
      }
    }

    _playerStateStreamController.add(playerState);
    _positionUpdater?.cancel();
    _positionUpdater = _getPositionUpdater(const Duration(milliseconds: 120));
    _positionStreamController.add(position);
    _logAudioState("pause(done)");
  }

  /// set channel's position to given [position]
  /// don't check if the position is valid.
  ///
  /// do nothing if [setSource] hasn't been called
  void seek(double position) {
    if (_fstream == null) return;
    _logAudioState("seek(begin,$position)");

    if (_bass.BASS_ChannelSetPosition(
          _fstream!,
          _bass.BASS_ChannelSeconds2Bytes(_fstream!, position),
          bass.BASS_POS_BYTE,
        ) ==
        0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_HANDLE:
          throw const FormatException("handle is not a valid channel.");
        case bass.BASS_ERROR_NOTFILE:
          throw const FormatException("The stream is not a file stream.");
        case bass.BASS_ERROR_POSITION:
          throw const FormatException(
            "The requested position is invalid, eg. it is beyond the end or the download has not yet reached it.",
          );
        case bass.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
            "The requested mode is not available. Invalid flags are ignored and do not result in this error.",
          );
        case bass.BASS_ERROR_UNKNOWN:
          throw const FormatException("Some other mystery problem!");
      }
    }
    _positionStreamController.add(this.position);
    _logAudioState("seek(end,$position)");
  }

  /// It is not necessary to individually free the samples/streams/musics
  /// as these are all automatically freed after [setSource] or [free] is called.
  ///
  /// do nothing if [setSource] hasn't been called
  void freeFStream() {
    if (_fstream == null) return;

    if (_bass.BASS_StreamFree(_fstream!) == 0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_HANDLE:
          LOGGER.w("StreamFree is called on a invalid handle.");
          break;
        case bass.BASS_ERROR_NOTAVAIL:
          throw const FormatException(
            "Device streams (STREAMPROC_DEVICE) cannot be freed.",
          );
      }
    }
    _fstream = null;
    _fPath = null;
    _streamWasapiExclusive = false;
    _eqHandles.clear();
  }

  /// Frees all resources used by the output device,
  /// including all its samples, streams and MOD musics.
  ///
  /// Also free the bass.dll.
  void free() {
    if (wasapiExclusive) {
      _bassWasapi.BASS_WASAPI_Stop(bass.TRUE);
      _bassWasapi.BASS_WASAPI_Free();
    }

    if (_bass.BASS_Free() == 0) {
      switch (_bass.BASS_ErrorGetCode()) {
        case bass.BASS_ERROR_INIT:
          LOGGER.w("BASS_Free is called before BASS_Init complete normally.");
          break;
        case bass.BASS_ERROR_BUSY:
          throw const FormatException(
            "The device is currently being reinitialized.",
          );
      }
    }

    _bassWasapiLib.close();
    _bassLib.close();

    _positionUpdater?.cancel();
    _playerStateStreamController.close();
    _positionStreamController.close();
    _spectrumStreamController.close();
    if (_fftBuffer != null) {
      malloc.free(_fftBuffer!);
      _fftBuffer = null;
    }
  }
}
