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
      <p>前往 <a href="../download">下载页面</a> 或 <a href="https://github.com/qingyueyin/Pure-music/releases" target="_blank" rel="noreferrer">GitHub Releases</a> 获取最新版本。</p>
    </div>
  </div>
  <div class="pm-step">
    <div class="pm-step-num">2</div>
    <div class="pm-step-body">
      <h3>解压 / 安装</h3>
      <p>按发布包说明解压或运行安装程序。默认便携模式：配置与曲库写在程序旁的 <code>data/</code> 目录。</p>
    </div>
  </div>
  <div class="pm-step">
    <div class="pm-step-num">3</div>
    <div class="pm-step-body">
      <h3>首次启动</h3>
      <p>按欢迎页提示添加音乐文件夹。大库首次扫描可能需要一段时间。</p>
    </div>
  </div>
</div>

## 便携模式说明

默认启用便携模式：

- 配置、曲库 SQLite、缓存写在 exe 旁 `data/`
- 适合 U 盘或绿色部署
- 请保证程序目录可写；否则可能无法保存设置与索引

## SmartScreen 与杀软

::: info 首次运行提示
Windows 可能弹出 SmartScreen。点击「更多信息」→「仍要运行」即可。
:::

部分杀软会误报。可将程序目录加入白名单。

## 从源码构建

适合开发者或想跟最新代码的用户。详见 [构建指南](/dev/build)。

```bash
flutter pub get
flutter build windows --release
```

产物在 `build/windows/x64/runner/Release/`。
