#include "start_menu_shortcut.h"

#include <objbase.h>
#include <propkey.h>
#include <propvarutil.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <windows.h>
#include <wrl/client.h>

#include <string>
#include <thread>
#include <vector>

#include "utils.h"

const wchar_t kAppUserModelId[] = L"PureMusic.Player.Desktop";

namespace {

using Microsoft::WRL::ComPtr;

// 开始菜单 Programs 下的目录层级有限，3 层足够覆盖厂商子文件夹。
constexpr int kMaxScanDepth = 3;
constexpr wchar_t kShortcutName[] = L"Pure Music";
constexpr wchar_t kFallbackShortcutName[] = L"Pure Music (Portable)";

// 追加一行到 startup.log；日志不可写时静默放弃。
void AppendLog(const std::wstring& message) {
  const HANDLE file = OpenAppLogFile(L"startup.log");
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  const std::string line = Utf8FromUtf16(message.c_str());
  if (!line.empty()) {
    DWORD written = 0;
    ::WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written,
                nullptr);
    ::WriteFile(file, "\r\n", 2, &written, nullptr);
  }
  ::CloseHandle(file);
}

std::wstring CurrentExecutablePath() {
  wchar_t buffer[32768];
  const DWORD length = ::GetModuleFileNameW(nullptr, buffer, 32768);
  if (length == 0 || length >= 32768) {
    return std::wstring();
  }
  return std::wstring(buffer, length);
}

// 展开 8.3 短名，避免同一路径两种写法被当成不同目标。
std::wstring LongPath(const std::wstring& path) {
  wchar_t buffer[32768];
  const DWORD length = ::GetLongPathNameW(path.c_str(), buffer, 32768);
  if (length == 0 || length >= 32768) {
    return path;
  }
  return std::wstring(buffer, length);
}

bool SamePath(const std::wstring& left, const std::wstring& right) {
  if (left.empty() || right.empty()) {
    return false;
  }
  return ::CompareStringOrdinal(LongPath(left).c_str(), -1,
                                LongPath(right).c_str(), -1, TRUE) ==
         CSTR_EQUAL;
}

// 递归收集 Programs 目录下的 .lnk。
void CollectShortcutFiles(const std::wstring& directory, int depth,
                          std::vector<std::wstring>* files) {
  if (depth > kMaxScanDepth) {
    return;
  }
  WIN32_FIND_DATAW data;
  const HANDLE find = ::FindFirstFileW((directory + L"\\*").c_str(), &data);
  if (find == INVALID_HANDLE_VALUE) {
    return;
  }
  do {
    if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
      if (data.cFileName[0] == L'.' &&
          (data.cFileName[1] == L'\0' ||
           (data.cFileName[1] == L'.' && data.cFileName[2] == L'\0'))) {
        continue;
      }
      CollectShortcutFiles(directory + L"\\" + data.cFileName, depth + 1,
                           files);
      continue;
    }
    const size_t length = static_cast<size_t>(::lstrlenW(data.cFileName));
    if (length > 4 && ::CompareStringOrdinal(data.cFileName + length - 4, 4,
                                             L".lnk", 4, TRUE) == CSTR_EQUAL) {
      files->push_back(directory + L"\\" + data.cFileName);
    }
  } while (::FindNextFileW(find, &data));
  ::FindClose(find);
}

ComPtr<IShellLinkW> LoadShortcut(const std::wstring& path, DWORD mode) {
  ComPtr<IShellLinkW> link;
  if (FAILED(::CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&link)))) {
    return nullptr;
  }
  ComPtr<IPersistFile> file;
  if (FAILED(link.As(&file)) || FAILED(file->Load(path.c_str(), mode))) {
    return nullptr;
  }
  return link;
}

std::wstring ShortcutTarget(IShellLinkW* link) {
  wchar_t target[32768];
  WIN32_FIND_DATAW data = {};
  if (FAILED(link->GetPath(target, 32768, &data, SLGP_RAWPATH))) {
    return std::wstring();
  }
  return target;
}

bool CreateShortcut(const std::wstring& path, const std::wstring& exe,
                    const std::wstring& working_directory) {
  ComPtr<IShellLinkW> link;
  if (FAILED(::CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&link)))) {
    return false;
  }
  if (FAILED(link->SetPath(exe.c_str()))) {
    return false;
  }
  link->SetWorkingDirectory(working_directory.c_str());
  link->SetDescription(L"Pure Music");
  link->SetIconLocation(exe.c_str(), 0);
  link->SetShowCmd(SW_SHOWNORMAL);
  ComPtr<IPropertyStore> store;
  ComPtr<IPersistFile> file;
  if (FAILED(link.As(&store)) || FAILED(link.As(&file))) {
    return false;
  }
  PROPVARIANT value;
  if (FAILED(::InitPropVariantFromString(kAppUserModelId, &value))) {
    return false;
  }
  const bool app_id_saved =
      SUCCEEDED(store->SetValue(PKEY_AppUserModel_ID, value)) &&
      SUCCEEDED(store->Commit());
  ::PropVariantClear(&value);
  return app_id_saved && SUCCEEDED(file->Save(path.c_str(), TRUE));
}

void EnsureShortcutInApartment() {
  const std::wstring exe = CurrentExecutablePath();
  if (exe.empty()) {
    AppendLog(L"shortcut: executable path unavailable");
    return;
  }
  PWSTR programs = nullptr;
  if (FAILED(::SHGetKnownFolderPath(FOLDERID_Programs, KF_FLAG_DEFAULT, nullptr,
                                    &programs))) {
    AppendLog(L"shortcut: start menu folder unavailable");
    return;
  }
  const std::wstring programs_dir(programs);
  ::CoTaskMemFree(programs);

  std::vector<std::wstring> files;
  CollectShortcutFiles(programs_dir, 0, &files);
  for (const auto& path : files) {
    ComPtr<IShellLinkW> link = LoadShortcut(path, STGM_READ);
    if (!link || !SamePath(ShortcutTarget(link.Get()), exe)) {
      continue;
    }
    AppendLog(L"shortcut: existing - " + path);
    return;
  }

  // 没有指向当前 exe 的快捷方式（便携版）：补一条，名称被别的目标占用时换备用名。
  std::wstring shortcut_path = programs_dir + L"\\" + kShortcutName + L".lnk";
  if (::GetFileAttributesW(shortcut_path.c_str()) != INVALID_FILE_ATTRIBUTES) {
    shortcut_path =
        programs_dir + L"\\" + kFallbackShortcutName + L".lnk";
  }
  if (::GetFileAttributesW(shortcut_path.c_str()) != INVALID_FILE_ATTRIBUTES) {
    AppendLog(L"shortcut: name taken, skipped");
    return;
  }
  const size_t separator = exe.find_last_of(L"\\/");
  const std::wstring working_directory =
      separator == std::wstring::npos ? exe : exe.substr(0, separator);
  if (CreateShortcut(shortcut_path, exe, working_directory)) {
    AppendLog(L"shortcut: created - " + shortcut_path);
  } else {
    AppendLog(L"shortcut: create failed - " + shortcut_path);
  }
}

void EnsureShortcutOnWorkerThread() {
  const HRESULT initialized = ::CoInitializeEx(
      nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  if (FAILED(initialized) && initialized != RPC_E_CHANGED_MODE) {
    AppendLog(L"shortcut: com init failed");
    return;
  }
  EnsureShortcutInApartment();
  if (SUCCEEDED(initialized)) {
    ::CoUninitialize();
  }
}

}  // namespace

void EnsureStartMenuShortcutInBackground() {
  std::thread(EnsureShortcutOnWorkerThread).detach();
}
