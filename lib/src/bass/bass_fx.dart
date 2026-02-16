// ignore_for_file: constant_identifier_names

import 'dart:ffi' as ffi;
import 'bass.dart';

// BASS_FX constants
const int BASS_FX_FREESOURCE = 0x10000;

// Attributes
const int BASS_ATTRIB_TEMPO = 0x10000;
const int BASS_ATTRIB_TEMPO_PITCH = 0x10001;
const int BASS_ATTRIB_TEMPO_FREQ = 0x10002;

class BassFx {
  final ffi.DynamicLibrary _lib;
  bool _initialized = false;
  late final int _BASS_FX_GetVersionHandle;
  late final int _BASS_FX_TempoCreateHandle;

  BassFx(ffi.DynamicLibrary dynamicLibrary) : _lib = dynamicLibrary {
    // Try to initialize function pointers, but don't fail if we can't
    try {
      _BASS_FX_GetVersionHandle = _lib
          .lookup<ffi.NativeFunction<ffi.Uint32 Function()>>(
            'BASS_FX_GetVersion',
          )
          .address;
      _BASS_FX_TempoCreateHandle = _lib
          .lookup<ffi.NativeFunction<HSTREAM Function(DWORD, DWORD)>>(
            'BASS_FX_TempoCreate',
          )
          .address;
      _initialized = true;
    } catch (e) {
      // Functions will be looked up lazily when accessed
      _initialized = false;
    }
  }

  /// HSTREAM BASS_FX_TempoCreate(DWORD chan, DWORD flags);
  late final _BASS_FX_TempoCreatePtr = () {
    try {
      return _lib.lookup<ffi.NativeFunction<HSTREAM Function(DWORD, DWORD)>>(
        'BASS_FX_TempoCreate',
      );
    } catch (e) {
      throw Exception('Failed to lookup BASS_FX_TempoCreate: $e');
    }
  }();

  late final BASS_FX_TempoCreate = () {
    try {
      return _BASS_FX_TempoCreatePtr.asFunction<int Function(int, int)>();
    } catch (e) {
      throw Exception(
          'Failed to create BASS_FX_TempoCreate function binding: $e');
    }
  }();

  /// DWORD BASS_FX_GetVersion(void);
  late final _BASS_FX_GetVersionPtr = () {
    try {
      return _lib.lookup<ffi.NativeFunction<ffi.Uint32 Function()>>(
        'BASS_FX_GetVersion',
      );
    } catch (e) {
      throw Exception('Failed to lookup BASS_FX_GetVersion: $e');
    }
  }();

  late final BASS_FX_GetVersion = () {
    try {
      return _BASS_FX_GetVersionPtr.asFunction<int Function()>();
    } catch (e) {
      throw Exception(
          'Failed to create BASS_FX_GetVersion function binding: $e');
    }
  }();
}
