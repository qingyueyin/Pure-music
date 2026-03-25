# Pure Music AMLL 歌词改造任务清单（2026-03-22）

## 目标

在不破坏现有播放链路的前提下，分阶段把主播放页歌词体验升级到 AMLL 风格能力。

## 里程碑与验收

- [x] M0：范围冻结与基线确认
  - 仅覆盖主播放页歌词视图（不含桌面歌词子项目）。
  - 保留旧逻辑回退开关。

- [x] M1：歌词时序预处理层（数据层）
  - 新增独立预处理器，输出“有效开始时间轴”。
  - 规则覆盖：`advance start`、`overlap clean`、`interlude-friendly`。
  - `LyricService` 当前行判定切到预处理时间轴。
  - 单测覆盖预处理核心规则与边界。

- [x] M2：歌词渲染配置收敛
  - 抽出统一配置对象：字号、模糊、渐变宽度、缩放倍率、弹簧参数。
  - `preference.dart`、`vertical_lyric_view.dart`、`lyric_view_tile.dart` 去散点参数。
  - 保留低配降级与效果关闭选项。

- [x] M3：行级动画体系升级
  - 从统一 300ms 隐式动画切到 `Ticker + SpringSimulation/AnimationController`。
  - 保持滚动跟随与手动滚动打断行为稳定。

- [x] M4：逐词渲染重构
  - `ShaderMask` 固定尾巴改为可配置 fade width。
  - 抽离逐词 mask 计算复用逻辑。
  - 非逐词歌词保留纯文本回退。

- [x] M5：强调效果与帧成本控制
  - `WordEmphasisHelper` 支持可调抬升、缩放、发光曲线。
  - 限制每帧对象重建，避免按词创建重型动画对象。

- [x] M6：视口与滚动策略升级
  - 引入“当前块/缓冲块”策略。
  - 重做自动吸附、用户拖动暂停、间奏显示与 overscan。

- [x] M7：验证与回退
  - 自动化验证：`flutter analyze`、`flutter test`、`flutter build windows --debug` 已通过。
  - 设置项可回退旧实现或关闭高级效果。
  - 人工 60/120Hz、长歌词、低性能设备抽验建议补充，但不阻塞当前交付。

- [x] M8：桌面歌词同步评估（后置）
  - 已评估 `.trae/lyric/pure_player_lyric/` 同步策略。
  - 结论：优先协议扩展，不复制业务判断；若继续同步 AMLL 词级效果，先统一词时间基准。

## 当前执行状态

- 当前进行中：无阻塞开发项，剩余为人工抽验建议。
- 本轮已交付：预处理器 + 测试 + `LyricService` 接入、统一歌词渲染配置对象、QRC 逐词绝对时间修复、行级 spring motion、逐词 mask helper、强调效果配置化、viewport block/buffer 策略、全量自动化验证、桌面歌词同步评估。
