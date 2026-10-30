#ifndef RUNNER_START_MENU_SHORTCUT_H_
#define RUNNER_START_MENU_SHORTCUT_H_

// 应用身份：进程 AUMID 与开始菜单快捷方式的 PKEY_AppUserModel_ID 必须一致，
// 系统媒体控件(SMTC)才能把媒体会话归到这个应用。
extern const wchar_t kAppUserModelId[];

// 便携版补一条开始菜单快捷方式：后台线程执行，不阻塞启动，失败只写日志。
void EnsureStartMenuShortcutInBackground();

#endif  // RUNNER_START_MENU_SHORTCUT_H_
