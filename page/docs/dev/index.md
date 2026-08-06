---
outline: deep
---

# 架构

面向开发者。用户功能说明见 [指南](/guide/)。

## 总览

```
Flutter / Dart UI
  ├─ page / component / play_service / lyric
  ├─ BASS FFI（播放、EQ、WASAPI、插件）
  └─ flutter_rust_bridge
       └─ Rust crate
            标签 (lofty)、曲库 (sqlite)、取色、系统能力
```

## 目录地图

| 路径 | 职责 |
|------|------|
| `lib/main.dart`、`entry.dart` | 入口、Rust init、路由、主题 |
| `lib/core/` | 设置、偏好、主题、快捷键、路径 |
| `lib/library/` | 曲库 Dart 侧 |
| `lib/lyric/` | 本地歌词解析与加载 |
| `lib/services/online_lyric/` | 在线歌词源 |
| `lib/play_service/` | 播放、EQ、歌词服务、桌面歌词服务 |
| `lib/page/now_playing_page/` | 播放页布局与歌词 UI |
| `lib/page/settings_page/` | 设置 |
| `lib/native/bass/` | BASS 播放引擎封装 |
| `lib/native/rust/` | FRB 生成绑定 |
| `rust/src/api/` | Rust 暴露 API |
| `desktop_lyric/` | 桌面歌词独立进程 |

## 运行路径

```text
音乐文件夹
  → Rust 扫描标签与目录
  → data/library.sqlite
  → AudioLibrary 组织歌曲、艺术家、专辑和文件夹
  → 页面读取并展示

点击歌曲
  → PlaybackService 管理队列与状态
  → BassPlayer 负责解码、输出、EQ 与独占模式

切换歌曲
  → LyricService 按本地 / 在线模式加载歌词
  → 播放页与桌面歌词消费同一份歌词状态
```

## 从哪里开始改

| 目标 | 入口 |
|------|------|
| 应用启动、初始化与路由 | `lib/main.dart`、`lib/entry.dart` |
| 曲库扫描与标签 | `rust/src/api/tag_reader.rs`、`lib/library/audio_library.dart` |
| 播放、队列与输出 | `lib/play_service/playback_service.dart`、`lib/native/bass/` |
| 歌词解析 | `lib/lyric/` |
| 在线歌词 | `lib/core/matcher.dart`、`lib/services/online_lyric/` |
| 播放页与歌词 UI | `lib/page/now_playing_page/` |
| 设置持久化 | `lib/core/settings.dart`、`lib/core/preference.dart` |
| 对应测试 | `test/`、`integration_test/` |

## 状态管理约定

- 全局配置：`AppSettings.instance`
- 播放偏好：`AppPreference.instance`
- 主题：`ThemeProvider`（Provider）
- 歌词视觉：`LyricRenderConfig`（immutable + `copyWith`）
- 不额外引入新状态库

## 保护功能

改动前先确认，避免破坏已稳定能力：

- 原文 - 翻译 - 罗马音分组
- 音调调节
- 封面取色的流动渐变 / 流光背景
- 其它已上线的特有能力（不确定就先问）

## 播放页性能硬约束（摘要）

- 不要新增长期高频 `positionStream` / 短周期 timer / 多余常驻 Ticker
- 每帧路径禁止 FFI、解码大图、整页 `setState`
- 不可见或暂停时必须停掉动画与订阅
- 缓存有上限；切歌只保留过渡所需资源

细节见仓库内 puremusic-dev skill 的 `player-performance` 参考。

## 环境变量

| 变量 | 值 | 作用 |
|------|----|------|
| `CP_ECHO_RECORD` | `1` | 启动时开启音频回声日志记录 |
| `CP_ECHO_LOG_DIR` | 目录 | 重定向回声日志目录（默认写入应用数据目录下的 `audio_echo_logs/`） |
| `CP_MEMORY_LOG` | `1` | 内存监控输出统计日志 |

## 测试页

无 UI 入口，通过路由直接访问：

- `/test/background` — 静态封面背景测试页（`lib/test/static_cover_background_test_page.dart`），生成渐变 / 色条 / 人脸三种测试图案，验证背景压暗参数。

## 下一步

- [构建](/dev/build)
- 用户侧 FAQ：[常见问题](/guide/faq)
