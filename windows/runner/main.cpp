#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

// 不强制占用独立显卡。播放器留在系统默认显卡上，避免显存一直堆在高性能卡里。

// 单实例判定用：自身 exe 全路径，按 32768 动态长度取，避免长路径被截断。
// Debug 构建不参与判定，避免未引用告警。
#if defined(NDEBUG)
static std::wstring GetOwnImagePath() {
  std::wstring buffer(32768, L'\0');
  const DWORD length = ::GetModuleFileNameW(
      nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  if (length == 0 || length >= buffer.size()) {
    return std::wstring();
  }
  buffer.resize(length);
  return buffer;
}
#endif


static void AppendCrashLog(const std::wstring& message) {
  HANDLE file = OpenAppLogFile(L"crash.log");
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  const int size = ::WideCharToMultiByte(
      CP_UTF8, 0, message.data(), static_cast<int>(message.size()), nullptr, 0,
      nullptr, nullptr);
  if (size > 0) {
    std::string utf8(size, '\0');
    ::WideCharToMultiByte(CP_UTF8, 0, message.data(),
                          static_cast<int>(message.size()), utf8.data(), size,
                          nullptr, nullptr);
    DWORD bytes_written = 0;
    ::WriteFile(file, utf8.data(), static_cast<DWORD>(utf8.size()),
                &bytes_written, nullptr);
    ::FlushFileBuffers(file);
  }
  ::CloseHandle(file);
}

// 供 runner 内其他翻译单元写同一条时间戳日志。
void AppendRunnerLog(const std::wstring& detail) {
  SYSTEMTIME time;
  ::GetLocalTime(&time);
  std::wstringstream line;
  line << std::setfill(L'0') << std::setw(4) << time.wYear << L'-'
       << std::setw(2) << time.wMonth << L'-' << std::setw(2) << time.wDay
       << L'T' << std::setw(2) << time.wHour << L':' << std::setw(2)
       << time.wMinute << L':' << std::setw(2) << time.wSecond << L"|"
       << detail << L"|pid=" << ::GetCurrentProcessId() << L"\r\n";
  AppendCrashLog(line.str());
}

static void RecordNativeException(const wchar_t* source,
                                  EXCEPTION_POINTERS* exception) {
  SYSTEMTIME time;
  ::GetLocalTime(&time);
  const DWORD code = exception != nullptr && exception->ExceptionRecord != nullptr
                         ? exception->ExceptionRecord->ExceptionCode
                         : 0;
  const void* address =
      exception != nullptr && exception->ExceptionRecord != nullptr
          ? exception->ExceptionRecord->ExceptionAddress
          : nullptr;
  std::wstringstream message;
  message << std::setfill(L'0') << std::setw(4) << time.wYear << L'-'
          << std::setw(2) << time.wMonth << L'-' << std::setw(2) << time.wDay
          << L'T' << std::setw(2) << time.wHour << L':' << std::setw(2)
          << time.wMinute << L':' << std::setw(2) << time.wSecond
          << L"|NATIVE_CRASH|source=" << source << L"|pid="
          << ::GetCurrentProcessId() << L"|thread=" << ::GetCurrentThreadId()
          << L"|code=0x" << std::hex << std::uppercase << code << L"|address="
          << address << L"\r\n";
  AppendCrashLog(message.str());
}

static LONG WINAPI UnhandledExceptionLogger(EXCEPTION_POINTERS* exception) {
  RecordNativeException(L"unhandled", exception);
  return EXCEPTION_CONTINUE_SEARCH;
}

#if defined(_MSC_VER)
static int RecordSehException(EXCEPTION_POINTERS* exception,
                              const wchar_t* source) {
  RecordNativeException(source, exception);
  return EXCEPTION_EXECUTE_HANDLER;
}

static int RunMessageLoop() {
  int exit_code = EXIT_SUCCESS;
  __try {
    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
      __try {
        ::TranslateMessage(&msg);
        ::DispatchMessage(&msg);
      } __except (RecordSehException(GetExceptionInformation(),
                                     L"message_dispatch")) {
        std::cerr << "SEH exception during message dispatch, continuing..." << std::endl;
      }
    }
  } __except (RecordSehException(GetExceptionInformation(), L"message_loop")) {
    std::cerr << "SEH exception in message loop" << std::endl;
    exit_code = EXIT_FAILURE;
  }
  return exit_code;
}
#else
static int RunMessageLoop() {
  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }
  return EXIT_SUCCESS;
}
#endif
namespace {

// 单实例：命名互斥量在创建窗口前判定，第二个进程只唤醒已有窗口后退出。
// Debug 构建不参与，相关函数一并裁掉，避免 /W4 /WX 下的未引用告警。
#if defined(NDEBUG)
constexpr wchar_t kMainWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kShowWindowMessageName[] = L"PureMusic.ShowExistingWindow";
constexpr DWORD kFindWindowTimeoutMs = 5000;
constexpr DWORD kFindWindowIntervalMs = 50;

HANDLE g_instance_mutex = nullptr;

uint32_t Crc32Step(uint32_t crc, uint8_t byte) {
  crc ^= byte;
  for (int bit = 0; bit < 8; ++bit) {
    crc = (crc & 1u) != 0 ? (crc >> 1) ^ 0xEDB88320u : crc >> 1;
  }
  return crc;
}

uint32_t Crc32OfText(const std::wstring& text) {
  uint32_t crc = 0xFFFFFFFFu;
  for (const wchar_t ch : text) {
    crc = Crc32Step(crc, static_cast<uint8_t>(ch & 0xFF));
    crc = Crc32Step(crc, static_cast<uint8_t>((ch >> 8) & 0xFF));
  }
  return crc ^ 0xFFFFFFFFu;
}

// 互斥量名带上自身全路径哈希，同名 exe 放在不同目录时互不影响。
std::wstring BuildInstanceMutexName() {
  std::wstring path = GetOwnImagePath();
  if (!path.empty()) {
    ::CharLowerBuffW(path.data(), static_cast<DWORD>(path.size()));
  }
  wchar_t suffix[16];
  swprintf_s(suffix, L"%08X", Crc32OfText(path));
  return std::wstring(L"Local\\PureMusic.SingleInstance.") + suffix;
}

// 只认同路径 exe 的主窗口，避免误伤其他 Flutter 程序。
bool SameImagePath(const std::wstring& path) {
  const std::wstring own_path = GetOwnImagePath();
  if (own_path.empty() || path.empty()) {
    return false;
  }
  return ::CompareStringOrdinal(
             own_path.c_str(), static_cast<int>(own_path.size()),
             path.c_str(), static_cast<int>(path.size()), TRUE) == CSTR_EQUAL;
}

bool IsAppWindow(HWND window) {
  wchar_t class_name[64];
  if (::GetClassNameW(window, class_name, 64) == 0) {
    return false;
  }
  if (::CompareStringOrdinal(class_name, -1, kMainWindowClassName, -1, TRUE) !=
      CSTR_EQUAL) {
    return false;
  }
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  if (process_id == 0) {
    return false;
  }
  HANDLE process =
      ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (process == nullptr) {
    return false;
  }
  std::wstring image_path(32768, L'\0');
  DWORD image_path_length = static_cast<DWORD>(image_path.size());
  bool matched = false;
  if (::QueryFullProcessImageNameW(process, 0, image_path.data(),
                                   &image_path_length) != FALSE) {
    image_path.resize(image_path_length);
    matched = SameImagePath(image_path);
  }
  ::CloseHandle(process);
  return matched;
}

BOOL CALLBACK FindAppWindowProc(HWND window, LPARAM result) {
  if (!IsAppWindow(window)) {
    return TRUE;
  }
  *reinterpret_cast<HWND*>(result) = window;
  return FALSE;
}

HWND FindExistingWindow() {
  const ULONGLONG deadline = ::GetTickCount64() + kFindWindowTimeoutMs;
  for (;;) {
    HWND window = nullptr;
    ::EnumWindows(FindAppWindowProc, reinterpret_cast<LPARAM>(&window));
    if (window != nullptr) {
      return window;
    }
    if (::GetTickCount64() >= deadline) {
      return nullptr;
    }
    ::Sleep(kFindWindowIntervalMs);
  }
}

// 已有实例：取消最小化并置前台；托盘隐藏时由已有实例的 Dart 侧显示。
bool ActivateExistingInstance() {
  const HWND window = FindExistingWindow();
  if (window == nullptr) {
    return false;
  }
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  if (process_id != 0) {
    ::AllowSetForegroundWindow(process_id);
  }
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  }
  if (::IsWindowVisible(window)) {
    ::SetForegroundWindow(window);
  }
  const UINT message = ::RegisterWindowMessageW(kShowWindowMessageName);
  if (message != 0) {
    ::PostMessageW(window, message, 0, 0);
  }
  return true;
}

#endif  // defined(NDEBUG)

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Debug 构建不参与单实例判定，避免开发时被已安装的 Release 版顶掉。
#if defined(NDEBUG)
  const std::wstring mutex_name = BuildInstanceMutexName();
  g_instance_mutex = ::CreateMutexW(nullptr, FALSE, mutex_name.c_str());
  if (g_instance_mutex == nullptr) {
    AppendRunnerLog(L"SingleInstance|CreateMutexW failed|error=" +
                    std::to_wstring(::GetLastError()));
  } else if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    const bool activated = ActivateExistingInstance();
    ::CloseHandle(g_instance_mutex);
    g_instance_mutex = nullptr;
    if (!activated) {
      AppendRunnerLog(L"SingleInstance|existing window not found");
      ::MessageBoxW(nullptr, L"Pure Music 已在运行，但无法切换到该窗口。",
                    L"Pure Music", MB_OK | MB_ICONWARNING);
      return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
  }
#endif

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // 进程 AUMID 与开始菜单快捷方式保持一致，系统媒体控件才能归到同一应用身份。
  const HRESULT app_id_result =
      ::SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);
  if (FAILED(app_id_result)) {
    std::wstringstream app_id_message;
    app_id_message << L"|AUMID_FAILED|hr=0x" << std::hex
                   << std::uppercase << static_cast<unsigned>(app_id_result)
                   << L"\r\n";
    AppendCrashLog(app_id_message.str());
  }

  const std::wstring exe_dir = GetExecutableDirectory();
  ::SetCurrentDirectoryW(exe_dir.c_str());
  ::SetUnhandledExceptionFilter(UnhandledExceptionLogger);
  const std::wstring dll_dir = exe_dir + L"\\dll";
  const std::wstring bass_dir = dll_dir + L"\\BASS";
  ::SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS |
                             LOAD_LIBRARY_SEARCH_USER_DIRS);
  ::AddDllDirectory(dll_dir.c_str());
  ::AddDllDirectory(bass_dir.c_str());

  flutter::DartProject project(L"data");
  project.set_ui_thread_policy(flutter::UIThreadPolicy::RunOnSeparateThread);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Pure Music", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::SetUnhandledExceptionFilter(UnhandledExceptionLogger);
  int exit_code = RunMessageLoop();
  // 等快捷方式线程收尾，避免写到一半被进程退出切断。
  WaitForStartMenuShortcut();

  ::CoUninitialize();
  return exit_code;
}
