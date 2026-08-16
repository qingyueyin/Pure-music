import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

void _disposeComObject(IUnknown object) {
  object.detach();
  object.release();
  calloc.free(object.ptr);
}

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
    try {
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
        if (FAILED(hr)) {
          calloc.free(ppsi);
          throw WindowsException(hr);
        }

        final itemArray = IShellItemArray(ppsi.cast());
        try {
          final pdwNumItems = arena<Uint32>();
          hr = itemArray.getCount(pdwNumItems);
          if (FAILED(hr)) throw WindowsException(hr);

          for (var i = 0; i < pdwNumItems.value; i++) {
            final ppsiItem = calloc<Pointer<COMObject>>();
            hr = itemArray.getItemAt(i, ppsiItem);
            if (FAILED(hr)) {
              calloc.free(ppsiItem);
              throw WindowsException(hr);
            }

            final item = IShellItem(ppsiItem.cast());
            try {
              final ppszName = calloc<Pointer<Utf16>>();
              try {
                hr = item.getDisplayName(SIGDN_FILESYSPATH, ppszName);
                if (FAILED(hr)) throw WindowsException(hr);

                paths.add(ppszName.value.toDartString());
              } finally {
                if (ppszName.value != nullptr) {
                  CoTaskMemFree(ppszName.value);
                }
                calloc.free(ppszName);
              }
            } finally {
              _disposeComObject(item);
            }
          }
        } finally {
          _disposeComObject(itemArray);
        }
      });
    } finally {
      _disposeComObject(dialog);
    }

    if (cancelled) return paths;
  } finally {
    if (comInitialized) CoUninitialize();
  }

  return paths;
}
