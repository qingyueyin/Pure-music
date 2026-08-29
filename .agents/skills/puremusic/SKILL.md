---
name: puremusic
description: Pure-music 项目开发指南，覆盖 Windows Flutter/Dart 前端、Rust 后端、音频播放、歌词解析与渲染、桌面歌词、主题背景、设置、FFI、文档和测试。处理此仓库的代码理解、问题诊断、功能开发、缺陷修复、性能优化或代码审查时使用。
---

# Pure-music 开发

## 开始工作

1. 先读仓库根目录的 `AGENTS.md`，再检查 `git status --short`；把已有改动视为用户工作，不覆盖、不回退。
2. 先定位实际调用链和现有实现，再决定修改位置；代码与本 skill 不一致时，以当前代码为准，并同步修正本 skill 中的过时信息。
3. 控制修改范围，不顺手重构无关代码；不创建分支、不提交、不推送，除非用户在当前任务中明确要求。

## 受保护功能

修改下列功能前先明确告知用户将涉及哪些文件和行为：

- 原文、翻译、注音的分组管理。
- 音调调节。
- 流光背景的音频律动模式。
- 其他已经上线的特有功能；无法确定是否属于保护范围时，先询问用户。

告知后再编辑相关文件，不把相邻重构混入修改。

## 代码导航

- 应用入口与路由：`lib/main.dart`、`lib/entry.dart`。
- 全局设置与播放偏好：`lib/core/settings.dart`、`lib/core/preference.dart`。
- 主题与颜色：`lib/core/theme.dart`、`lib/core/color_extraction.dart`、`lib/core/desktop_lyric_colors.dart`；封面取色实现位于 `rust/src/api/color_extraction.rs`。
- 歌词模型和解析：`lib/lyric/`；在线歌词获取与转换：`lib/services/online_lyric/`。
- 播放页和歌词 UI：`lib/page/now_playing_page/`，组件集中在其 `component/` 目录。
- 播放、歌词和桌面歌词服务：`lib/play_service/`；底层播放封装：`lib/native/bass/`。
- 详情页播放入口：`lib/page/uni_detail_page.dart`、`lib/page/uni_page_components.dart`；顺序播放使用 `PlayAll`，随机播放使用 `ShufflePlay`，当前只有专辑详情页启用 `enablePlayAll`。
- 播放页控件和歌词来源：`lib/page/now_playing_page/large_page.dart`、`small_page.dart`、`component/lyric_source_view.dart`；常驻控件设置由 `AppSettings.alwaysShowNowPlayingControls` 管理。
- 桌面歌词过渡与高亮：`lib/play_service/lyric_service.dart`、`desktop_lyric_service.dart`；显示组件的换行和逐词高亮在 `pure-player-lyric` 仓库维护。
- 演出模式：`lib/page/concert_page.dart`；节目单持久化在 `lib/services/concert_program_store.dart`，Dart 调用封装在 `lib/services/smart_sort_service.dart`，核心编排算法在 `rust/src/smart_sort/`。
- 单曲标签和歌词编辑：`lib/page/audio_detail_page.dart`；LRC 序列化在 `lib/lyric/lrc_serializer.dart`，实际标签读写通过 Rust tag API 完成。
- 任务栏缩略图与封面预览：`lib/play_service/taskbar_thumbnail_service.dart`、`windows/runner/taskbar_thumbnail.*`。
- Dart FFI 绑定：`lib/native/rust/`；Rust API：`rust/src/api/`。
- Windows 平台代码：`windows/`；独立桌面歌词模块：`desktop_lyric/`。
- 项目文档：`page/docs/`；测试：`test/` 和 `integration_test/`。

涉及播放页样式、动画、播放进度、歌词跟随、频谱或动态背景时，编辑前完整阅读 [播放页性能规则](references/player-performance.md)。

## 既有模式

- 使用 `AppSettings.instance` 管理全局配置，使用 `AppPreference.instance` 管理播放偏好。
- 播放页显示设置通过 `AppSettings.rebuildNotifier` 通知控件重建；新增设置要同时接入读取、保存和设置页入口。
- 使用 `ThemeProvider` 下发主题；使用 `LyricRenderConfig` 和 `LyricViewController` 管理歌词视觉配置，不引入新的状态管理库。
- 封面主色和调色板由 Rust 提取，Dart 侧的 `ColorExtractionService` 只缓存提取结果，不增加重复的 Dart 取色链路。
- 使用 `Symbols.xxx` 图标；颜色透明度使用 `Color.withValues(alpha:)`。
- 不在 `build` 中启动动画、读配置或触发其他副作用；异步回调更新界面前检查 `mounted`。
- 把 `lib/native/rust/` 和 `rust/src/frb_generated.rs` 中的绑定视为生成代码；修改 Rust API 后通过项目现有生成配置更新，不手工维护生成结果。
- 桌面歌词只把歌词文件明确标出的长空白行视为过渡行；普通歌词行之间的时间间隔不自动生成插播空白。
- 演出模式的编排顺序只替换当前播放队列，不修改来源歌单；调整参数时复用已缓存的音频分析结果。

## 播放页约束

- 复用现有同步信号、共享帧驱动和缓存，不为单个视觉组件新增常驻高频订阅、短周期定时器或独立 Ticker。
- 每帧路径不做 FFI、文件读取、图片解码、调色板提取、大集合分配或整页 `setState`。
- 仅让可见且需要动画的页面、歌词行和背景执行逐帧工作；暂停、隐藏、切换模式和销毁时停止或解绑。
- 为图片、Painter、Paragraph、滤镜、频谱和调色板缓存定义上限与清理时机；保留切歌过渡需要的新旧资源，过渡后释放旧资源。
- 没有相同条件下的运行态数据时，只陈述静态检查结果，不宣称内存、CPU、GPU 或帧率已经达标。

## 修改与验证

1. 复用仓库已有写法，注释只说明做了什么和为什么做，不写来源，不增加无意义的空行。
2. 仅格式化本次修改的源文件；对改动范围执行静态分析，确保没有新增警告或错误。
3. 除非用户明确要求，不主动运行完整构建或完整测试套件；未运行的验证项目如实说明，不把静态分析写成编译或性能结论。
4. 完成后检查 `git diff --check`、相关 diff 和 `git status --short`，确认没有覆盖用户已有改动。
5. 最终回复不超过 3 句，说明改了哪些文件、做了什么，以及实际执行的验证，不粘贴 diff。

## 发布文档

- GitHub Release 正文按用户能理解的功能分组书写，优先说明可感知的变化和使用位置。
- 拟定 Release 前，以最近一次由 Action 同步的版本提交为边界核对全部用户可见提交，不能只根据最近几条提交概括。
- `page/docs/guide/changelog.md`、`page/docs/public/latest-release.json` 和版本同步文件由 GitHub Action 根据 Release 自动更新，不在常规功能提交中手工维护。
