import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

List<String> pickMultipleDirectories({String? title}) {
  final paths = <String>[];

  bool comInitialized = false;
  final hrInit = CoInitializeEx(
    nullptr,
    COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE,
  );
  if (!FAILED(hrInit)) {
    comInitialized = true;
  } else if (hrInit != RPC_E_CHANGED_MODE) {
    return paths;
  }

  bool cancelled = false;
  try {
    final dialog = FileOpenDialog.createInstance();

    using((arena) {
      final pfos = arena<Uint32>();
      var hr = dialog.getOptions(pfos);
      if (FAILED(hr)) throw WindowsException(hr);

      var options = pfos.value;
      options |= FOS_PICKFOLDERS;
      options |= FOS_ALLOWMULTISELECT;
      options |= FOS_PATHMUSTEXIST;
      options |= FOS_FORCEFILESYSTEM;

      hr = dialog.setOptions(options);
      if (FAILED(hr)) throw WindowsException(hr);

      if (title != null && title.isNotEmpty) {
        final pTitle = title.toNativeUtf16(allocator: arena);
        hr = dialog.setTitle(pTitle);
        if (FAILED(hr)) throw WindowsException(hr);
      }

      hr = dialog.show(NULL);
      if (FAILED(hr)) {
        if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
          cancelled = true;
          return;
        }
        throw WindowsException(hr);
      }

      final ppsi = calloc<Pointer<COMObject>>();
      hr = dialog.getResults(ppsi);
      if (FAILED(hr)) throw WindowsException(hr);

      final itemArray = IShellItemArray(ppsi.cast());
      final pdwNumItems = arena<Uint32>();
      hr = itemArray.getCount(pdwNumItems);
      if (FAILED(hr)) throw WindowsException(hr);

      for (var i = 0; i < pdwNumItems.value; i++) {
        final ppsiItem = calloc<Pointer<COMObject>>();
        hr = itemArray.getItemAt(i, ppsiItem);
        if (FAILED(hr)) throw WindowsException(hr);

        final item = IShellItem(ppsiItem.cast());
        final ppszName = arena<Pointer<Utf16>>();
        hr = item.getDisplayName(SIGDN_FILESYSPATH, ppszName);
        if (FAILED(hr)) throw WindowsException(hr);

        paths.add(ppszName.value.toDartString());
      }
    });

    if (cancelled) return paths;
  } finally {
    if (comInitialized) CoUninitialize();
  }

  return paths;
}
