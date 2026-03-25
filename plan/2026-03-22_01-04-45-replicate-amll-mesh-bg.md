---
mode: plan
cwd: D:\All\Documents\Projects\player\Pure-music
task: 复刻 AMLL 的网格渐变渲染器与播放页背景动效到 Pure Music
complexity: complex
planning_method: builtin
created_at: 2026-03-22T01:04:45+08:00
---

# Plan: 复刻 AMLL 网格渐变与播放页背景

🎯 任务概述
目标不是再堆一套新的背景特效，而是把 AMLL 源项目里已经跑通的背景渲染协议、网格生成逻辑、专辑纹理预处理、播放页接入方式，按 Flutter/Windows 的实现边界迁移到 Pure Music。现状是 Pure Music 已经有 `AmllBackground`、`MeshGradientBackground` 和一套 `amll_bhp_mesh` 端口，但三者还没有形成 AMLL 那种“统一渲染入口 + 封面切换过渡 + 低频驱动 + 性能开关 + 页面状态联动”的完整链路。

📋 执行计划
1. 先固化对标基线，按 AMLL 的背景接口和播放器接线方式建立验收标准。
   以 `packages/core/src/bg-render/base.ts:3`、`packages/core/src/bg-render/index.ts:12`、`packages/react-full/src/components/PrebuiltLyricPlayer/index.tsx:596` 为准，梳理 `setAlbum`、`setLowFreqVolume`、`setHasLyric`、`setFPS`、`setStaticMode`、`setRenderScale` 六个核心输入，再映射到 Pure Music 当前播放页入口 `lib/page/now_playing_page/page.dart:85`。
2. 重构 Pure Music 播放页背景接入层，替换当前“布尔开关二选一”的临时结构。
   现在 `NowPlayingPage` 只按 `enableAmllBackground` 在 `AmllBackground` 与 `MeshGradientBackground` 之间切换（`lib/page/now_playing_page/page.dart:91`、`lib/core/preference.dart:37`），后续应改成“背景渲染策略/模式”枚举，至少区分 `amll_mesh`、`shader_fallback`、`simple_fallback`，并保证旧布尔偏好可以迁移。
3. 补齐播放页输入数据管线，让背景拿到 AMLL 真正依赖的动态输入。
   当前 `AmllBackground` 支持 `albumCoverBytes`、`monetColorScheme`、`spectrumStream`，但播放页实际只传了 `dominantColor` 和 `spectrumStream`（`lib/page/now_playing_page/component/amll_background.dart:15`、`lib/page/now_playing_page/page.dart:92`）。执行时要把封面原始字节、歌词页可见状态、暂停/恢复状态、低频能量统一接给背景控制器，否则只能继续停留在“效果像”而不是“实现对齐”。
4. 抽出专辑纹理预处理模块，对齐 AMLL 的 `setAlbum` 处理链。
   AMLL 在 `packages/core/src/bg-render/mesh-renderer/index.ts:1132` 之后做了资源重试加载、32x32 降采样、对比度/饱和度/亮度调整、模糊和纹理状态切换；Pure Music 当前只有 `amll_mesh_texture.dart` + shader 交叉淡入（`lib/page/now_playing_page/component/amll_background.dart:316`）。建议把这部分抽成可复用的“封面背景纹理预处理器”，同时服务网格渲染主路径和 shader fallback。
5. 以 Flutter 可行方案为前提，实现 AMLL 网格渐变主渲染路径的技术 Spike。
   现有 `lib/mesh_gradient/core/amll_bhp_mesh.dart:64` 已经明确对标 AMLL 的 `updateMesh()` 行为，但真正接入播放页的仍是一个简化 shader（`lib/page/now_playing_page/component/mesh_gradient_background.dart:8`）。需要先验证 Flutter 端是否能用 `ui.Vertices`/`Canvas.drawVertices`/`ImageShader` 或等价路径表达“顶点位置 + 顶点色 + UV 采样 + 多状态淡入淡出”；如果受限，则把现有 `AmllBackground` 明确降级为 fallback，而不是继续把它当主实现。
6. 迁移 AMLL 的控制点预设与随机生成策略，形成可复现的网格形态库。
   AMLL 使用预设控制点和随机控制点生成混合策略（`packages/core/src/bg-render/mesh-renderer/cp-presets.ts:38`、`packages/core/src/bg-render/mesh-renderer/cp-generate.ts:153`）；Pure Music 当前 `AmllBackground` 只是基于 seed 生成 `flow16` 切线场（`lib/page/now_playing_page/component/amll_background.dart:154`）。执行时要把 AMLL 的 control-point preset 数据迁到 Flutter，并保持 deterministic seed 或 cover-hash 选型，避免每次切歌网格形态漂移失控。
7. 把播放页背景动效与页面状态联动做全，而不是只做“封面换了就换色”。
   需要补齐封面切换淡入、多 mesh state 渐变、歌词页打开时的活跃度、页面隐藏时静态模式、暂停时时钟冻结、低频平滑驱动等行为。AMLL 参考点在 `packages/core/src/bg-render/mesh-renderer/index.ts:841`、`packages/core/src/bg-render/mesh-renderer/index.ts:925`、`packages/react-full/src/states/configAtoms.ts:290`、`packages/react-full/src/states/dataAtoms.ts:144`；Pure Music 当前只有 ticker、palette tween、album blend 和基础频谱平滑（`lib/page/now_playing_page/component/amll_background.dart:124`、`lib/page/now_playing_page/component/amll_background.dart:341`）。
8. 同步整理偏好项、调参与性能降级策略，确保这次改造可上线、可回退。
   参考 AMLL 的 `FPS`、`renderScale`、`staticMode` 配置（`packages/react-full/src/states/configAtoms.ts:290`），为 Pure Music 增加性能档位或高级设置；默认保留当前 shader fallback 作为回滚路径，Windows 设备性能不足时允许自动切回低成本背景，而不是让主路径硬顶所有机器。
9. 最后补测试与回归验证，先修当前基线错误，再覆盖新链路。
   `test/amll_background_shader_test.dart:7` 仍按旧的 34 float 布局断言，但实现已经是 52 float 且包含 `albumBlend/hasAlbum`（`lib/page/now_playing_page/component/amll_background_shader.dart:6`），说明现有测试基线已过时。执行时先修这类失真测试，再补 `amll_bhp_mesh` 预设回归、封面切换集成、无封面 fallback、播放页可见性/静态模式验证，最后跑 `flutter analyze`、定向 `flutter test`，并在 Windows 上做一次实际播放页手动回归。

⚠️ 风险与注意事项
- 最大风险不是算法，而是图形栈差异。AMLL 主实现依赖 WebGL mesh + FBO + 纹理混合（`packages/core/src/bg-render/mesh-renderer/index.ts:979`），Flutter 未必能 1:1 复刻，需要先做渲染可行性 Spike。
- Pure Music 当前播放页没有把封面原始字节和“歌词页是否打开”作为背景统一输入，直接开做渲染器会卡在数据源不完整的问题上。
- 现有背景实现是并行生长出来的两套方案，`AmllBackground`、`MeshGradientBackground`、`amll_mesh_background_widget` 同时存在，若不先收口成单一策略层，后续会继续出现重复逻辑和配置失真。
- 回滚策略必须一开始就定好。推荐保留 `AmllBackground` 作为 `shader_fallback`，新 mesh 主路径只在功能完整且性能可接受后再升为默认。

📎 参考
- `lib/page/now_playing_page/page.dart:85`
- `lib/core/preference.dart:37`
- `lib/page/now_playing_page/component/amll_background.dart:15`
- `lib/page/now_playing_page/component/amll_background.dart:227`
- `lib/page/now_playing_page/component/amll_background.dart:316`
- `lib/page/now_playing_page/component/amll_background_shader.dart:6`
- `lib/page/now_playing_page/component/mesh_gradient_background.dart:8`
- `lib/mesh_gradient/core/amll_bhp_mesh.dart:64`
- `test/amll_background_shader_test.dart:7`
- `D:/All/Documents/Projects/applemusic-like-lyrics/packages/core/src/bg-render/base.ts:3`
- `D:/All/Documents/Projects/applemusic-like-lyrics/packages/core/src/bg-render/index.ts:12`
- `D:/All/Documents/Projects/applemusic-like-lyrics/packages/core/src/bg-render/mesh-renderer/index.ts:779`
- `D:/All/Documents/Projects/applemusic-like-lyrics/packages/core/src/bg-render/mesh-renderer/index.ts:1132`
- `D:/All/Documents/Projects/applemusic-like-lyrics/packages/core/src/bg-render/mesh-renderer/cp-presets.ts:38`
- `D:/All/Documents/Projects/applemusic-like-lyrics/packages/core/src/bg-render/mesh-renderer/cp-generate.ts:153`
- `D:/All/Documents/Projects/applemusic-like-lyrics/packages/react-full/src/components/PrebuiltLyricPlayer/index.tsx:596`
- `D:/All/Documents/Projects/applemusic-like-lyrics/packages/react-full/src/states/configAtoms.ts:290`
- `D:/All/Documents/Projects/applemusic-like-lyrics/packages/react-full/src/states/dataAtoms.ts:144`
