#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <iostream>

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

#if defined(_MSC_VER)
static int RunMessageLoop() {
  int exit_code = EXIT_SUCCESS;
  __try {
    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
      __try {
        ::TranslateMessage(&msg);
        ::DispatchMessage(&msg);
      } __except (EXCEPTION_EXECUTE_HANDLER) {
        std::cerr << "SEH exception during message dispatch, continuing..." << std::endl;
      }
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
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

  int exit_code = RunMessageLoop();

  ::CoUninitialize();
  return exit_code;
}
