# Player Performance Budget

## Outcome

Adding a visual style or animation should mainly add drawing work. It must not add another independent position query loop, always-on Ticker, whole-widget-tree rebuild, image decode, or unbounded cache. Visual fluidity is part of the requirement, so lowering background frame rate, motion speed, or audio breathing strength is not the default optimization.

## Driving Model

- Track change, seek, player-state change, lyric-ready, and route-visible events use discrete notifiers. Read the real native position once and synchronize immediately.
- Continuous progress uses a shared Ticker or local `Stopwatch` only while visible, with low-frequency native correction. Do not give every component a high-frequency `positionStream` subscription.
- Only the active word-synced lyric line and a running interlude may repaint every frame. Ordinary lines repaint on state changes.
- Dynamic backgrounds run only while the route is visible and playback or color transition needs motion. Spectrum work stops when there are no listeners.

## Per-frame Path

Allowed: cached scalar reads, interpolation, `CustomPainter` repaint, and reused fixed-size buffers.

Forbidden: FFI calls, image decode, palette extraction, file access, Future creation, large collection allocation, whole-page `setState`, and recreating filters or Paragraphs.

## Memory Lifecycle

- Every cache defines its key, hard limit, eviction policy, and cleanup trigger.
- Track transitions may briefly retain old and new visual resources, then release the old set after the transition.
- Low-memory cleanup is staged: discard invisible/rebuildable data first, then shrink shared caches. Normal track changes must not clear all caches.
- The creator owns stopping and disposing controllers, Tickers, subscriptions, timers, and native buffers.
- Player-page `dispose` must not null `nowPlayingCover`, `_nowPlayingCoverBytes`, or `_preExtractedPalette`; read `reference/cover-transition.md` before touching that lifecycle.

## Before Editing

1. Find the existing driver for the same kind of state and reuse it.
2. State the start, pause, visibility, and disposal conditions.
3. Check whether each frame performs Widget rebuild, FFI, decode, or allocation.
4. Define cache limits and old/new resource handoff during track changes.
5. Notify the user first when protected features in `AGENTS.md` are involved.

## After Editing

1. Search new `Ticker`, `Timer.periodic`, `positionStream`, `spectrumStream`, and `setState` usage and account for every lifecycle.
2. Check route visibility, pause, track change, seek, return-to-player, and no-lyric states for leftover work.
3. Format, analyze, and diff-check changed files; do not run a full build unless requested.
4. Performance claims require runtime comparison with the same track, window, and style, covering stable playback and repeated track changes. Static analysis alone is not performance evidence.
