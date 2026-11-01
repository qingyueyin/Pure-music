#include "start_menu_shortcut.h"

#include <objbase.h>
#include <propkey.h>
#include <propvarutil.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <stdio.h>
#include <windows.h>
#include <wrl/client.h>

#include <string>
#include <vector>

#include "utils.h"

const wchar_t kAppUserModelId[] = L"PureMusic.Player.Desktop";

namespace {

using Microsoft::WRL::ComPtr;

// Programs 根目录算第 1 层，最多下探 3 层。
constexpr int kMaxScanDepth = 3;
constexpr DWORD kMaxPathLength = 32768;
constexpr wchar_t kShortcutName[] = L"Pure Music";
constexpr wchar_t kFallbackShortcutName[] = L"Pure Music (Portable)";
constexpr wchar_t kShortcutSuffix[] = L".lnk";
// Inno Setup 卸载项：安装版用它判断身份，快捷方式主名只归安装版用。
constexpr wchar_t kUninstallKeyPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"
    L"{42C4470A-72BE-49A0-B32F-DF7A941DD48C}_is1";

// 后台线程句柄：退出前 join，避免写到一半被进程退出切断。
HANDLE g_shortcut_thread = nullptr;

// 追加一行到 startup.log；日志不可写时静默放弃。整行一次写出，避免与其它进程交错。
void AppendLog(const std::wstring& message) {
  if (message.empty()) {
    return;
  }
  const HANDLE file = OpenAppLogFile(L"startup.log");
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  const std::string line = Utf8FromUtf16(message.c_str()) + "\r\n";
  DWORD written = 0;
  ::WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written,
              nullptr);
  ::CloseHandle(file);
}

std::wstring CurrentExecutablePath() {
  wchar_t buffer[kMaxPathLength];
  const DWORD length = ::GetModuleFileNameW(nullptr, buffer, kMaxPathLength);
  if (length == 0 || length >= kMaxPathLength) {
    return std::wstring();
  }
  return std::wstring(buffer, length);
}

std::wstring ParentDirectory(const std::wstring& path) {
  const size_t separator = path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    return std::wstring();
  }
  return path.substr(0, separator);
}

std::wstring FileName(const std::wstring& path) {
  const size_t separator = path.find_last_of(L"\\/");
  return separator == std::wstring::npos ? path : path.substr(separator + 1);
}

// 展开 %VAR% 形式的目标路径，旧安装器写的就是这种未展开形式。
std::wstring ExpandPath(const std::wstring& path) {
  const DWORD needed = ::ExpandEnvironmentStringsW(path.c_str(), nullptr, 0);
  if (needed == 0 || needed > kMaxPathLength) {
    return path;
  }
  std::wstring expanded(needed, L'\0');
  const DWORD written =
      ::ExpandEnvironmentStringsW(path.c_str(), expanded.data(), needed);
  if (written == 0 || written > needed) {
    return path;
  }
  expanded.resize(written - 1);
  return expanded;
}

// 展开 8.3 短名，避免同一路径两种写法被当成不同目标。缓冲在堆上，不占栈。
std::wstring LongPath(const std::wstring& path) {
  std::wstring buffer(kMaxPathLength, L'\0');
  const DWORD length =
      ::GetLongPathNameW(path.c_str(), buffer.data(), kMaxPathLength);
  if (length == 0 || length >= kMaxPathLength) {
    return path;
  }
  buffer.resize(length);
  return buffer;
}

// 目标是否就是当前 exe。self_long 预先算好，候选路径每条只展开一次。
bool SameAsSelf(const std::wstring& candidate, const std::wstring& self,
                const std::wstring& self_long) {
  if (candidate.empty()) {
    return false;
  }
  if (::CompareStringOrdinal(candidate.c_str(), -1, self.c_str(), -1, TRUE) ==
      CSTR_EQUAL) {
    return true;
  }
  return ::CompareStringOrdinal(LongPath(candidate).c_str(), -1,
                                self_long.c_str(), -1, TRUE) == CSTR_EQUAL;
}

// 只认这两个受控名字，别动别人的条目。
bool MatchesControlledName(const std::wstring& path) {
  std::wstring name = FileName(path);
  const size_t length = name.size();
  if (length <= 4 ||
      ::CompareStringOrdinal(name.c_str() + length - 4, 4, kShortcutSuffix, 4,
                             TRUE) != CSTR_EQUAL) {
    return false;
  }
  name.resize(length - 4);
  return ::CompareStringOrdinal(name.c_str(), -1, kShortcutName, -1, TRUE) ==
             CSTR_EQUAL ||
         ::CompareStringOrdinal(name.c_str(), -1, kFallbackShortcutName, -1,
                                TRUE) == CSTR_EQUAL;
}

// 受控名字的条目坏了（目标为空）或指向已不存在的文件：开始菜单里的陈旧入口。
bool IsStaleShortcut(const std::wstring& path, const std::wstring& target) {
  if (!MatchesControlledName(path)) {
    return false;
  }
  return target.empty() ||
         ::GetFileAttributesW(target.c_str()) == INVALID_FILE_ATTRIBUTES;
}

void DeleteShortcut(const std::wstring& path) {
  if (::DeleteFileW(path.c_str()) != 0) {
    AppendLog(L"shortcut: stale removed - " + path);
  } else {
    AppendLog(L"shortcut: stale delete failed - " + path);
  }
}

// 开发构建（build\windows\...）不往开始菜单里塞入口。
bool IsDevelopmentBuild(const std::wstring& exe) {
  std::wstring lower = exe;
  ::CharLowerBuffW(lower.data(), static_cast<DWORD>(lower.size()));
  return lower.find(L"\\build\\windows\\") != std::wstring::npos;
}

// 递归收集 Programs 目录下的 .lnk。
void CollectShortcutFiles(const std::wstring& directory, int depth,
                          std::vector<std::wstring>* files) {
  if (depth >= kMaxScanDepth) {
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
                                             kShortcutSuffix, 4, TRUE) ==
                          CSTR_EQUAL) {
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
  wchar_t target[kMaxPathLength];
  WIN32_FIND_DATAW data = {};
  if (FAILED(link->GetPath(target, kMaxPathLength, &data, SLGP_RAWPATH))) {
    return std::wstring();
  }
  return ExpandPath(target);
}

bool WriteAppUserModelId(IPropertyStore* store) {
  PROPVARIANT value;
  if (FAILED(::InitPropVariantFromString(kAppUserModelId, &value))) {
    return false;
  }
  const bool saved = SUCCEEDED(store->SetValue(PKEY_AppUserModel_ID, value)) &&
                     SUCCEEDED(store->Commit());
  ::PropVariantClear(&value);
  return saved;
}

bool HasExpectedAppUserModelId(IPropertyStore* store) {
  PROPVARIANT current;
  ::PropVariantInit(&current);
  bool matches = false;
  if (SUCCEEDED(store->GetValue(PKEY_AppUserModel_ID, &current)) &&
      current.vt == VT_LPWSTR && current.pwszVal != nullptr) {
    matches = ::CompareStringOrdinal(current.pwszVal, -1, kAppUserModelId, -1,
                                     TRUE) == CSTR_EQUAL;
  }
  ::PropVariantClear(&current);
  return matches;
}

// 先写同目录临时文件再原子替换，进程中途退出不会留下半截 .lnk。
bool SaveShortcutAtomically(IPersistFile* file, const std::wstring& path) {
  const std::wstring temporary = path + L".tmp";
  if (FAILED(file->Save(temporary.c_str(), TRUE))) {
    ::DeleteFileW(temporary.c_str());
    return false;
  }
  if (::MoveFileExW(temporary.c_str(), path.c_str(),
                    MOVEFILE_REPLACE_EXISTING) == 0) {
    ::DeleteFileW(temporary.c_str());
    return false;
  }
  return true;
}

// 指向本 exe 的旧快捷方式（如安装版建的）缺 AUMID 时补写，只改这一条。
// IPropertyStore::Commit 不落盘，改完仍需 Save。
void EnsureShortcutAppId(const std::wstring& path) {
  ComPtr<IShellLinkW> link = LoadShortcut(path, STGM_READWRITE);
  if (!link) {
    AppendLog(L"shortcut: existing, open for write failed - " + path);
    return;
  }
  ComPtr<IPropertyStore> store;
  ComPtr<IPersistFile> file;
  if (FAILED(link.As(&store)) || FAILED(link.As(&file))) {
    AppendLog(L"shortcut: existing, interfaces unavailable - " + path);
    return;
  }
  if (HasExpectedAppUserModelId(store.Get())) {
    AppendLog(L"shortcut: existing - " + path);
    return;
  }
  const bool saved = WriteAppUserModelId(store.Get()) &&
                     SaveShortcutAtomically(file.Get(), path);
  AppendLog(saved ? L"shortcut: appid fixed - " + path
                  : L"shortcut: appid write failed - " + path);
}

enum class ShortcutProbe { kOther, kSelf };

// 检查一条 .lnk：目标是本 exe 返回 kSelf；受控名字的陈旧或写坏条目顺手删掉。
ShortcutProbe ProbeShortcut(const std::wstring& path, const std::wstring& exe,
                            const std::wstring& exe_long) {
  ComPtr<IShellLinkW> link = LoadShortcut(path, STGM_READ);
  if (!link) {
    if (MatchesControlledName(path)) {
      DeleteShortcut(path);
    }
    return ShortcutProbe::kOther;
  }
  const std::wstring target = ShortcutTarget(link.Get());
  if (SameAsSelf(target, exe, exe_long)) {
    return ShortcutProbe::kSelf;
  }
  if (IsStaleShortcut(path, target)) {
    DeleteShortcut(path);
  }
  return ShortcutProbe::kOther;
}

// 快捷方式内容：目标、工作目录、AUMID。
bool BuildShortcut(IShellLinkW* link, const std::wstring& exe,
                   const std::wstring& working_directory) {
  if (FAILED(link->SetPath(exe.c_str()))) {
    return false;
  }
  link->SetWorkingDirectory(working_directory.c_str());
  link->SetDescription(L"Pure Music");
  link->SetIconLocation(exe.c_str(), 0);
  link->SetShowCmd(SW_SHOWNORMAL);
  ComPtr<IPropertyStore> store;
  if (FAILED(link->QueryInterface(IID_PPV_ARGS(&store)))) {
    return false;
  }
  return WriteAppUserModelId(store.Get());
}

bool CreateShortcut(const std::wstring& path, const std::wstring& exe,
                    const std::wstring& working_directory) {
  ComPtr<IShellLinkW> link;
  if (FAILED(::CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&link)))) {
    return false;
  }
  if (!BuildShortcut(link.Get(), exe, working_directory)) {
    return false;
  }
  ComPtr<IPersistFile> file;
  if (FAILED(link.As(&file))) {
    return false;
  }
  return SaveShortcutAtomically(file.Get(), path);
}

// exe 在安装版注册表卸载项的 InstallLocation 里就算安装版；
// 查不到注册表或目录对不上都按便携版处理，主名留给自己。
bool IsInstalledBuild(const std::wstring& exe) {
  wchar_t location[kMaxPathLength] = {};
  DWORD size = sizeof(location);
  const LSTATUS status = ::RegGetValueW(
      HKEY_CURRENT_USER, kUninstallKeyPath, L"InstallLocation",
      RRF_RT_REG_SZ, nullptr, location, &size);
  if (status != ERROR_SUCCESS || location[0] == L'\0') {
    return false;
  }
  const std::wstring exe_long = LongPath(exe);
  std::wstring install_dir(location);
  while (!install_dir.empty() &&
         (install_dir.back() == L'\\' || install_dir.back() == L'/')) {
    install_dir.pop_back();
  }
  if (install_dir.empty()) {
    return false;
  }
  const std::wstring prefix = install_dir + L'\\';
  return ::CompareStringOrdinal(
             exe_long.substr(0, prefix.size()).c_str(),
             static_cast<int>(prefix.size()), prefix.c_str(),
             static_cast<int>(prefix.size()), TRUE) == CSTR_EQUAL;
}

// 便携版固定用「Pure Music (Portable)」，名字被占就覆盖；
// 安装版用主名。不再落到带目录名/哈希的长尾巴名字。
std::wstring ChooseShortcutPath(const std::wstring& programs_dir,
                                const std::wstring& exe) {
  const wchar_t* name = IsInstalledBuild(exe) ? kShortcutName
                                              : kFallbackShortcutName;
  return std::wstring(programs_dir) + L"\\" + name + kShortcutSuffix;
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
  const std::wstring exe_long = LongPath(exe);

  // 先只查两个固定候选，命中就不必全量扫描。
  std::wstring existing;
  const std::wstring fixed_names[] = {kShortcutName, kFallbackShortcutName};
  for (const auto& name : fixed_names) {
    const std::wstring path = programs_dir + L"\\" + name + kShortcutSuffix;
    if (ProbeShortcut(path, exe, exe_long) == ShortcutProbe::kSelf &&
        existing.empty()) {
      existing = path;
    }
  }
  if (existing.empty()) {
    // 走到这里说明固定候选没命中，顺手把整棵树里的陈旧条目清掉。
    std::vector<std::wstring> files;
    CollectShortcutFiles(programs_dir, 0, &files);
    for (const auto& path : files) {
      if (ProbeShortcut(path, exe, exe_long) == ShortcutProbe::kSelf &&
          existing.empty()) {
        existing = path;
      }
    }
  }
  if (!existing.empty()) {
    EnsureShortcutAppId(existing);
    return;
  }

  if (IsDevelopmentBuild(exe)) {
    AppendLog(L"shortcut: development build, skipped");
    return;
  }
  const std::wstring path = ChooseShortcutPath(programs_dir, exe);
  if (path.empty()) {
    AppendLog(L"shortcut: no free name in start menu");
    return;
  }
  if (CreateShortcut(path, exe, ParentDirectory(exe))) {
    AppendLog(L"shortcut: created - " + path);
  } else {
    AppendLog(L"shortcut: create failed - " + path);
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

DWORD WINAPI ShortcutThreadProc(void*) {
  EnsureShortcutOnWorkerThread();
  return 0;
}

}  // namespace

void EnsureStartMenuShortcutInBackground() {
  if (g_shortcut_thread != nullptr) {
    return;
  }
  // std::thread 在 _HAS_EXCEPTIONS=0 下构造失败会 terminate，改用 CreateThread。
  g_shortcut_thread =
      ::CreateThread(nullptr, 0, ShortcutThreadProc, nullptr, 0, nullptr);
  if (g_shortcut_thread == nullptr) {
    AppendLog(L"shortcut: thread create failed");
  }
}

void WaitForStartMenuShortcut() {
  if (g_shortcut_thread == nullptr) {
    return;
  }
  ::WaitForSingleObject(g_shortcut_thread, INFINITE);
  ::CloseHandle(g_shortcut_thread);
  g_shortcut_thread = nullptr;
}
