---
outline: deep
---

# 安装

## 系统要求

| 项目 | 要求 |
|------|------|
| 系统 | **Windows 10 / 11**（官方支持范围） |
| 内存 | 建议 4GB 及以上 |
| 磁盘 | 约 100MB 可用空间 |
| 运行库 | 建议安装最新 Visual C++ 可再发行组件 |

Windows 7 / 8 等更旧系统**不在支持范围**。本软件基于 Flutter 桌面端，官方工具链本身就不覆盖 Win7/8，一般无法安装或无法稳定运行；请使用 Windows 10 或 11。

## 选择发行形态

| 形态 | 适合谁 | 程序位置 | 数据位置 |
|------|--------|----------|----------|
| 安装版 | 固定本机使用，需要开始菜单 / 可选桌面快捷方式 | 默认 `%LOCALAPPDATA%\Programs\Pure Music` | `%LOCALAPPDATA%\pure_music` |
| 便携版 | U 盘、绿色部署、整目录带走 | 解压目录内 `app\` | 程序旁 `data/` |

两者功能一致。从 [下载页](/download) 获取对应文件：安装版带 `installer`，便携版带 `portable`。不要下载 Source code 源码归档。

优先用 **GitHub Releases**。访问慢可到 [Gitee](https://gitee.com/qingyueyin/Pure-music) 镜像，但那边自动同步往往很慢，**版本可能暂时对不齐**，以 GitHub / 本站更新日志为准更稳妥。

::: tip 程序目录 ≠ 数据目录
安装版可执行文件在 `Programs\Pure Music`，设置与曲库在 `pure_music`。备份用户数据时拷贝数据目录即可，不必备份整个安装目录。
:::

## 安装版步骤

<div class="pm-steps">
  <div class="pm-step">
    <div class="pm-step-num">1</div>
    <div class="pm-step-body">
      <h3>运行安装程序</h3>
      <p>下载名称中带 <code>installer</code> 的 <code>.exe</code> 并运行。默认安装到当前用户目录（<code>%LOCALAPPDATA%\Programs\Pure Music</code>），无需管理员权限。桌面快捷方式默认不勾选，可在向导任务页勾选。</p>
    </div>
  </div>
  <div class="pm-step">
    <div class="pm-step-num">2</div>
    <div class="pm-step-body">
      <h3>可选：导入便携版数据</h3>
      <p>若本机<strong>还没有</strong>安装版用户数据，可在向导中勾选导入，并选择包含 <code>pure_music.exe</code> 的原便携目录。只会迁移设置、曲库、歌单与歌词来源记录，不改动原文件。</p>
      <p>若 <code>%LOCALAPPDATA%\pure_music</code> 已有内容，导入页会跳过，避免覆盖。导入前请先关闭便携版进程；目标数据目录须为空。</p>
    </div>
  </div>
  <div class="pm-step">
    <div class="pm-step-num">3</div>
    <div class="pm-step-body">
      <h3>首次启动</h3>
      <p>从开始菜单或桌面快捷方式启动，按欢迎页提示添加音乐文件夹。大库首次扫描可能需要一段时间。</p>
    </div>
  </div>
</div>

## 便携版步骤

<div class="pm-steps">
  <div class="pm-step">
    <div class="pm-step-num">1</div>
    <div class="pm-step-body">
      <h3>下载并完整解压</h3>
      <p>获取名称中带 <code>portable</code> 的发布包，解压到有写入权限的目录，不要在压缩包内直接运行。</p>
    </div>
  </div>
  <div class="pm-step">
    <div class="pm-step-num">2</div>
    <div class="pm-step-body">
      <h3>运行程序</h3>
      <p>进入包内 <code>app</code> 目录，运行 <code>pure_music.exe</code>。按欢迎页提示添加音乐文件夹。</p>
    </div>
  </div>
</div>

::: warning 不要只复制 exe
运行时还需要同目录下的 DLL、`dll/` 和 `desktop_lyric/`。移动或备份时请保留整个程序目录。
:::

## 数据位置

| 形态 | 路径 |
|------|------|
| 安装版 · 程序 | `%LOCALAPPDATA%\Programs\Pure Music` |
| 安装版 · 数据 | `%LOCALAPPDATA%\pure_music`（通常为 `C:\Users\<用户>\AppData\Local\pure_music`） |
| 便携版 | 程序旁 `data/`（配置、曲库、歌单与缓存） |

备份或换机时：安装版拷贝数据目录；便携版拷贝整个程序目录（含 `data/`）。

## 更新版本

### 安装版

1. 完全退出旧版本
2. 运行新版安装程序覆盖安装
3. 用户数据在 `%LOCALAPPDATA%\pure_music`，一般会保留

### 便携版

1. 完全退出旧版本
2. 备份旧目录中的 `data/`
3. 将新版本解压到一个新目录
4. 把旧的 `data/` 复制到新程序目录，或运行包根目录的 `upgrade_from_previous.ps1` 迁移
5. 启动确认后再删除旧目录

只迁移用户数据，不要用旧版 `dll/` 或其它运行文件覆盖新版本。

### 便携 → 安装

用安装版向导的「导入便携版数据」，或手动把便携 `data/` 中的用户文件迁到 `%LOCALAPPDATA%\pure_music`（目标目录应为空，避免覆盖）。

安装成功但导入失败时：原便携数据不会被修改，可稍后手动迁移或清空目标目录后重装并勾选导入。

## 卸载

### 安装版

1. 完全退出 Pure Music
2. 在 Windows「已安装的应用」或「控制面板 → 程序和功能」中卸载 Pure Music  
   （也可运行安装目录下的卸载程序）
3. 卸载结束时会询问是否**同时删除用户数据**（设置、曲库索引、歌单、歌词来源与缓存）  
   - 选「是」：删除 `%LOCALAPPDATA%\pure_music`  
   - 选「否」（默认倾向）：保留数据，便于以后重装恢复

程序文件在 `%LOCALAPPDATA%\Programs\Pure Music`，用户数据在 `%LOCALAPPDATA%\pure_music`，二者分开。

### 便携版

退出后删除整个程序目录即可。需要保留配置时先备份 `data/`。

## SmartScreen 与杀软

::: info 首次运行提示
Windows 可能弹出 SmartScreen。点击「更多信息」→「仍要运行」即可。
:::

部分杀软会误报。可将程序目录（安装版为安装目录）加入白名单。

## 从源码构建

源码不是发布版程序。开发环境、首次运行和打包方式见 [构建指南](/dev/build)。
