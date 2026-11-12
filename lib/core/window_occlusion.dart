import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:window_manager/window_manager.dart';

/// 最大化窗口的边框会比屏幕多出几个像素，留一点容差再判断包含。
const _coverTolerance = 16.0;

/// 桌面、任务栏这类壳层窗口不作为遮挡依据。
const _shellWindowClasses = {
  'Progman',
  'WorkerW',
  'Shell_TrayWnd',
  'Shell_SecondaryTrayWnd',
  'Windows.UI.Core.CoreWindow',
};

/// 前台窗口是否把本窗口完全盖住。
/// 前台窗口在另一块显示器上时，矩形不会包含本窗口，副屏窗口照常渲染。
bool shouldTreatWindowCovered({
  required Rect windowBounds,
  required Rect foregroundBounds,
  required int foregroundProcessId,
  required int currentProcessId,
  required String foregroundClassName,
}) {
  if (foregroundProcessId == currentProcessId) return false;
  if (_shellWindowClasses.contains(foregroundClassName)) return false;
  if (windowBounds.isEmpty || foregroundBounds.isEmpty) return false;
  return foregroundBounds.left <= windowBounds.left + _coverTolerance &&
      foregroundBounds.top <= windowBounds.top + _coverTolerance &&
      foregroundBounds.right >= windowBounds.right - _coverTolerance &&
      foregroundBounds.bottom >= windowBounds.bottom - _coverTolerance;
}

final class _WinRect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

typedef _GetForegroundWindowNative = IntPtr Function();
typedef _GetForegroundWindowDart = int Function();

typedef _GetWindowRectNative =
    Int32 Function(IntPtr hwnd, Pointer<_WinRect> rect);
typedef _GetWindowRectDart = int Function(int hwnd, Pointer<_WinRect> rect);

typedef _GetWindowThreadProcessIdNative =
    Uint32 Function(IntPtr hwnd, Pointer<Uint32> processId);
typedef _GetWindowThreadProcessIdDart =
    int Function(int hwnd, Pointer<Uint32> processId);

typedef _GetClassNameNative =
    Int32 Function(IntPtr hwnd, Pointer<Utf16> name, Int32 maxCount);
typedef _GetClassNameDart =
    int Function(int hwnd, Pointer<Utf16> name, int maxCount);

typedef _GetCurrentProcessIdNative = Uint32 Function();
typedef _GetCurrentProcessIdDart = int Function();

final _user32 = DynamicLibrary.open('user32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _getForegroundWindow = _user32
    .lookupFunction<_GetForegroundWindowNative, _GetForegroundWindowDart>(
      'GetForegroundWindow',
    );
final _getWindowRect = _user32
    .lookupFunction<_GetWindowRectNative, _GetWindowRectDart>('GetWindowRect');
final _getWindowThreadProcessId = _user32
    .lookupFunction<
      _GetWindowThreadProcessIdNative,
      _GetWindowThreadProcessIdDart
    >('GetWindowThreadProcessId');
final _getClassName = _user32
    .lookupFunction<_GetClassNameNative, _GetClassNameDart>('GetClassNameW');
final _getCurrentProcessId = _kernel32
    .lookupFunction<_GetCurrentProcessIdNative, _GetCurrentProcessIdDart>(
      'GetCurrentProcessId',
    );

/// 查一次前台窗口是否真的挡住了本窗口。拿不到窗口信息时按未遮挡处理，
/// 宁可多渲染也不要把副屏上正在看的窗口停掉。
Future<bool> isWindowCoveredByForeground() async {
  if (!Platform.isWindows) return false;
  final Rect bounds;
  final double pixelRatio;
  try {
    bounds = await windowManager.getBounds();
    // getBounds 返回逻辑像素，Win32 的窗口矩形是物理像素。
    pixelRatio = windowManager.getDevicePixelRatio();
  } catch (_) {
    return false;
  }
  if (bounds.isEmpty) return false;
  final windowBounds = Rect.fromLTRB(
    bounds.left * pixelRatio,
    bounds.top * pixelRatio,
    bounds.right * pixelRatio,
    bounds.bottom * pixelRatio,
  );
  final foreground = _getForegroundWindow();
  if (foreground == 0) return false;
  final rect = calloc<_WinRect>();
  final processId = calloc<Uint32>();
  final className = calloc<Uint16>(256);
  try {
    if (_getWindowRect(foreground, rect) == 0) return false;
    _getWindowThreadProcessId(foreground, processId);
    final length = _getClassName(foreground, className.cast<Utf16>(), 256);
    return shouldTreatWindowCovered(
      windowBounds: windowBounds,
      foregroundBounds: Rect.fromLTRB(
        rect.ref.left.toDouble(),
        rect.ref.top.toDouble(),
        rect.ref.right.toDouble(),
        rect.ref.bottom.toDouble(),
      ),
      foregroundProcessId: processId.value,
      currentProcessId: _getCurrentProcessId(),
      foregroundClassName: length > 0
          ? className.cast<Utf16>().toDartString()
          : '',
    );
  } finally {
    calloc.free(rect);
    calloc.free(processId);
    calloc.free(className);
  }
}
