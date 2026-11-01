import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _DataBlob extends ffi.Struct {
  @ffi.Uint32()
  external int cbData;

  external ffi.Pointer<ffi.Uint8> pbData;
}

// CryptProtectData / CryptUnprotectData:
// BOOL fn(DATA_BLOB *pDataIn, LPCWSTR *ppszDataDescr, DATA_BLOB *pOptionalEntropy,
//         PVOID pvReserved, CRYPTPROTECT_PROMPTSTRUCT *pPromptStruct,
//         DWORD dwFlags, DATA_BLOB *pDataOut)
typedef _CryptDataNative =
    ffi.Int32 Function(
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<ffi.Pointer<ffi.Uint16>>,
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Uint32,
      ffi.Pointer<_DataBlob>,
    );
typedef _CryptDataDart =
    int Function(
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<ffi.Pointer<ffi.Uint16>>,
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      int,
      ffi.Pointer<_DataBlob>,
    );

typedef _LocalFreeNative =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);
typedef _LocalFreeDart =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);

typedef _GetLastErrorNative = ffi.Uint32 Function();
typedef _GetLastErrorDart = int Function();

const int _cryptprotectUiForbidden = 0x1;

final _crypt32 = ffi.DynamicLibrary.open('crypt32.dll');
final _kernel32 = ffi.DynamicLibrary.open('kernel32.dll');

final _protect = _crypt32
    .lookup<ffi.NativeFunction<_CryptDataNative>>('CryptProtectData')
    .asFunction<_CryptDataDart>();
final _unprotect = _crypt32
    .lookup<ffi.NativeFunction<_CryptDataNative>>('CryptUnprotectData')
    .asFunction<_CryptDataDart>();
final _localFree = _kernel32
    .lookup<ffi.NativeFunction<_LocalFreeNative>>('LocalFree')
    .asFunction<_LocalFreeDart>();
final _getLastError = _kernel32
    .lookup<ffi.NativeFunction<_GetLastErrorNative>>('GetLastError')
    .asFunction<_GetLastErrorDart>();

/// 走一次 DPAPI。输入/中间结构用 calloc 分配、calloc 释放，
/// 输出的缓冲区由系统用 LocalAlloc 分配，只能用 LocalFree 还回去。
Uint8List _runCrypt({required bool protect, required Uint8List input}) {
  final inputPtr = calloc<ffi.Uint8>(input.isEmpty ? 1 : input.length);
  final inputBlob = calloc<_DataBlob>(1);
  final outputBlob = calloc<_DataBlob>(1);
  try {
    if (input.isNotEmpty) {
      inputPtr.asTypedList(input.length).setAll(0, input);
    }
    inputBlob.ref
      ..cbData = input.length
      ..pbData = inputPtr;
    outputBlob.ref
      ..cbData = 0
      ..pbData = ffi.nullptr;
    final call = protect ? _protect : _unprotect;
    final ok = call(
      inputBlob,
      ffi.nullptr,
      ffi.nullptr,
      ffi.nullptr,
      ffi.nullptr,
      _cryptprotectUiForbidden,
      outputBlob,
    );
    if (ok == 0) {
      final code = _getLastError();
      final name = protect ? 'CryptProtectData' : 'CryptUnprotectData';
      throw StateError('$name 调用失败（Windows 错误码 $code）');
    }
    final outPtr = outputBlob.ref.pbData;
    final outLength = outputBlob.ref.cbData;
    if (outPtr == ffi.nullptr) return Uint8List(0);
    try {
      if (outLength == 0) return Uint8List(0);
      return Uint8List.fromList(outPtr.asTypedList(outLength));
    } finally {
      _localFree(outPtr.cast());
      outputBlob.ref.pbData = ffi.nullptr;
    }
  } finally {
    calloc.free(inputPtr);
    calloc.free(inputBlob);
    calloc.free(outputBlob);
  }
}

String protectSecret(String plainText) {
  if (plainText.isEmpty) return '';
  final protected = _runCrypt(
    protect: true,
    input: Uint8List.fromList(utf8.encode(plainText)),
  );
  return base64Encode(protected);
}

String unprotectSecret(String encoded) {
  if (encoded.isEmpty) return '';
  final Uint8List input;
  try {
    input = base64Decode(encoded);
  } on FormatException catch (error) {
    throw StateError('保存的密码数据已损坏：${error.message}');
  }
  if (input.isEmpty) return '';
  final plain = _runCrypt(protect: false, input: input);
  if (plain.isEmpty) return '';
  try {
    return utf8.decode(plain);
  } on FormatException catch (error) {
    throw StateError('保存的密码无法解析：${error.message}');
  }
}
