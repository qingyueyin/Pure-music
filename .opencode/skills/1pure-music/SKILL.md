---
name: 1pure-music
description: Pure-music Windows 本地音乐播放器。Flutter/Dart 前端 + Rust 后端（FFI/BASS/FRB）。Use when: modifying project code, understanding architecture, fixing bugs, adding features. Covers audio engine, lyric pipeline, player performance budget, theming, music library, build config.
---

## Core Patterns

- **Audio engine**: BASS via raw `dart:ffi` (NOT FRB). Two output modes: shared (EQ + tempo/pitch supported) vs WASAPI exclusive (pure decode, no EQ). Exclusive auto-fallback to shared on EQ enable.
- **Flutter-Rust bridge**: `flutter_rust_bridge` v2.12.0. Rust API at `rust/src/api/`. FRB re-generate via `flutter_rust_bridge_codegen generate`.
- **State management**: `Provider` + `ChangeNotifier`. Services are singletons (`PlayService.instance`, `ThemeProvider.instance`). Streams for position/spectrum/lyric-line events. `ValueNotifier` for simple state (nowPlaying, wasapiExclusive).
- **Lyric engine**: YRC > QRC > KRC > TTML > LRC priority (external files first, then embedded tags). Multi-format parser unified into `SyncLyricLine`/`UnsyncLyricLine` types. Auto-translation pairing for karaoke formats.
- **Theme**: Material You via `ColorScheme.fromSeed()`. Seed color comes from Rust k-means (`color_extraction.rs`); do not add a Dart palette generator. Player background uses mesh-gradient or cover blur.
- **Music library DB**: SQLite (rusqlite on Rust side for index, dart sqlite3 for app data). WAL mode. Migrated from JSON (`index.json`) to SQLite (`library.sqlite`).
- **Online lyrics**: 3 sources (QQ, Netease, Kugou). Netease uses Rust-side AES encrypt/decrypt (`ne.rs`). Source preference persisted per-track in DB.
- **Crossfade**: `BASS_ChannelSlideAttribute` for old-stream fade-out (300ms) + new-stream fade-in (200ms). Shared mode only; exclusive mode releases immediately.
- **Memory management**: LRU caches for lyrics (32 entries), cover images (96 Rust-side), album seed colors (50). Dart ImageCache capped at 15 images / 12MB. Low-memory callback trims all caches.
- **Player performance budget**: New visuals must reuse discrete playback sync signals and shared/local clocks. No per-component high-frequency position subscription, always-on Ticker, per-frame FFI/image work, whole-page rebuild, or unbounded cache. Read `reference/player-performance.md` before changing player visuals or animation.
- **Now Playing cover transition**: Three-tier progressive loading (immediate 48×48 → async full-size → 260ms debounced hi-res) + parent-child cover sharing via `findAncestorStateOfType`. `dispose()` must NOT null cover data fields — background blur keeps working during pop transition. `BlurCoverBackground` must NOT re-blur on hi-res cover ready (use 48×48 smallBytes as stable source).
- **Settings persistence**: JSON file (`settings.json`) with atomic write (tmp + rename). Portable mode uses `exe/data/`, otherwise `%APPDATA%/pure_music/`.

## Reference Files

| File | Content | When to load |
|------|---------|--------------|
| `reference/audio-engine.md` | BASS init, stream modes, EQ, WASAPI, crossfade, spectrum | Working on audio playback, EQ, output mode |
| `reference/cover-transition.md` | Now Playing cover lifecycle: progressive loading, parent-child sharing, dispose rules, blur re-blur gotcha | Debugging cover flash / transition smoothness issues on player page |
| `reference/player-performance.md` | Mandatory frame-driving, visibility, per-frame work, cache, release and verification rules | Adding or changing player visuals, animation, lyrics, progress or dynamic background |

## Key Workflows

**Adding new audio format support**: Update `SUPPORTED_FORMATS` phf_map in `rust/src/api/tag_reader.rs`, add BASS plugin DLL to `BASS/` directory, ensure `bass_player.dart` auto-loads it via `BASS_PluginLoad`.

**Adding new online lyric source**: Create source file in `lib/services/online_lyric/sources/`, add parser in `parsers/`, register source logic in `lib/lyric/lyric_source.dart`, update preferred source enum.

**Regenerating FRB bindings after Rust change**: Run `flutter_rust_bridge_codegen generate` from project root. YAML config at `flutter_rust_bridge.yaml` (input: `rust/src/api/**/*.rs`, output: `lib/native/rust`).

**Building release**: `flutter build windows --release`. Portable by default (`PORTABLE_BUILD` env var). BASS DLLs expected at `<exe>/dll/BASS/`.

**Modifying protected features** (per AGENTS.md): Must notify user before touching original/translation/romanization group management, pitch control, or the Now Playing cover transition lifecycle.
