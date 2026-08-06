---
outline: deep
---

# 下载

提供两种 Windows 发行形态：安装版与便携版。

<DownloadCard />

::: tip 从哪下、下哪个文件？

| 渠道 | 说明 |
|------|------|
| **GitHub Releases** | 推荐；版本与安装包最全 |
| **[Gitee](https://gitee.com/qingyueyin/Pure-music)** | 访问慢时用；镜像常滞后，请核对版本号 |

进入最新版本后：

- 安装版：名称中带 `installer` 的 `.exe`
- 便携版：名称中带 `portable` 的 `.zip`

`Source code` 是源码归档，不是可直接运行的程序。
:::

## 系统要求

- **Windows 10 / 11**（官方支持；Windows 7 / 8 不可用）
- 建议 4GB 及以上内存
- 约 100MB 可用磁盘空间

## 安装版

1. 下载 `*_release_installer.exe` 并运行
2. 按向导完成安装（默认装到 `%LOCALAPPDATA%\Programs\Pure Music`，当前用户，无需管理员）
3. 可选创建桌面快捷方式（默认不勾选）；开始菜单项会创建
4. 可选：从原便携版导入设置与曲库（本机尚无安装版数据时才出现该页）
5. 启动后按欢迎页提示添加音乐文件夹

| 用途 | 路径 |
|------|------|
| 程序 | `%LOCALAPPDATA%\Programs\Pure Music` |
| 数据 | `%LOCALAPPDATA%\pure_music` |

## 便携版

1. 下载发布包并完整解压，不要直接在压缩包内运行
2. 将程序放在有写入权限的目录
3. 运行 `app\pure_music.exe`（或包内说明指向的 exe），按欢迎页提示添加音乐文件夹

配置、曲库与缓存默认写在程序旁的 `data/`。备份或迁移时，请保留整个程序目录。

::: info SmartScreen
首次运行时 Windows 可能弹出 SmartScreen 提示，点击「更多信息」→「仍要运行」即可。
:::

更多见 [安装指南](/guide/install)、[更新日志](/guide/changelog)、[常见问题](/guide/faq)。
