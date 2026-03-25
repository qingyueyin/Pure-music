---
mode: brief
cwd: D:\All\Documents\Projects\player\Pure-music
task: Pure Music AMLL 背景复刻对内同步
status: in_progress
created_at: 2026-03-22T12:18:48+08:00
related_plan: plan/2026-03-22_01-04-45-replicate-amll-mesh-bg.md
---

# Brief: Pure Music AMLL Background

## 这项工作要解决什么

目标是把 `applemusic-like-lyrics` 里的播放页背景能力迁到 Pure Music，范围不是单个 shader，而是整条背景链路：

1. 播放页如何选择背景模式。
2. 背景如何拿到封面、低频能量、页面状态。
3. AMLL shader fallback 是否可用。
4. 真正的 mesh gradient 主路径是否能在 Flutter/Windows 上落地。

当前判断：这项工作仍然处于 `in_progress`，还没有达到“完整复刻 AMLL 网格渐变渲染器”的完成标准。

## 当前已经完成的部分

1. 播放页背景配置已经从 `enableAmllBackground` 布尔值升级成 `NowPlayingBackgroundMode` 枚举，支持 `shaderFallback / meshGradient / simpleFallback`。
   代码位置：
   `lib/core/enums.dart:38`
   `lib/core/preference.dart:38`

2. 播放页现在会把封面原始字节传给 `AmllBackground.albumCoverBytes`，不再只传主色。
   代码位置：
   `lib/page/now_playing_page/page.dart:60`
   `lib/page/now_playing_page/page.dart:94`
   `lib/page/now_playing_page/page.dart:156`

3. 设置页已经有三态背景模式切换，可以直接切 AMLL、网格、纯色。
   代码位置：
   `lib/page/settings_page/other_settings.dart:310`

4. AMLL shader fallback 的运行时编译错误已经修掉。
   之前 `assets/shaders/amll_background.frag` 在 Flutter SkSL 下会因为 `min(int, int)` 失败，导致实际总是退回 painter fallback。
   现在已修复为 `int(clamp(float(...), 0.0, 3.0))`。
   代码位置：
   `assets/shaders/amll_background.frag:107`

5. 背景相关的定向测试已经通过，说明当前 shader fallback 链路和配置链路是可工作的。

## 目前还没有完成的部分

1. `meshGradient` 模式仍然不是 AMLL 那套真正的 mesh renderer。
   现在的 `lib/page/now_playing_page/component/mesh_gradient_background.dart:8` 还是简化版 runtime shader，不是 AMLL `packages/core/src/bg-render/mesh-renderer/index.ts` 那套 `BHP mesh + texture + 多状态淡入 + FBO` 主路径。

2. 也就是说，目前只完成了“背景模式配置收口”和“AMLL shader fallback 可用”，还没有完成“AMLL 网格渐变主实现复刻”。

3. Windows 实机视觉效果还没有最终验收。
   原因不是背景代码本身，而是当前仓库还存在独立的构建阻塞：
   `lib/native/bass/bass_player.dart:178`
   `lib/native/bass/bass_player.dart:865`
   这会让 `flutter build windows --debug` 失败，导致无法直接做完整桌面回归。

## 我接下来打算做什么

### Phase 1: 清掉背景主路径之外的构建阻塞

先处理当前阻塞 Windows 构建的语法错误，目标是让 `flutter build windows --debug` 恢复可用。  
如果这一步不做，后面的背景视觉回归都只能停留在 widget test 层面。

### Phase 2: 做 Flutter 侧 AMLL mesh 主路径技术 Spike

验证 Flutter 端能否承载以下能力：

1. BHP mesh 顶点位置更新。
2. 顶点色 + UV + 专辑纹理采样。
3. 多个 mesh state 的 alpha 淡入淡出。
4. 低频能量驱动。

这一步的目标不是一次做完，而是确认“主路径是否可实现”。  
如果 Flutter 图形栈不能合理承载，就需要明确把 `AmllBackground` 保留为正式 fallback，而不是继续口头上称为“已复刻 AMLL mesh”。

### Phase 3: 把 AMLL 控制点预设和纹理预处理迁进来

按 AMLL 原项目对齐两块内容：

1. 控制点 preset / 随机控制点生成。
   参考：
   `packages/core/src/bg-render/mesh-renderer/cp-presets.ts`
   `packages/core/src/bg-render/mesh-renderer/cp-generate.ts`

2. 封面纹理预处理链。
   参考：
   `packages/core/src/bg-render/mesh-renderer/index.ts:1132`

这样才能让 Pure Music 背景的网格形态和封面质感接近 AMLL，而不是只做一个“颜色像”的背景。

### Phase 4: 做最终视觉与行为回归

验收标准会看四件事：

1. 切歌时背景是否平滑过渡。
2. 暂停/恢复时背景是否正确停表。
3. 低频驱动是否生效且不会造成额外抖动。
4. AMLL / 网格 / 纯色 三种模式是否都能稳定切换。

## 已有验证证据

已经跑过的验证包括：

1. `flutter test test/now_playing_background_mode_preference_test.dart`
2. `flutter test test/amll_background_shader_test.dart`
3. `flutter test test/amll_background_integration_test.dart`
4. `flutter test test/mesh_gradient/amll_bhp_mesh_test.dart`
5. `flutter analyze lib/core/enums.dart lib/core/preference.dart lib/page/now_playing_page/page.dart lib/page/settings_page/other_settings.dart lib/page/settings_page/create_issue.dart`

当前结论：

1. AMLL shader fallback 现在可以加载。
2. 背景模式配置链路工作正常。
3. BHP mesh 生成相关测试通过。
4. 但无法据此声称“AMLL mesh 主路径复刻已完成”。

## 需要同事知道的风险

1. 这项任务的最大风险不是调参，而是 Flutter 图形栈和 AMLL WebGL 实现之间的能力差异。
2. 如果不先修 `bass_player.dart` 的现有构建错误，桌面端真实效果验证会一直被外部问题阻塞。
3. 当前仓库里同时存在 `AmllBackground`、`MeshGradientBackground`、`amll_mesh_background_widget` 三条背景思路，后续必须继续收口，否则会反复分叉。

## 对同事的结论

如果有人现在问“Pure Music 的 AMLL 背景复刻做到哪了”，统一说法应该是：

`背景配置和 AMLL shader fallback 已经打通，背景主路径的完整 AMLL mesh renderer 还在实现中，当前不应对外宣称已经完全复刻。`

## 参考文件

- `plan/2026-03-22_01-04-45-replicate-amll-mesh-bg.md`
- `lib/core/enums.dart:38`
- `lib/core/preference.dart:38`
- `lib/page/now_playing_page/page.dart:86`
- `lib/page/settings_page/other_settings.dart:310`
- `assets/shaders/amll_background.frag:107`
- `lib/page/now_playing_page/component/mesh_gradient_background.dart:8`
- `lib/mesh_gradient/core/amll_bhp_mesh.dart:64`
- `D:/All/Documents/Projects/applemusic-like-lyrics/packages/core/src/bg-render/mesh-renderer/index.ts:925`
- `D:/All/Documents/Projects/applemusic-like-lyrics/packages/core/src/bg-render/mesh-renderer/index.ts:1132`
