import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _DataBlob extends ffi.Struct {
  @ffi.Uint32()
  external int cbData;

  external ffi.Pointer<ffi.Uint8> pbData;
}

typedef _CryptProtectDataNative =
    ffi.Int32 Function(
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<ffi.Uint16>,
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Uint32,
      ffi.Pointer<_DataBlob>,
    );
typedef _CryptProtectDataDart =
    int Function(
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<ffi.Uint16>,
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

const int _cryptprotectUiForbidden = 0x1;

final _crypt32 = ffi.DynamicLibrary.open('crypt32.dll');
final _kernel32 = ffi.DynamicLibrary.open('kernel32.dll');

final _protect = _crypt32
    .lookup<ffi.NativeFunction<_CryptProtectDataNative>>('CryptProtectData')
    .asFunction<_CryptProtectDataDart>();
final _unprotect = _crypt32
    .lookup<ffi.NativeFunction<_CryptProtectDataNative>>('CryptUnprotectData')
    .asFunction<_CryptProtectDataDart>();
final _localFree = _kernel32
    .lookup<ffi.NativeFunction<_LocalFreeNative>>('LocalFree')
    .asFunction<_LocalFreeDart>();

String protectSecret(String plainText) {
  if (plainText.isEmpty) return '';
  final input = utf8.encode(plainText);
  final inputPtr = malloc.allocate<ffi.Uint8>(input.length);
  final inputBlob = malloc.allocate<_DataBlob>(1);
  final outputBlob = malloc.allocate<_DataBlob>(1);
  try {
    inputPtr.asTypedList(input.length).setAll(0, input);
    inputBlob.ref
      ..cbData = input.length
      ..pbData = inputPtr;
    outputBlob.ref
      ..cbData = 0
      ..pbData = ffi.nullptr;
    final ok = _protect(
      inputBlob,
      ffi.nullptr,
      ffi.nullptr,
      ffi.nullptr,
      ffi.nullptr,
      _cryptprotectUiForbidden,
      outputBlob,
    );
    if (ok == 0) throw StateError('CryptProtectData 失败');
    final protected = Uint8List.fromList(
      outputBlob.ref.pbData.asTypedList(outputBlob.ref.cbData),
    );
    return base64Encode(protected);
  } finally {
    if (outputBlob.ref.pbData != ffi.nullptr) {
      _localFree(outputBlob.ref.pbData.cast());
    }
    malloc.free(inputPtr);
    malloc.free(inputBlob);
    malloc.free(outputBlob);
  }
}

String unprotectSecret(String encoded) {
  if (encoded.isEmpty) return '';
  final input = base64Decode(encoded);
  final inputPtr = malloc.allocate<ffi.Uint8>(input.length);
  final inputBlob = malloc.allocate<_DataBlob>(1);
  final outputBlob = malloc.allocate<_DataBlob>(1);
  try {
    inputPtr.asTypedList(input.length).setAll(0, input);
    inputBlob.ref
      ..cbData = input.length
      ..pbData = inputPtr;
    outputBlob.ref
      ..cbData = 0
      ..pbData = ffi.nullptr;
    final ok = _unprotect(
      inputBlob,
      ffi.nullptr,
      ffi.nullptr,
      ffi.nullptr,
      ffi.nullptr,
      _cryptprotectUiForbidden,
      outputBlob,
    );
    if (ok == 0) throw StateError('CryptUnprotectData 失败');
    final plain = Uint8List.fromList(
      outputBlob.ref.pbData.asTypedList(outputBlob.ref.cbData),
    );
    return utf8.decode(plain);
  } finally {
    if (outputBlob.ref.pbData != ffi.nullptr) {
      _localFree(outputBlob.ref.pbData.cast());
    }
    malloc.free(inputPtr);
    malloc.free(inputBlob);
    malloc.free(outputBlob);
  }
}
