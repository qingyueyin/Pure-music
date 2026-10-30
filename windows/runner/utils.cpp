#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>

namespace {

// 递归创建目录；已存在视为成功。
bool EnsureDirectoryExists(const std::wstring& directory) {
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

std::vector<std::wstring> GetLogDirectoryCandidates() {
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

}  // namespace

std::wstring GetExecutableDirectory() {
  wchar_t module_path[MAX_PATH];
  DWORD length = ::GetModuleFileNameW(nullptr, module_path, MAX_PATH);
  std::wstring path(module_path, length);
  size_t pos = path.find_last_of(L"\\/");
  if (pos != std::wstring::npos) {
    path.resize(pos);
  }
  return path;
}

HANDLE OpenAppLogFile(const wchar_t* file_name) {
  for (const auto& directory : GetLogDirectoryCandidates()) {
    if (!EnsureDirectoryExists(directory)) {
      continue;
    }
    const std::wstring file_path = directory + L"\\" + file_name;
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

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  unsigned int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      -1, nullptr, 0, nullptr, nullptr)
    -1; // remove the trailing null character
  int input_length = (int)wcslen(utf16_string);
  std::string utf8_string;
  if (target_length == 0 || target_length > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}
