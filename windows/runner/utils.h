#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <windows.h>

#include <string>
#include <vector>

// 当前进程 exe 所在目录，不带尾随反斜杠。
std::wstring GetExecutableDirectory();

// 打开应用日志目录下的日志文件用于追加写（必要时创建目录）。
// 依次尝试 exe\logs 与 %LOCALAPPDATA%\pure_music\logs，失败返回 INVALID_HANDLE_VALUE。
HANDLE OpenAppLogFile(const wchar_t* file_name);

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

// 往 logs/crash.log 追加一条带时间戳的运行日志。
void AppendRunnerLog(const std::wstring& detail);

#endif  // RUNNER_UTILS_H_
