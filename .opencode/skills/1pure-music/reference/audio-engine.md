# Audio Engine (BASS)

## Core File
`lib/native/bass/bass_player.dart` — 1600+ lines, full BASS audio layer.

## Init Sequence
1. Determine BASS DLL dir: `<exe>/dll/BASS/` or `cwd/dll/BASS/`
2. `SetDllDirectoryW` → fallback to `SetEnvironmentVariableW PATH`
3. Load `bass.dll` → `basswasapi.dll` → wildcard `BASS_PluginLoad` (skips core DLLs)
4. `_loadBassFx()` for `bass_fx.dll` (tempo/pitch)
5. `_bassInit()`: `BASS_Free()` → `BASS_Init(-1, 44100, 0, null, null)` + config buffer 500ms

## Two Output Modes

### Shared Mode (default)
- `BASS_SAMPLE_FLOAT | BASS_ASYNCFILE` flags
- Wraps stream in `BASS_FX_TempoCreate` for tempo/pitch support
- EQ via `BASS_FX_BFX_PEAKEQ` (preferred) or `BASS_FX_DX8_PARAMEQ`
- Crossfade on track change (300ms fade-out + delayed cleanup, 200ms fade-in)

### WASAPI Exclusive Mode
- `BASS_STREAM_DECODE | BASS_WASAPI_EXCLUSIVE | BASS_WASAPI_AUTOFORMAT | BASS_WASAPI_EVENT | BASS_WASAPI_BUFFER`
- Decoding channel only; actual output via `BASS_WASAPI_Start/FREE`
- Buffer size dynamic: 0.10s (≤44.1kHz) to 0.20s (≥96kHz)
- Position = decoded bytes - WASAPI buffer residue
- EQ/tempo/pitch NOT available → auto-fallback to shared mode
- Retry 3x on `BASS_ERROR_BUSY` with 50ms sleep between attempts

## EQ System (10 bands)
- Center freqs: 80, 100, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 Hz
- Bandwidth adaptive: 28 (low) → 8 (high) octaves
- BFX_PEAKEQ preferred; falls back to DX8_PARAMEQ
- All-zero EQ = flat detection → `_removeEQ()` to bypass
- EQ active → blocks exclusive mode via guard in `useExclusiveMode()`

## Crossfade
- `_fadeOutOldStream(handle, durationMs: 300, delayCleanup: true)` — old handle freed via Timer
- `_fadeInNewStream(handle, targetVolume)` — 200ms slide from 0 to target
- WASAPI exclusive: immediate stop+free, no crossfade

## Spectrum
- FFT-512 from `BASS_ChannelGetData` (shared) or `BASS_WASAPI_GetData` (exclusive)
- 8 log bands (45Hz–16kHz), only first 4 active
- Attack/release IIR smoothing: attack=0.6, release=0.4
- Tick period: 66ms spectrum, 33ms position (when listeners active)
- Idle period: 200ms

## Position Updater
- Timer.periodic with versioning token (`_positionUpdaterVersion`)
- On track change: version++ to cancel stale timers
- Checks `PlayerState.stopped` every ~6 ticks to emit `PlayerState.completed`

## Tempo / Pitch (shared mode only)
- `BASS_ATTRIB_TEMPO` via BASS_FX: tempo = (rate - 1.0) * 100%
- `BASS_ATTRIB_TEMPO_PITCH`: semitone offset
- Exclusive mode: auto-fallback to shared, logs warning

## ReplayGain
- Read via Rust FFI (`readAudioExtraMetadata`) → `replaygain_track_gain` tag
- Applied as VOLDSP offset through EqualizerService
