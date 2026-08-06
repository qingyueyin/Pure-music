---
outline: deep
---

# 安装

## 系统要求

| 项目 | 要求 |
|------|------|
| 系统 | Windows 10 或更高版本 |
| 内存 | 建议 4GB 及以上 |
| 磁盘 | 约 100MB 可用空间 |
| 运行库 | 建议安装最新 Visual C++ 可再发行组件 |

## 安装步骤

<div class="pm-steps">
  <div class="pm-step">
    <div class="pm-step-num">1</div>
    <div class="pm-step-body">
      <h3>下载</h3>
      <p>前往 <a href="../download">下载页面</a> 获取名称中带 <code>portable</code> 的最新发布包，不要下载 Source code 源码归档。</p>
    </div>
  </div>
  <div class="pm-step">
    <div class="pm-step-num">2</div>
    <div class="pm-step-body">
      <h3>完整解压</h3>
      <p>将整个发布包解压到有写入权限的目录。当前只有便携版，没有安装程序。</p>
    </div>
  </div>
  <div class="pm-step">
    <div class="pm-step-num">3</div>
    <div class="pm-step-body">
      <h3>首次启动</h3>
      <p>运行 <code>pure_music.exe</code>，按欢迎页提示添加音乐文件夹。大库首次扫描可能需要一段时间。</p>
    </div>
  </div>
</div>

## 便携模式说明

默认启用便携模式：

- 配置、曲库、歌单与缓存都写在程序旁的 `data/`
- 适合 U 盘或绿色部署
- 建议解压到普通文件夹，不要放进需要管理员权限才能写入的目录

::: warning 不要只复制 exe
运行时还需要同目录下的 DLL、`dll/` 和 `desktop_lyric/`。移动或备份时请保留整个程序目录。
:::

## 更新版本

1. 完全退出旧版本
2. 备份旧目录中的 `data/`
3. 将新版本解压到一个新目录
4. 把旧的 `data/` 复制到新程序目录，再启动确认

只迁移 `data/`，不要用旧版 `dll/` 或其它运行文件覆盖新版本。确认新版本正常后再删除旧目录。

## SmartScreen 与杀软

::: info 首次运行提示
Windows 可能弹出 SmartScreen。点击「更多信息」→「仍要运行」即可。
:::

部分杀软会误报。可将程序目录加入白名单。

## 从源码构建

源码不是发布版程序。开发环境、首次运行和打包方式见 [构建指南](/dev/build)。
