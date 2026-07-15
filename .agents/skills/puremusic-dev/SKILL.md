---
name: puremusic-dev
description: |
  Pure-music Windows 本地音乐播放器项目专属 skill。Flutter/Dart 前端 + Rust 后端（lofty 读标签、flutter_rust_bridge FFI）。
  歌词引擎同时支持 TTML、LRC、增强 LRC。当你需要修改项目代码、理解架构、添加功能或修复 bug 时务必使用此 skill。
  包含核心架构图、播放页性能预算、关键模式、命名约定和反模式清单。所有与 pure-music 项目相关的开发任务都应参考此 skill。
---

## 核心架构

```
lib/
  main.dart                -- 入口：初始化 Rust、设置、窗口
  entry.dart               -- MaterialApp.router + GoRouter + ThemeData
  core/
    settings.dart          -- AppSettings 单例，手动 JSON 序列化
    theme.dart             -- ThemeProvider (ChangeNotifier)，种子色管理
    preference.dart        -- AppPreference 单例，播放相关偏好
    lyric_controller.dart  -- LyricViewController
    lyric_render_config.dart -- LyricRenderConfig (immutable)
    enums.dart             -- ThemeOption, NowPlayingBackgroundMode 等
  component/               -- 通用可复用组件
  library/                 -- 音频库、播放列表
  lyric/                   -- 歌词引擎 (LRC / TTML / 增强 LRC)
  native/                  -- Rust FFI 绑定 (flutter_rust_bridge 生成)
  page/
    now_playing_page/
      page.dart            -- part，_NowPlayingPage 主入口
      large_page.dart      -- part，大尺寸布局
      small_page.dart      -- part，小尺寸布局
      immersive_page.dart  -- part，沉浸模式
      component/           -- 歌词 UI 集中在此
    settings_page/         -- 设置页
    uni_detail_page.dart   -- 歌曲详情页
  play_service/            -- 播放/歌词/桌面歌词服务
  services/                -- 其他服务
rust/
  src/
    api/                   -- flutter_rust_bridge API 函数
    extract_color.rs       -- k-means 颜色提取
    tag.rs                 -- lofty 读/写标签
```

## 导航指南

- 改歌词 UI → `page/now_playing_page/component/`
- 改播放行为 → `play_service/`
- 改视觉参数 → `core/lyric_render_config.dart`
- 改设置 → `core/settings.dart`
- 改主题 → `core/theme.dart`
- 改 Rust FFI → `rust/src/api/`
- 改播放页样式、动画、进度或歌词跟随 → 先读 `reference/player-performance.md`
- 图标用 `Symbols.xxx`（`material_symbols_icons`），不动态解析字符串
- 歌词视觉架构四层分离：缩放（SpringSimulation）/ 不透明度（AnimatedOpacity）/ 模糊（ImageFiltered）/ 滚动位置（ValueTransition），各层参数在 `LyricRenderConfig`
- 歌词行分三种：逐字（SyncLyricLine）、逐行（LrcLine）、间奏（空 words + 时长 > 3s）

## 状态管理规范

- **全局配置**：`AppSettings.instance.xxx` — 单例 mutable fields，手动 JSON
- **播放偏好**：`AppPreference.instance.xxx` — 单例
- **主题**：`ThemeProvider` ChangeNotifier，Provider 下发
- **歌词视觉**：`LyricRenderConfig`（@immutable + copyWith），通过 `LyricViewController.renderConfig` + `context.watch`
- 不引入新状态管理库

### 种子色优先级

封面色（Rust k-means）> 系统色。`_lastAlbumSeedColor` 在切模式时优先保留。

### Monet 色规则

只改前景色，不改背景色：

```dart
final useMonet = AppSettings.instance.useMaterialYouForControls;
final scheme = Theme.of(context).colorScheme;
color: useMonet ? scheme.primary : scheme.onSurface,
```

## 通用编码规范

- Config 类用 `@immutable` + `copyWith`
- 颜色用 `Color.withValues(alpha:)`，不用 `withOpacity`
- 动画优先弹簧物理（`package:flutter/physics.dart`），固定时长只用于 opacity/blur
- Widget 非必要不重建，painter/ticker/controller 在 `didUpdateWidget` 中响应变化
- 不在 `build` 中触发动画或副作用
- 不展示的内容不占空间（`SizedBox.shrink()`）
- 所有异步操作后检查 `mounted`

## 播放页性能硬约束

- 新样式不得新增长期高频 `positionStream` 订阅、短周期 `Timer.periodic` 或独立常驻 Ticker；先复用现有离散同步信号、共享帧时钟和本地 `Stopwatch`
- 每帧路径不得调用 FFI、读取/解码图片、提取调色板、创建大列表或用 `setState` 重建整页；动态内容优先通过 `CustomPainter` 的 `repaint` 更新
- Ticker、频谱和动态背景仅在路由可见且确实需要动画时运行；暂停、隐藏、切换模式和 `dispose` 时必须停止或解绑
- 所有图片、Painter、Paragraph、滤镜和调色板缓存必须有上限；切歌只保留过渡需要的新旧资源，并在过渡结束后平滑释放
- 优化动态背景不能把降帧、降低流速或削弱音频呼吸作为默认方案；先消除重复重绘、重复图层、重复计算和无效订阅
- 页面恢复、切歌和 seek 必须直接读取真实播放位置并发送离散同步信号；正常播放用本地时钟推进并低频校准，不能靠持续高频轮询维持正确性
- 新增动画前必须说明驱动来源、可见性条件、停止条件、缓存上限和每帧工作；缺一项就不应合入
- 没有运行态数据时，不得声称内存、CPU/GPU 或帧率已经达标；静态分析只能证明代码质量，不能证明性能

完整检查表见 `reference/player-performance.md`。

## 通信规范

- 说人话，不要废话，回答不超过 3 句
- 注释只写做了什么、为什么做，不写来源或参考
- 不引用产品/品牌名称
- 不要加不必要的空行和注释
- 所有的代码修改和新增都要确保不会引入新的 bug
- 所有的代码修改和新增都要确保不会引入新的性能问题
- 所有的代码修改和新增都要确保不会引入新的内存问题
- 所有的代码修改和新增都要确保不会引入新的内存泄漏问题
- 修改后的文件，要确保没有任何的警告和错误

## 工作流

- 修复先开独立分支 → cherry-pick 到 main → 删分支
- 改完告诉我改了哪几个文件、什么内容，不要贴 diff
- 除非被问，否则不主动 build/test
- build 命令：`flutter build windows --debug`

## 关键依赖

- `provider` 6.x — 状态管理
- `go_router` 17.x — 路由
- `flutter_rust_bridge` 2.12 — Rust FFI
- `material_symbols_icons` — Symbols 图标
- `flutter/physics.dart` — 弹簧物理动画
- `sqlite3` — 存储

## 反模式

- 不用 `PaletteGenerator`（用 Rust k-means）
- 不用 `withOpacity`/`withAlpha`
- 不动态解析 Symbols 名
- 不在 `applyThemeOption` 里重读系统色
- 行缩放不用 `forward()/reverse()`（用 `SpringSimulation.animateWith()`）
- 不在 build 中触发动画
- Monet IconButton 不改背景色
- 不在 `initState`/`build` 调用 `readFromJson()`
- 不引入额外状态管理库
- 不为单个视觉组件各自订阅高频播放位置或频谱
- 不让不可见页面、非当前歌词行或暂停状态继续逐帧工作
- 不用频繁清空全部缓存来换低内存，避免把压力集中到切歌和页面恢复瞬间
