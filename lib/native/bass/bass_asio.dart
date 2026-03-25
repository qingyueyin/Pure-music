// Minimal BASSASIO bindings (manually written).
//
// This file intentionally wraps only the small subset needed to:
// - lazy-load bassasio.dll
// - init/start/stop/free
// - route a BASS decoding channel to ASIO output via ChannelEnableBASS
//
// It is designed to be optional: callers should guard for missing DLL.

// ignore_for_file: constant_identifier_names, non_constant_identifier_names

import 'dart:ffi' as ffi;

typedef BOOL = ffi.Int32;
typedef DWORD = ffi.Uint32;

class BassAsio {
  final ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName)
      _lookup;

  BassAsio(ffi.DynamicLibrary dynamicLibrary) : _lookup = dynamicLibrary.lookup;

  BassAsio.fromLookup(
    ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName) lookup,
  ) : _lookup = lookup;

  int BASS_ASIO_GetVersion() => _BASS_ASIO_GetVersion();
  late final _BASS_ASIO_GetVersionPtr =
      _lookup<ffi.NativeFunction<DWORD Function()>>('BASS_ASIO_GetVersion');
  late final _BASS_ASIO_GetVersion =
      _BASS_ASIO_GetVersionPtr.asFunction<int Function()>();

  int BASS_ASIO_ErrorGetCode() => _BASS_ASIO_ErrorGetCode();
  late final _BASS_ASIO_ErrorGetCodePtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function()>>(
          'BASS_ASIO_ErrorGetCode');
  late final _BASS_ASIO_ErrorGetCode =
      _BASS_ASIO_ErrorGetCodePtr.asFunction<int Function()>();

  int BASS_ASIO_Init(int device, int flags) => _BASS_ASIO_Init(device, flags);
  late final _BASS_ASIO_InitPtr =
      _lookup<ffi.NativeFunction<BOOL Function(ffi.Int32, DWORD)>>(
          'BASS_ASIO_Init');
  late final _BASS_ASIO_Init =
      _BASS_ASIO_InitPtr.asFunction<int Function(int, int)>();

  int BASS_ASIO_Free() => _BASS_ASIO_Free();
  late final _BASS_ASIO_FreePtr =
      _lookup<ffi.NativeFunction<BOOL Function()>>('BASS_ASIO_Free');
  late final _BASS_ASIO_Free =
      _BASS_ASIO_FreePtr.asFunction<int Function()>();

  int BASS_ASIO_Start(double buflen, int threads) =>
      _BASS_ASIO_Start(buflen, threads);
  late final _BASS_ASIO_StartPtr =
      _lookup<ffi.NativeFunction<BOOL Function(ffi.Double, ffi.Int32)>>(
          'BASS_ASIO_Start');
  late final _BASS_ASIO_Start =
      _BASS_ASIO_StartPtr.asFunction<int Function(double, int)>();

  int BASS_ASIO_Stop() => _BASS_ASIO_Stop();
  late final _BASS_ASIO_StopPtr =
      _lookup<ffi.NativeFunction<BOOL Function()>>('BASS_ASIO_Stop');
  late final _BASS_ASIO_Stop =
      _BASS_ASIO_StopPtr.asFunction<int Function()>();

  int BASS_ASIO_IsStarted() => _BASS_ASIO_IsStarted();
  late final _BASS_ASIO_IsStartedPtr =
      _lookup<ffi.NativeFunction<BOOL Function()>>('BASS_ASIO_IsStarted');
  late final _BASS_ASIO_IsStarted =
      _BASS_ASIO_IsStartedPtr.asFunction<int Function()>();

  /// Route a BASS channel (typically a decoding channel) to an ASIO output channel.
  ///
  /// BOOL BASS_ASIO_ChannelEnableBASS(BOOL input, DWORD channel, DWORD handle, BOOL join);
  int BASS_ASIO_ChannelEnableBASS(
    int input,
    int channel,
    int handle,
    int join,
  ) =>
      _BASS_ASIO_ChannelEnableBASS(input, channel, handle, join);

  late final _BASS_ASIO_ChannelEnableBASSPtr =
      _lookup<ffi.NativeFunction<BOOL Function(BOOL, DWORD, DWORD, BOOL)>>(
          'BASS_ASIO_ChannelEnableBASS');
  late final _BASS_ASIO_ChannelEnableBASS =
      _BASS_ASIO_ChannelEnableBASSPtr.asFunction<int Function(int, int, int, int)>();
}
