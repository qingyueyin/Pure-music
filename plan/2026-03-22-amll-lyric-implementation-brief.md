# Pure Music AMLL 歌词改造实施说明（对外同步版）

## 目标

在不破坏现有播放链路的前提下，分阶段把主播放页歌词体验升级到 AMLL 风格能力，并保留可回退路径。

## 范围

- 仅覆盖主播放页歌词视图与其数据链路。
- 桌面歌词子项目作为后置评估，不进入首批实施。

## 已完成

- 任务拆解清单已落地。文件：`D:\All\Documents\Projects\player\Pure-music\plan\2026-03-22-amll-lyric-task-breakdown.md`
- 新增时序预处理器与单测，并接入当前行判定。文件：`D:\All\Documents\Projects\player\Pure-music\lib\lyric\lyric_timing_preprocessor.dart`、`D:\All\Documents\Projects\player\Pure-music\lib\play_service\lyric_service.dart`、`D:\All\Documents\Projects\player\Pure-music\test\lyric_timing_preprocessor_test.dart`
- 新增统一歌词渲染配置对象，并将主播放页歌词视图切到统一配置入口。文件：`D:\All\Documents\Projects\player\Pure-music\lib\core\lyric_render_config.dart`、`D:\All\Documents\Projects\player\Pure-music\lib\core\preference.dart`、`D:\All\Documents\Projects\player\Pure-music\lib\page\now_playing_page\component\lyric_view_controls.dart`、`D:\All\Documents\Projects\player\Pure-music\lib\page\now_playing_page\component\lyric_view_tile.dart`、`D:\All\Documents\Projects\player\Pure-music\lib\page\now_playing_page\component\vertical_lyric_view.dart`、`D:\All\Documents\Projects\player\Pure-music\test\lyric_render_config_test.dart`
- 修复 QRC 逐词时间戳仍停留在相对时间的问题，并补充 offset 场景回归测试。文件：`D:\All\Documents\Projects\player\Pure-music\lib\lyric\qrc.dart`、`D:\All\Documents\Projects\player\Pure-music\test\qrc_timing_test.dart`
- 行级动画已切到 `Ticker + SpringSimulation/AnimationController` 驱动，移除 `LyricViewTile` 里的统一 300ms 隐式动画链路。文件：`D:\All\Documents\Projects\player\Pure-music\lib\page\now_playing_page\component\lyric_line_motion.dart`、`D:\All\Documents\Projects\player\Pure-music\lib\page\now_playing_page\component\lyric_view_tile.dart`、`D:\All\Documents\Projects\player\Pure-music\test\lyric_line_motion_test.dart`
- 逐词高亮已抽成独立 mask helper，并将 fade width 接入偏好、控制器和设置快控入口。文件：`D:\All\Documents\Projects\player\Pure-music\lib\page\now_playing_page\component\lyric_word_highlight_mask.dart`、`D:\All\Documents\Projects\player\Pure-music\lib\core\preference.dart`、`D:\All\Documents\Projects\player\Pure-music\lib\page\now_playing_page\component\lyric_view_controls.dart`、`D:\All\Documents\Projects\player\Pure-music\test\lyric_word_highlight_mask_test.dart`
- 强调效果已切到统一 `WordEmphasisHelper.resolve` 状态计算，并通过配置项控制抬升、缩放、发光强度与相位。文件：`D:\All\Documents\Projects\player\Pure-music\lib\page\now_playing_page\component\word_emphasis_helper.dart`、`D:\All\Documents\Projects\player\Pure-music\lib\core\lyric_render_config.dart`、`D:\All\Documents\Projects\player\Pure-music\test\word_emphasis_helper_test.dart`
- 垂直歌词视图已加入 viewport block/buffer 策略与 overscan cacheExtent，当前行仅在越出缓冲块时触发重新吸附。文件：`D:\All\Documents\Projects\player\Pure-music\lib\page\now_playing_page\component\lyric_viewport_strategy.dart`、`D:\All\Documents\Projects\player\Pure-music\lib\page\now_playing_page\component\vertical_lyric_view.dart`、`D:\All\Documents\Projects\player\Pure-music\test\lyric_viewport_strategy_test.dart`
- 桌面歌词同步评估已完成：继续沿用主应用预处理/判定、桌面歌词只消费协议消息的路线；若后续同步 AMLL 效果，优先统一 `LyricLineChangedMessage` 的词时间基准，不在桌面歌词子项目复制当前行判定。参考：`D:\All\Documents\Projects\player\Pure-music\packages\desktop_lyric\lib\message.dart`、`D:\All\Documents\Projects\player\Pure-music\lib\play_service\desktop_lyric_service.dart`

## 当前计划（按顺序）

1. 人工真机场景抽验（60/120Hz、长歌词、低性能设备）
2. 桌面歌词效果同步若要启动，先统一词时间基准字段

## 关键技术抓手

- 当前行判定从原始 `line.start` 切换为“有效开始时间轴”，以支持提前进入与重叠清理。
- 逐词渲染与强调效果继续留在 Flutter 层，Rust 仅做音频、I/O、歌词获取。
- 渲染参数收敛到统一配置入口，保留低配降级与关闭开关。

## 验证方式

- 静态检查：`flutter analyze` 通过。
- 全量单测：`flutter test` 通过。
- 构建验证：`flutter build windows --debug` 通过，产物位于 `build\windows\x64\runner\Debug\pure_music.exe`。
- 人工 60/120Hz 观感与低性能设备抽验本轮未执行。

## 风险与回退

- 现有工作区存在大量未提交改动，需在继续推进前确认基线。
- 预处理层仅影响“当前行判定”，不改原始歌词数据，确保标签写回逻辑不受影响。
- 桌面歌词协议侧目前已具备 `words/progressMs/nextWords` 承载能力，但若继续同步 AMLL 特效，需先统一当前行与下一行的词时间基准。
- 高刷新率与低性能设备的主观观感仍建议补一次人工抽验。

## 交付物与协作

- 任务清单文档：`D:\All\Documents\Projects\player\Pure-music\plan\2026-03-22-amll-lyric-task-breakdown.md`
- 对外说明文档：本文件
