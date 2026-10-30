#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <windows.h>
#include <shobjidl.h>

#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "start_menu_shortcut.h"
#include "utils.h"

// 不强制占用独立显卡。播放器留在系统默认显卡上，避免显存一直堆在高性能卡里。

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

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // 进程 AUMID 与开始菜单快捷方式保持一致，系统媒体控件才能归到同一应用身份。
  ::SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);

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

  // 便携版首次运行补一条开始菜单快捷方式，后台执行不阻塞首屏。
  EnsureStartMenuShortcutInBackground();

  ::SetUnhandledExceptionFilter(UnhandledExceptionLogger);
  int exit_code = RunMessageLoop();

  ::CoUninitialize();
  return exit_code;
}
