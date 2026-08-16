#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

extern "C" {
__declspec(dllexport) unsigned long NvOptimusEnablement = 0x00000001;
__declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 0x00000001;
}

static std::wstring GetExecutableDirectory() {
  wchar_t module_path[MAX_PATH];
  DWORD length = ::GetModuleFileNameW(nullptr, module_path, MAX_PATH);
  std::wstring path(module_path, length);
  size_t pos = path.find_last_of(L"\\/");
  if (pos != std::wstring::npos) {
    path.resize(pos);
  }
  return path;
}

static bool EnsureDirectoryExists(const std::wstring& directory) {
  const DWORD attributes = ::GetFileAttributesW(directory.c_str());
  if (attributes != INVALID_FILE_ATTRIBUTES) {
    return (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  }
  const size_t separator = directory.find_last_of(L"\\/");
  if (separator != std::wstring::npos && separator > 2 &&
      !EnsureDirectoryExists(directory.substr(0, separator))) {
    return false;
  }
  return ::CreateDirectoryW(directory.c_str(), nullptr) != FALSE ||
         ::GetLastError() == ERROR_ALREADY_EXISTS;
}

static std::vector<std::wstring> GetLogDirectoryCandidates() {
  std::vector<std::wstring> candidates;
  candidates.push_back(GetExecutableDirectory() + L"\\logs");
  const DWORD required = ::GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
  if (required > 1) {
    std::wstring local_app_data(required, L'\0');
    const DWORD written = ::GetEnvironmentVariableW(
        L"LOCALAPPDATA", local_app_data.data(), required);
    if (written > 0 && written < required) {
      local_app_data.resize(written);
      candidates.push_back(local_app_data + L"\\pure_music\\logs");
    }
  }
  return candidates;
}

static HANDLE OpenCrashLog() {
  for (const auto& directory : GetLogDirectoryCandidates()) {
    if (!EnsureDirectoryExists(directory)) {
      continue;
    }
    const std::wstring file_path = directory + L"\\crash.log";
    HANDLE file = ::CreateFileW(
        file_path.c_str(), FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
      return file;
    }
  }
  return INVALID_HANDLE_VALUE;
}

static void AppendCrashLog(const std::wstring& message) {
  HANDLE file = OpenCrashLog();
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

  ::CoUninitialize();
  return exit_code;
}
