# Pure Music 桌面歌词

<p align="center">
  <img src="app_icon.ico" width="80" height="80" alt="Pure Music 桌面歌词 Logo">
</p>

<p align="center">
  专为 Pure Music 打造的桌面歌词
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Windows-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Flutter-3.3+-0x0175C2?style=flat-square" alt="Flutter">
  <img src="https://img.shields.io/badge/License-GPL--3.0-green?style=flat-square" alt="License">
</p>

Pure Music 的桌面歌词，跟随主播放器实时同步歌词与播放状态。

---

## 截图预览

**歌词样式**

<p align="center">
  <img src="screenshot/左对齐主题色歌词.png" width="330" alt="左对齐主题色歌词">
  <img src="screenshot/居中主题色歌词信息歌词.png" width="330" alt="居中主题色歌词">
  <img src="screenshot/右对齐主题色歌词.png" width="330" alt="右对齐主题色歌词">
</p>

---

## 特色

**逐字跟唱** — 逐字高亮与主程序同步（含提前换句、句末收尾、变速播放），间奏自动过渡

**翻译与注音** — 逐行翻译、注音并排显示，注音位置可调（歌词上方 / 歌词下方 / 翻译下方），可分别开关

**多种配色** — 跟随主题色、明暗配色（跟随/浅色/深色）、自定义已播放/未播放颜色（含透明度）

**多对齐模式** — 左对齐、居中、右对齐，悬停控制条跟随歌词对齐

**切换动画** — 上划 / 下划 / 左划 / 右划 / 淡入淡出 / 吸收六种换句动画

**文字描边** — 默认启用，深色黑描边、浅色白描边自动切换

**自由窗口** — 拖动移动、边缘调整大小、置顶、背景透明度、锁定防误触（点击穿透）

**悬停控制** — 悬停显示控制条：锁定、上一首、播放/暂停、下一首、关闭

**实时同步** — 歌词、播放状态、主题色与配置改动即时同步，主程序退出自动关闭

---

## 快速开始

<details>
<summary>构建流程</summary>

```bash
flutter pub get
flutter run

# 构建 Release
flutter build windows --release

# 或使用项目自带构建脚本（自动清理、更新版本号、输出到 output/）
.\build_windows.ps1
```

</details>

<details>
<summary>功能总览</summary>

**歌词** — 逐字高亮、逐行翻译、注音（位置可调）、多对齐模式、六种切换动画、字体大小/粗细、歌曲信息
**配色** — 跟随主题色、明暗配色、自定义颜色、文字描边、背景透明度
**窗口** — 拖动移动、调整大小、置顶、锁定防误触（点击穿透）、悬停控制条（切歌/播放暂停/关闭）
**同步** — 与主播放器实时同步歌词、播放状态与主题，主程序退出自动关闭

</details>

---

## 致谢

<details>
<summary>开源库</summary>

window_manager、screen_retriever、provider、win32、ffi、flutter_localizations

</details>

<details>
<summary>参考项目</summary>

[zerobit_player_desktop_lyrics](https://github.com/zerobit-tech/zerobit_player_desktop_lyrics)、[coriander_player](https://github.com/Ferry-200/coriander_player)

</details>

---

## License

**GNU General Public License v3.0** — 法律上遵循此许可。

**附加要求（非法律条款，但请尊重）：**

- 本软件**仅限非商业用途**
- 若使用或修改本软件，**请注明出处**（附上本仓库链接）

Pure Music 桌面歌词是 Pure Music 的组成部分，遵循与主程序一致的许可协议。

---

<div align="center">Made with ❤️ by qingyueyin</div>
