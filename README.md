# 🎵 Pure Music 桌面歌词

<p align="center">
  <img src="app_icon.ico" width="128" height="128" alt="Pure Music Logo">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Windows-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Flutter-3.3+-0x0175C2?style=flat-square" alt="Flutter">
  <img src="https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-green?style=flat-square" alt="License">
</p>

---

## ✨ 特性

- **多种对齐模式** — 左对齐、居中、右对齐
- **逐字歌词高亮** — 逐字显示歌词进度
- **跟随主题色** — 与主播放器保持一致的视觉风格
- **锁定/解锁** — 防止误触的锁定功能

---

## 📸 预览

<img src="screenshot/桌面歌词.png" width="400" alt="桌面歌词">
<img src="screenshot/桌面歌词隐藏.png" width="400" alt="桌面歌词隐藏">

---

## 📁 项目结构

```
pure_player_lyric/
├── lib/                          # Flutter 主代码
│   ├── component/                 # UI 组件
│   │   ├── action_row.dart       # 控制按钮栏
│   │   ├── foreground.dart       # 主界面
│   │   ├── lyric_line_display_area.dart  # 歌词显示区域
│   │   └── ...
│   ├── main.dart                 # 入口文件
│   └── ...
├── windows/                      # Windows 平台代码
├── pubspec.yaml                 # 依赖配置
└── build_windows.ps1           # 构建脚本
```

---

## 🙏 致谢

### 📚 开源库

| 库                                                            | 用途         |
| :------------------------------------------------------------ | :----------- |
| [window_manager](https://pub.dev/packages/window_manager)     | 窗口管理     |
| [screen_retriever](https://pub.dev/packages/screen_retriever) | 屏幕信息获取 |

### 💡 灵感来源

- [zerobit_player_desktop_lyrics](https://github.com/zerobit-tech/zerobit_player_desktop_lyrics) — 桌面歌词设计参考
- [coriander_player](https://github.com/Ferry-200/coriander_player) — 早期版本参考

---

## 📄 License

本项目基于 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/legalcode) 许可证开源。

---

<div align="center">

Made with ❤️ by qingyueyin

</div>
