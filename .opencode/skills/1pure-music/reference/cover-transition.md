# Now Playing Page — Cover Transition

## 三级递进封面加载

`_NowPlayingInfo` 按优先级逐级加载，取最高分辨率非 null 者：

| 级别 | 来源 | 时机 | 说明 |
|------|------|------|------|
| `_immediateCover` | widget.cover（父级通过 `findAncestorStateOfType` 共享）或 `audio.smallCoverBytes` | initState 同步 | 首帧就有图，不闪。48×48 小字节 |
| `_loResCover` | `audio.cover`（异步全尺寸） | initState 的 post-frame callback | 约 0-100ms 后到 |
| `_hiResCover` | 父级 `updateCover` 回调 | 260ms 防抖后 | 高清版 |

`_NowPlayingInfo` build 时按 `_hiResCover ?? _loResCover ?? _immediateCover ?? fallbackCover` 选图。

## 父子共享封面

`_NowPlayingInfo` 通过 `findAncestorStateOfType<_NowPlayingPageState>()` 获取父级的 `nowPlayingCover`（`ImageProvider?`）。父级必须在 `updateCover()` 异步加载成功后赋值：`nowPlayingCover = cover`。

## dispose 不得清数据字段

`_NowPlayingPageState.dispose()` 中**不能**置 null 以下字段，否则 pop 过渡期间 `BlurCoverBackground` 丢失背景 → 闪烁：

- ❌ `nowPlayingCover = null`
- ❌ `_nowPlayingCoverBytes = null`
- ❌ `_preExtractedPalette = null`

v2.1.5 的 dispose 只做：`_coverDebounceTimer?.cancel()` + `CoverImageCache.instance.trimMemory()` + `super.dispose()`。

## 背景模糊不能重跑

`BlurCoverBackground` 依赖 `_nowPlayingCoverBytes` 做模糊图。每次这个 bytes 变化，它会 `_clearImage()`（dispose 旧模糊图 → 显示 `tintColor`）再重新模糊新 bytes，中间有 600ms X 2 的淡入淡出，露出底色 → 闪。

**规则**：`updateCover()` 的异步回调（_coverDebounceTimer）**不写入** `_nowPlayingCoverBytes`，也**不写入** `_dominantColor` / `_preExtractedPalette`。背景永远使用首帧的 48×48 `smallBytes` 做模糊，tint 永远用首帧的缓存调色板或 fallback。

## Timer 回写 tint 色 → 过渡期闪烁

`_coverDebounceTimer` 回调（约 200ms 触发）如果写入 `_dominantColor` / `_preExtractedPalette`，`BlurCoverBackground._tintColor()` 会从 `fallbackColor`（软化 primary）瞬间跳变为封面调色板均值。此时路由过渡动画（~300ms）尚未结束，跳变表现为"封面闪一下"。

**规则**：timer 回调只做三件事：
1. `_colorService.cachePaletteForPath()` — 写缓存供下次首帧用
2. `ThemeProvider.instance.applySeedColorDirectly()` — 主题种子色更新
3. `nowPlayingCover = MemoryImage(bytes)` — 封面 ImageProvider 供子级共享

不碰 `_dominantColor` / `_preExtractedPalette` / `_nowPlayingCoverBytes`。

## 常见回归模式

1. **死声明**：字段声明了但从不赋值（`nowPlayingCover` 声明在 `_NowPlayingPageState` 但 `updateCover` 不写）
2. **静默删除**：重构时删掉父子共享（`findAncestorStateOfType`）且无替代
3. **递进退化**：三级加载坍缩成单级，首帧空白
4. **生命周期错配**：dispose 清 `_nowPlayingCoverBytes` → pop 过渡闪烁
