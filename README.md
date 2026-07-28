# Pure Music

<p align="center">
  <img src="app_icon.png" width="80" height="80" alt="Pure Music Logo">
</p>

<p align="center">
  专为 Windows 打造的本地音乐播放器
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Windows-blue?style=flat-square" alt="Platform">  
  <img src="https://badgen.net/github/release/qingyueyin/Pure-music?icon=github" alt="Version">
  <img src="https://img.shields.io/github/downloads/qingyueyin/Pure-music/total?style=flat-square" alt="Downloads">
  <img src="https://img.shields.io/badge/License-GPL--3.0-green?style=flat-square" alt="License">
</p>

一款纯粹的本地音乐播放器。

---

## 截图预览

<details>
<summary>查看全部截图</summary>

**深色模式**

<img src="screenshot/深色主页.png" width="400" alt="深色主页">
<img src="screenshot/深色专辑页.png" width="400" alt="深色专辑页">
<img src="screenshot/深色横屏响应式布局.png" width="400" alt="深色横屏">
<img src="screenshot/深色竖屏响应式布局.png" width="225" alt="深色竖屏">
<img src="screenshot/横屏沉浸模式+歌词行模糊.png" width="400" alt="横屏沉浸">
<img src="screenshot/竖屏模式.png" width="225" alt="竖屏模式">
<img src="screenshot/竖屏模式2.png" width="225" alt="竖屏模式2">
<img src="screenshot/竖屏沉浸模式+歌词行模糊.png" width="225" alt="竖屏沉浸">

**浅色模式**

<img src="screenshot/浅色主页.png" width="400" alt="浅色主页">
<img src="screenshot/浅色专辑页.png" width="400" alt="浅色专辑页">
<img src="screenshot/浅色横屏模式.png" width="400" alt="浅色横屏">
<img src="screenshot/浅色横屏+歌词行模糊.png" width="400" alt="浅色横屏模糊">
<img src="screenshot/浅色横屏2.png" width="400" alt="浅色横屏2">
<img src="screenshot/浅色歌手页.png" width="400" alt="浅色歌手页">

**封面模糊**

<img src="screenshot/深色封面模糊.png" width="400" alt="深色封面模糊">
<img src="screenshot/浅色封面模糊.png" width="400" alt="浅色封面模糊">

**桌面歌词**

<img src="screenshot/桌面歌词.png" width="400" alt="桌面歌词">
<img src="screenshot/桌面歌词隐藏.png" width="400" alt="桌面歌词隐藏">

</details>

---

## 特色

**🎨 沉浸式界面** — 封面取色驱动 Material You 主题，动态/静态背景，辉光缩放

**📝 多格式歌词** — 逐字歌词支持，多种歌词格式支持：YRC/QRC/KRC/TTML，多源在线搜索，注音与翻译并排

**🎛️ 专业音频** — 10 段均衡器（80Hz~16kHz），Eq 导入，音调/速度调节，ReplayGain 自动增益

**📐 响应式布局** — 三档自适应，竖屏与横屏自动适配

---

## 快速开始

<details>
<summary>构建流程</summary>

```bash
flutter pub get
flutter run

# 构建 Release
flutter build windows --release

# 修改 Rust 后重新生成 FRB 绑定
# 需先安装: cargo install flutter_rust_bridge_codegen
flutter_rust_bridge_codegen generate
```

</details>

<details>
<summary>功能总览</summary>

**播放** — WASAPI 独占模式 · 淡入淡出 · 半音音调 · 速度调节 · 会话恢复
**音频** — 10 段均衡器  · Eq 导入 · 音频增益 · ReplayGain · DSP 音量
**主题** — Material You 动态取色 · 封面自动取色 · 系统主题同步 · 动态/静态背景 · 莫奈取色 · 自定义字体 · 沉浸模式
**歌词** — 在线源歌词· 逐字歌词 · 逐行/逐字模式 · 注音/翻译 · 简繁转换 · 桌面歌词 · 间奏动画 · 音频律动
**音乐库** — 按艺术家/专辑/文件夹/歌曲浏览 · 播放列表 · SQLite 持久化 · 封面缓存
**布局** — 响应式三档布局 · 竖屏/横屏自适应
**系统** — SMTC · 全局快捷键 · 单实例 · 窗口记忆 · 日志导出 · 数据库

**快捷键：** `Esc` 关闭/返回 · `Space` 暂停/播放 · `Ctrl + ←/→` 切歌 · `Ctrl + ↑/↓` 音量 · `F1` 沉浸模式

</details>


---
## 致谢

<details>
<summary>开源库</summary>

图标：[Silicon7921](https://ray.so/icon) · 字体：[MiSans VF](https://hyperos.mi.com/font/zh/) 

BASS · flutter_rust_bridge · dio · lofty · provider · go_router · window_manager · hotkey_manager · flutter_single_instance · flutter_animate · mesh_gradient · palette_generator · material_symbols_icons · sqlite3 · flex_color_picker · file_picker · flutter_volume_controller · pinyin · fl_charset · logger · xml

</details>

<details>
<summary>参考项目</summary>

[coriander_player](https://github.com/Ferry-200/coriander_player) · [ZeroBit-Player](https://github.com/Empty-57/ZeroBit-Player) · [Lyrico](https://github.com/Replica0110/Lyrico) · [original-sound-hq-player](https://github.com/Johnwikix/original-sound-hq-player) · [SPlayer](https://github.com/imsyy/SPlayer) · [Unilyric](https://github.com/apoint123/Unilyric)





</details>

---

## Star History

<a href="https://www.star-history.com/?repos=qingyueyin%2FPure-music&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=qingyueyin/Pure-music&type=date&theme=dark&legend=top-left&sealed_token=3xg2arWalPfLMWP-v8tF6oiUigXHChZGv3G5byMARkfFx4mAH_bKPZWuYsOGt0OXyQAacmwE94DO-yNQKFu3d1xE7KqjHBRQ1PXDBRrIb9-lsK6IVQyzdA" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=qingyueyin/Pure-music&type=date&theme=light&legend=top-left&sealed_token=3xg2arWalPfLMWP-v8tF6oiUigXHChZGv3G5byMARkfFx4mAH_bKPZWuYsOGt0OXyQAacmwE94DO-yNQKFu3d1xE7KqjHBRQ1PXDBRrIb9-lsK6IVQyzdA" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=qingyueyin/Pure-music&type=date&legend=top-left&sealed_token=3xg2arWalPfLMWP-v8tF6oiUigXHChZGv3G5byMARkfFx4mAH_bKPZWuYsOGt0OXyQAacmwE94DO-yNQKFu3d1xE7KqjHBRQ1PXDBRrIb9-lsK6IVQyzdA" />
 </picture>
</a>

---

## License

**GNU General Public License v3.0** — 法律上遵循此许可。

**附加要求（非法律条款，但请尊重）：**
- 本软件**仅限非商业用途**
- 若使用或修改本软件，**请注明出处**（附上本仓库链接）
- 商业使用请联系作者

Pure Music 始于 [coriander_player](https://github.com/Ferry-200/coriander_player)（GPL-3.0），历经大量重写与扩展，已成为独立发行的项目。

---

<div align="center">Made with ❤️ by qingyueyin</div>
