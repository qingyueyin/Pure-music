#[cfg(target_os = "windows")]
mod windows_executor {
    use std::collections::HashMap;
    use std::ffi::{c_char, c_void, CString, OsStr};
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;
    use std::ptr;
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex, OnceLock, RwLock};
    use std::thread;
    use std::time::{Duration, Instant};

    use serde::{Deserialize, Serialize};

    use crate::frb_generated::StreamSink;
    use crate::smart_transition::model::{
        validate_transition_plan, GainPoint, TransitionMode, TransitionPlan,
    };

    const BASS_POS_BYTE: u32 = 0;
    const BASS_ATTRIB_VOL: u32 = 2;
    const BASS_MIXER_CHAN_ABSOLUTE: u32 = 0x1000;
    const BASS_MIXER_CHAN_DOWNMIX: u32 = 0x400000;
    const BASS_MIXER_CHAN_NORAMPIN: u32 = 0x800000;
    const BASS_MIXER_ENV_VOL: u32 = 2;
    const BASS_SYNC_POS: u32 = 0;
    const BASS_SYNC_END: u32 = 2;
    const BASS_SYNC_ONETIME: u32 = 0x80000000;
    const BASS_SYNC_MIXER_ENVELOPE: u32 = 0x10200;
    const BASS_SYNC_MIXER_ENVELOPE_NODE: u32 = 0x10201;
    const INVALID_POSITION: u64 = u64::MAX;

    const STATE_PREPARED: u8 = 0;
    const STATE_ARMED: u8 = 1;
    const STATE_STARTED: u8 = 2;
    const STATE_COMPLETING: u8 = 3;
    const STATE_COMPLETED: u8 = 4;
    const STATE_CANCELLING: u8 = 5;
    const STATE_CANCELLED: u8 = 6;
    const STATE_FAILED: u8 = 7;
    const STATE_FINALIZING: u8 = 8;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct MixerNode {
        position: u64,
        value: f32,
    }

    #[repr(C)]
    struct BassChannelInfo {
        frequency: u32,
        channels: u32,
        flags: u32,
        channel_type: u32,
        original_resolution: u32,
        plugin: u32,
        sample: u32,
        filename: *const c_char,
    }

    type SyncProc = unsafe extern "system" fn(u32, u32, u32, *mut c_void);
    type BassErrorGetCode = unsafe extern "system" fn() -> i32;
    type BassChannelGetInfo = unsafe extern "system" fn(u32, *mut BassChannelInfo) -> i32;
    type BassChannelGetPosition = unsafe extern "system" fn(u32, u32) -> u64;
    type BassChannelSetPosition = unsafe extern "system" fn(u32, u64, u32) -> i32;
    type BassChannelSeconds2Bytes = unsafe extern "system" fn(u32, f64) -> u64;
    type BassChannelBytes2Seconds = unsafe extern "system" fn(u32, u64) -> f64;
    type BassChannelSetAttribute = unsafe extern "system" fn(u32, u32, f32) -> i32;
    type BassStreamFree = unsafe extern "system" fn(u32) -> i32;
    type BassMixerGetVersion = unsafe extern "system" fn() -> u32;
    type BassMixerStreamAddChannelEx = unsafe extern "system" fn(u32, u32, u32, u64, u64) -> i32;
    type BassMixerChannelRemove = unsafe extern "system" fn(u32) -> i32;
    type BassMixerChannelGetPosition = unsafe extern "system" fn(u32, u32) -> u64;
    type BassMixerChannelSetSync =
        unsafe extern "system" fn(u32, u32, u64, Option<SyncProc>, *mut c_void) -> u32;
    type BassMixerChannelRemoveSync = unsafe extern "system" fn(u32, u32) -> i32;
    type BassMixerChannelSetEnvelope =
        unsafe extern "system" fn(u32, u32, *const MixerNode, u32) -> i32;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn LoadLibraryW(filename: *const u16) -> *mut c_void;
        fn GetProcAddress(module: *mut c_void, name: *const u8) -> *mut c_void;
    }

    struct BassApi {
        bass_version: u32,
        bassmix_version: u32,
        error_get_code: BassErrorGetCode,
        channel_get_info: BassChannelGetInfo,
        channel_get_position: BassChannelGetPosition,
        channel_set_position: BassChannelSetPosition,
        channel_seconds_to_bytes: BassChannelSeconds2Bytes,
        channel_bytes_to_seconds: BassChannelBytes2Seconds,
        channel_set_attribute: BassChannelSetAttribute,
        stream_free: BassStreamFree,
        mixer_stream_add_channel_ex: BassMixerStreamAddChannelEx,
        mixer_channel_remove: BassMixerChannelRemove,
        mixer_channel_get_position: BassMixerChannelGetPosition,
        mixer_channel_set_sync: BassMixerChannelSetSync,
        mixer_channel_remove_sync: BassMixerChannelRemoveSync,
        mixer_channel_set_envelope: BassMixerChannelSetEnvelope,
    }

    unsafe impl Send for BassApi {}
    unsafe impl Sync for BassApi {}

    impl BassApi {
        fn load(bass_dir: &str) -> Result<Self, String> {
            let bass_module = load_library(&Path::new(bass_dir).join("bass.dll"))?;
            let mix_module = load_library(&Path::new(bass_dir).join("bassmix.dll"))?;
            let get_version: unsafe extern "system" fn() -> u32 =
                unsafe { required(bass_module, "BASS_GetVersion")? };
            let mixer_get_version: BassMixerGetVersion =
                unsafe { required(mix_module, "BASS_Mixer_GetVersion")? };
            let api = Self {
                bass_version: unsafe { get_version() },
                bassmix_version: unsafe { mixer_get_version() },
                error_get_code: unsafe { required(bass_module, "BASS_ErrorGetCode")? },
                channel_get_info: unsafe { required(bass_module, "BASS_ChannelGetInfo")? },
                channel_get_position: unsafe { required(bass_module, "BASS_ChannelGetPosition")? },
                channel_set_position: unsafe { required(bass_module, "BASS_ChannelSetPosition")? },
                channel_seconds_to_bytes: unsafe {
                    required(bass_module, "BASS_ChannelSeconds2Bytes")?
                },
                channel_bytes_to_seconds: unsafe {
                    required(bass_module, "BASS_ChannelBytes2Seconds")?
                },
                channel_set_attribute: unsafe {
                    required(bass_module, "BASS_ChannelSetAttribute")?
                },
                stream_free: unsafe { required(bass_module, "BASS_StreamFree")? },
                mixer_stream_add_channel_ex: unsafe {
                    required(mix_module, "BASS_Mixer_StreamAddChannelEx")?
                },
                mixer_channel_remove: unsafe { required(mix_module, "BASS_Mixer_ChannelRemove")? },
                mixer_channel_get_position: unsafe {
                    required(mix_module, "BASS_Mixer_ChannelGetPosition")?
                },
                mixer_channel_set_sync: unsafe {
                    required(mix_module, "BASS_Mixer_ChannelSetSync")?
                },
                mixer_channel_remove_sync: unsafe {
                    required(mix_module, "BASS_Mixer_ChannelRemoveSync")?
                },
                mixer_channel_set_envelope: unsafe {
                    required(mix_module, "BASS_Mixer_ChannelSetEnvelope")?
                },
            };
            if api.bassmix_version < 0x02040c00 {
                return Err(format!(
                    "BASSmix 2.4.12 or newer is required, found {:08x}",
                    api.bassmix_version
                ));
            }
            Ok(api)
        }

        fn last_error(&self) -> i32 {
            unsafe { (self.error_get_code)() }
        }

        fn frame_bytes(&self, channel: u32) -> Result<u64, String> {
            let mut info = BassChannelInfo {
                frequency: 0,
                channels: 0,
                flags: 0,
                channel_type: 0,
                original_resolution: 0,
                plugin: 0,
                sample: 0,
                filename: ptr::null(),
            };
            if unsafe { (self.channel_get_info)(channel, &mut info) } == 0 || info.channels == 0 {
                return Err(format!("BASS_ChannelGetInfo failed: {}", self.last_error()));
            }
            Ok(u64::from(info.channels) * 4)
        }
    }

    fn load_library(path: &Path) -> Result<*mut c_void, String> {
        let wide = OsStr::new(path)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect::<Vec<_>>();
        let module = unsafe { LoadLibraryW(wide.as_ptr()) };
        if module.is_null() {
            Err(format!("failed to load {}", path.display()))
        } else {
            Ok(module)
        }
    }

    unsafe fn required<T: Copy>(module: *mut c_void, name: &str) -> Result<T, String> {
        let name = CString::new(name).map_err(|error| error.to_string())?;
        let address = unsafe { GetProcAddress(module, name.as_ptr().cast()) };
        if address.is_null() {
            return Err(format!("missing native symbol {}", name.to_string_lossy()));
        }
        Ok(unsafe { std::mem::transmute_copy(&address) })
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    pub struct ArmRequest {
        transition_id: u64,
        source_generation: u64,
        mixer_handle: u32,
        outgoing_handle: u32,
        incoming_handle: u32,
        incoming_path: String,
        incoming_replay_gain_db: Option<f64>,
        plan: TransitionPlan,
    }

    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Capabilities {
        available: bool,
        bass_version: u32,
        bassmix_version: u32,
        absolute_scheduling: bool,
        envelope: bool,
        playback_sync: bool,
        tempo_at_cue: bool,
        error: Option<String>,
    }

    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Snapshot {
        transition_id: u64,
        source_generation: u64,
        state: &'static str,
        incoming_handle: u32,
        outgoing_handle: u32,
        mixer_handle: u32,
        incoming_path: String,
        incoming_replay_gain_db: Option<f64>,
        adopted: bool,
        outgoing_detached: bool,
        envelope: Option<EnvelopeDiagnostics>,
        error: Option<String>,
        last_bass_error: i32,
    }

    #[derive(Clone, Serialize)]
    #[serde(rename_all = "camelCase")]
    struct EnvelopeNodeProbe {
        position_bytes: u64,
        position_seconds: f64,
        value: f32,
    }

    #[derive(Clone, Serialize)]
    #[serde(rename_all = "camelCase")]
    struct EnvelopeDiagnostics {
        delay_bytes: u64,
        delay_seconds: f64,
        duration_bytes: u64,
        duration_seconds: f64,
        outgoing_nodes: [EnvelopeNodeProbe; 3],
        incoming_nodes: [EnvelopeNodeProbe; 3],
    }

    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct ArmOutcome {
        accepted: bool,
        snapshot: Option<Snapshot>,
        error: Option<String>,
    }

    struct RawSyncSlot {
        source: u32,
        sync: u32,
        callback_id: u64,
    }

    struct Context {
        api: Arc<BassApi>,
        transition_id: u64,
        source_generation: u64,
        mixer_handle: u32,
        outgoing_handle: u32,
        incoming_handle: u32,
        incoming_path: String,
        incoming_replay_gain_db: Option<f64>,
        overlap: bool,
        state: AtomicU8,
        quiescing: AtomicBool,
        callback_in_flight: AtomicUsize,
        started_pending: AtomicBool,
        terminal_pending: AtomicBool,
        started_emitted: AtomicBool,
        terminal_emitted: AtomicBool,
        adopted: AtomicBool,
        outgoing_detached: AtomicBool,
        event_sequence: AtomicU64,
        slots: Mutex<Vec<RawSyncSlot>>,
        envelope: Mutex<Option<EnvelopeDiagnostics>>,
        error: Mutex<Option<String>>,
        last_bass_error: AtomicU64,
    }

    impl Context {
        fn snapshot(&self) -> Snapshot {
            Snapshot {
                transition_id: self.transition_id,
                source_generation: self.source_generation,
                state: state_name(self.state.load(Ordering::Acquire)),
                incoming_handle: self.incoming_handle,
                outgoing_handle: self.outgoing_handle,
                mixer_handle: self.mixer_handle,
                incoming_path: self.incoming_path.clone(),
                incoming_replay_gain_db: self.incoming_replay_gain_db,
                adopted: self.adopted.load(Ordering::Acquire),
                outgoing_detached: self.outgoing_detached.load(Ordering::Acquire),
                envelope: self
                    .envelope
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .clone(),
                error: self
                    .error
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .clone(),
                last_bass_error: self.last_bass_error.load(Ordering::Acquire) as i32,
            }
        }

        fn record_error(&self, message: String) {
            self.last_bass_error
                .store(self.api.last_error() as u64, Ordering::Release);
            *self.error.lock().unwrap_or_else(|error| error.into_inner()) = Some(message);
        }
    }

    const CALLBACK_START_NODE: u8 = 1;
    const CALLBACK_START_POSITION: u8 = 2;
    const CALLBACK_COMPLETE: u8 = 3;

    struct CallbackSlot {
        context: Arc<Context>,
        kind: u8,
    }

    unsafe extern "system" fn sync_trampoline(
        _sync: u32,
        _channel: u32,
        data: u32,
        user: *mut c_void,
    ) {
        if user.is_null() {
            return;
        }
        let callback_id = user as usize as u64;
        let slot = {
            executor()
                .callback_slots
                .read()
                .unwrap_or_else(|error| error.into_inner())
                .get(&callback_id)
                .cloned()
        };
        let Some(slot) = slot else {
            return;
        };
        let context = &slot.context;
        context.callback_in_flight.fetch_add(1, Ordering::AcqRel);
        if !context.quiescing.load(Ordering::Acquire) {
            match slot.kind {
                CALLBACK_START_NODE if data >> 16 == 1 => {
                    if context
                        .state
                        .compare_exchange(
                            STATE_ARMED,
                            STATE_STARTED,
                            Ordering::AcqRel,
                            Ordering::Acquire,
                        )
                        .is_ok()
                    {
                        context.started_pending.store(true, Ordering::Release);
                    }
                }
                CALLBACK_START_POSITION => {
                    if context
                        .state
                        .compare_exchange(
                            STATE_ARMED,
                            STATE_STARTED,
                            Ordering::AcqRel,
                            Ordering::Acquire,
                        )
                        .is_ok()
                    {
                        context.started_pending.store(true, Ordering::Release);
                    }
                }
                CALLBACK_COMPLETE => {
                    if context
                        .state
                        .compare_exchange(
                            STATE_STARTED,
                            STATE_COMPLETING,
                            Ordering::AcqRel,
                            Ordering::Acquire,
                        )
                        .is_ok()
                    {
                        context.terminal_pending.store(true, Ordering::Release);
                    }
                }
                _ => {}
            }
        }
        context.callback_in_flight.fetch_sub(1, Ordering::AcqRel);
    }

    struct Executor {
        api: Mutex<Option<Arc<BassApi>>>,
        contexts: Mutex<HashMap<u64, Arc<Context>>>,
        callback_slots: RwLock<HashMap<u64, Arc<CallbackSlot>>>,
        next_callback_id: AtomicU64,
        deferred_reclaims: AtomicUsize,
        sink: RwLock<Option<StreamSink<String>>>,
        worker_started: AtomicBool,
    }

    fn executor() -> &'static Executor {
        static EXECUTOR: OnceLock<Executor> = OnceLock::new();
        EXECUTOR.get_or_init(|| Executor {
            api: Mutex::new(None),
            contexts: Mutex::new(HashMap::new()),
            callback_slots: RwLock::new(HashMap::new()),
            next_callback_id: AtomicU64::new(1),
            deferred_reclaims: AtomicUsize::new(0),
            sink: RwLock::new(None),
            worker_started: AtomicBool::new(false),
        })
    }

    impl Executor {
        fn initialize(&self, bass_dir: &str) -> Result<Arc<BassApi>, String> {
            let mut api = self.api.lock().unwrap_or_else(|error| error.into_inner());
            if let Some(api) = api.as_ref() {
                return Ok(api.clone());
            }
            let loaded = Arc::new(BassApi::load(bass_dir)?);
            *api = Some(loaded.clone());
            self.ensure_worker();
            Ok(loaded)
        }

        fn ensure_worker(&self) {
            if self
                .worker_started
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                thread::Builder::new()
                    .name("smart-transition-events".to_string())
                    .spawn(worker_loop)
                    .expect("failed to start smart transition event worker");
            }
        }

        fn emit(&self, context: &Context, event: &str) {
            let sequence = context.event_sequence.fetch_add(1, Ordering::AcqRel) + 1;
            let payload = serde_json::json!({
                "event": event,
                "eventSequence": sequence,
                "snapshot": context.snapshot(),
            });
            let Ok(json) = serde_json::to_string(&payload) else {
                return;
            };
            let sink = self.sink.read().unwrap_or_else(|error| error.into_inner());
            if let Some(sink) = sink.as_ref() {
                let _ = sink.add(json);
            }
        }
    }

    fn worker_loop() {
        loop {
            let contexts = executor()
                .contexts
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .values()
                .cloned()
                .collect::<Vec<_>>();
            for context in contexts {
                if context.started_pending.swap(false, Ordering::AcqRel)
                    && !context.started_emitted.swap(true, Ordering::AcqRel)
                {
                    executor().emit(&context, "started");
                    if !context.overlap
                        && context
                            .state
                            .compare_exchange(
                                STATE_STARTED,
                                STATE_COMPLETING,
                                Ordering::AcqRel,
                                Ordering::Acquire,
                            )
                            .is_ok()
                    {
                        context.terminal_pending.store(true, Ordering::Release);
                    }
                }
                if context.terminal_pending.swap(false, Ordering::AcqRel) {
                    finish_started(&context);
                }
                let state = context.state.load(Ordering::Acquire);
                if matches!(state, STATE_CANCELLED | STATE_FAILED)
                    && !context.terminal_emitted.swap(true, Ordering::AcqRel)
                {
                    executor().emit(
                        &context,
                        if state == STATE_FAILED {
                            "failed"
                        } else {
                            "cancelled"
                        },
                    );
                } else if state == STATE_COMPLETED
                    && !context.terminal_emitted.swap(true, Ordering::AcqRel)
                {
                    executor().emit(&context, "completed");
                }
            }
            thread::sleep(Duration::from_millis(4));
        }
    }

    pub fn init_events(bass_dir: String, sink: StreamSink<String>) -> Result<(), String> {
        executor().initialize(&bass_dir)?;
        *executor()
            .sink
            .write()
            .unwrap_or_else(|error| error.into_inner()) = Some(sink);
        Ok(())
    }

    pub fn close_events() {
        *executor()
            .sink
            .write()
            .unwrap_or_else(|error| error.into_inner()) = None;
    }

    pub fn capabilities_json(bass_dir: String) -> String {
        match executor().initialize(&bass_dir) {
            Ok(api) => serde_json::to_string(&Capabilities {
                available: true,
                bass_version: api.bass_version,
                bassmix_version: api.bassmix_version,
                absolute_scheduling: true,
                envelope: true,
                playback_sync: true,
                tempo_at_cue: false,
                error: None,
            })
            .unwrap_or_default(),
            Err(error) => serde_json::to_string(&Capabilities {
                available: false,
                bass_version: 0,
                bassmix_version: 0,
                absolute_scheduling: false,
                envelope: false,
                playback_sync: false,
                tempo_at_cue: false,
                error: Some(error),
            })
            .unwrap_or_default(),
        }
    }

    pub fn arm_json(bass_dir: String, request_json: String) -> String {
        let request: ArmRequest = match serde_json::from_str(&request_json) {
            Ok(request) => request,
            Err(error) => return outcome_json(false, None, Some(error.to_string())),
        };
        if let Err(error) = validate_transition_plan(&request.plan) {
            return outcome_json(false, None, Some(error.to_string()));
        }
        if request.transition_id == 0
            || request.mixer_handle == 0
            || request.outgoing_handle == 0
            || request.incoming_handle == 0
        {
            return outcome_json(
                false,
                None,
                Some("zero transition or BASS handle".to_string()),
            );
        }
        let api = match executor().initialize(&bass_dir) {
            Ok(api) => api,
            Err(error) => return outcome_json(false, None, Some(error)),
        };
        {
            let contexts = executor()
                .contexts
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            if let Some(existing) = contexts.get(&request.transition_id) {
                return outcome_json(true, Some(existing.snapshot()), None);
            }
            if contexts.values().any(|context| {
                !matches!(
                    context.state.load(Ordering::Acquire),
                    STATE_COMPLETED | STATE_CANCELLED | STATE_FAILED
                )
            }) {
                return outcome_json(false, None, Some("native transition is busy".to_string()));
            }
        }
        let overlap = matches!(
            request.plan.mode,
            TransitionMode::EnergyCrossfade
                | TransitionMode::BeatAligned
                | TransitionMode::BeatMatched
        );
        let context = Arc::new(Context {
            api: api.clone(),
            transition_id: request.transition_id,
            source_generation: request.source_generation,
            mixer_handle: request.mixer_handle,
            outgoing_handle: request.outgoing_handle,
            incoming_handle: request.incoming_handle,
            incoming_path: request.incoming_path,
            incoming_replay_gain_db: request.incoming_replay_gain_db,
            overlap,
            state: AtomicU8::new(STATE_PREPARED),
            quiescing: AtomicBool::new(false),
            callback_in_flight: AtomicUsize::new(0),
            started_pending: AtomicBool::new(false),
            terminal_pending: AtomicBool::new(false),
            started_emitted: AtomicBool::new(false),
            terminal_emitted: AtomicBool::new(false),
            adopted: AtomicBool::new(false),
            outgoing_detached: AtomicBool::new(false),
            event_sequence: AtomicU64::new(0),
            slots: Mutex::new(Vec::new()),
            envelope: Mutex::new(None),
            error: Mutex::new(None),
            last_bass_error: AtomicU64::new(0),
        });
        executor()
            .contexts
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .insert(context.transition_id, context.clone());
        if let Err(error) = schedule(&context, &request.plan) {
            context.record_error(error.clone());
            rollback_prestart(&context, STATE_FAILED);
            return outcome_json(true, Some(context.snapshot()), Some(error));
        }
        context.state.store(STATE_ARMED, Ordering::Release);
        outcome_json(true, Some(context.snapshot()), None)
    }

    fn schedule(context: &Arc<Context>, plan: &TransitionPlan) -> Result<(), String> {
        let api = &context.api;
        let outgoing_position =
            unsafe { (api.mixer_channel_get_position)(context.outgoing_handle, BASS_POS_BYTE) };
        if outgoing_position == INVALID_POSITION {
            return Err(format!(
                "outgoing mixer position unavailable: {}",
                api.last_error()
            ));
        }
        let outgoing_seconds =
            unsafe { (api.channel_bytes_to_seconds)(context.outgoing_handle, outgoing_position) };
        let remaining_source_seconds = plan.outgoing_cue_ms as f64 / 1000.0 - outgoing_seconds;
        if !remaining_source_seconds.is_finite() || remaining_source_seconds <= 0.10 {
            return Err("plan_late: outgoing cue is too close or already passed".to_string());
        }
        let delay_seconds = remaining_source_seconds / plan.outgoing_effective_speed.max(1e-6);
        let mixer_position =
            unsafe { (api.channel_get_position)(context.mixer_handle, BASS_POS_BYTE) };
        if mixer_position == INVALID_POSITION {
            return Err(format!("mixer position unavailable: {}", api.last_error()));
        }
        let delay_bytes =
            unsafe { (api.channel_seconds_to_bytes)(context.mixer_handle, delay_seconds) };
        let absolute_start = mixer_position.saturating_add(delay_bytes);
        let incoming_position = unsafe {
            (api.channel_seconds_to_bytes)(
                context.incoming_handle,
                plan.incoming_cue_ms as f64 / 1000.0,
            )
        };
        if unsafe {
            (api.channel_set_position)(context.incoming_handle, incoming_position, BASS_POS_BYTE)
        } == 0
        {
            return Err(format!("incoming seek failed: {}", api.last_error()));
        }
        if unsafe { (api.channel_set_attribute)(context.incoming_handle, BASS_ATTRIB_VOL, 1.0) }
            == 0
        {
            return Err(format!(
                "incoming volume restore failed: {}",
                api.last_error()
            ));
        }
        let flags = BASS_MIXER_CHAN_ABSOLUTE | BASS_MIXER_CHAN_DOWNMIX | BASS_MIXER_CHAN_NORAMPIN;
        if unsafe {
            (api.mixer_stream_add_channel_ex)(
                context.mixer_handle,
                context.incoming_handle,
                flags,
                absolute_start,
                0,
            )
        } == 0
        {
            return Err(format!(
                "BASS_Mixer_StreamAddChannelEx failed: {}",
                api.last_error()
            ));
        }
        let mixer_frame_bytes = api.frame_bytes(context.mixer_handle)?;
        let incoming_frame_bytes = api.frame_bytes(context.incoming_handle)?;
        if context.overlap {
            let duration_bytes = unsafe {
                (api.channel_seconds_to_bytes)(
                    context.mixer_handle,
                    plan.duration_ms as f64 / 1000.0,
                )
            }
            .max(mixer_frame_bytes);
            let incoming_nodes =
                incoming_nodes(&plan.gain_curve, duration_bytes, mixer_frame_bytes);
            if unsafe {
                (api.mixer_channel_set_envelope)(
                    context.incoming_handle,
                    BASS_MIXER_ENV_VOL,
                    incoming_nodes.as_ptr(),
                    incoming_nodes.len() as u32,
                )
            } == 0
            {
                return Err(format!("incoming envelope failed: {}", api.last_error()));
            }
            let outgoing_nodes = outgoing_nodes(&plan.gain_curve, delay_bytes, duration_bytes);
            if unsafe {
                (api.mixer_channel_set_envelope)(
                    context.outgoing_handle,
                    BASS_MIXER_ENV_VOL,
                    outgoing_nodes.as_ptr(),
                    outgoing_nodes.len() as u32,
                )
            } == 0
            {
                return Err(format!("outgoing envelope failed: {}", api.last_error()));
            }
            *context
                .envelope
                .lock()
                .unwrap_or_else(|error| error.into_inner()) = Some(envelope_diagnostics(
                api,
                context.mixer_handle,
                delay_bytes,
                duration_bytes,
                &outgoing_nodes,
                &incoming_nodes,
            ));
            add_sync(
                context,
                context.incoming_handle,
                BASS_SYNC_MIXER_ENVELOPE_NODE,
                BASS_MIXER_ENV_VOL as u64,
                CALLBACK_START_NODE,
            )?;
            add_sync(
                context,
                context.outgoing_handle,
                BASS_SYNC_MIXER_ENVELOPE,
                BASS_MIXER_ENV_VOL as u64,
                CALLBACK_COMPLETE,
            )?;
            add_sync(
                context,
                context.outgoing_handle,
                BASS_SYNC_END | BASS_SYNC_ONETIME,
                0,
                CALLBACK_COMPLETE,
            )?;
        } else {
            if matches!(plan.mode, TransitionMode::SilenceTrim) {
                let trim_nodes = [
                    MixerNode {
                        position: 0,
                        value: 1.0,
                    },
                    MixerNode {
                        position: delay_bytes,
                        value: 1.0,
                    },
                    MixerNode {
                        position: delay_bytes.saturating_add(mixer_frame_bytes),
                        value: 0.0,
                    },
                ];
                if unsafe {
                    (api.mixer_channel_set_envelope)(
                        context.outgoing_handle,
                        BASS_MIXER_ENV_VOL,
                        trim_nodes.as_ptr(),
                        trim_nodes.len() as u32,
                    )
                } == 0
                {
                    return Err(format!(
                        "silence trim envelope failed: {}",
                        api.last_error()
                    ));
                }
            }
            add_sync(
                context,
                context.incoming_handle,
                BASS_SYNC_POS | BASS_SYNC_ONETIME,
                incoming_position.saturating_add(incoming_frame_bytes),
                CALLBACK_START_POSITION,
            )?;
        }
        Ok(())
    }

    fn envelope_diagnostics(
        api: &BassApi,
        mixer: u32,
        delay_bytes: u64,
        duration_bytes: u64,
        outgoing_nodes: &[MixerNode],
        incoming_nodes: &[MixerNode],
    ) -> EnvelopeDiagnostics {
        EnvelopeDiagnostics {
            delay_bytes,
            delay_seconds: unsafe { (api.channel_bytes_to_seconds)(mixer, delay_bytes) },
            duration_bytes,
            duration_seconds: unsafe { (api.channel_bytes_to_seconds)(mixer, duration_bytes) },
            outgoing_nodes: envelope_node_probes(api, mixer, outgoing_nodes),
            incoming_nodes: envelope_node_probes(api, mixer, incoming_nodes),
        }
    }

    fn envelope_node_probes(
        api: &BassApi,
        mixer: u32,
        nodes: &[MixerNode],
    ) -> [EnvelopeNodeProbe; 3] {
        let indices = [0, nodes.len() / 2, nodes.len() - 1];
        indices.map(|index| {
            let node = nodes[index];
            EnvelopeNodeProbe {
                position_bytes: node.position,
                position_seconds: unsafe { (api.channel_bytes_to_seconds)(mixer, node.position) },
                value: node.value,
            }
        })
    }

    fn incoming_nodes(curve: &[GainPoint], duration: u64, frame: u64) -> Vec<MixerNode> {
        let mut nodes = Vec::with_capacity(curve.len() + 1);
        nodes.push(MixerNode {
            position: 0,
            value: curve[0].incoming as f32,
        });
        let second_position = (duration / (curve.len() - 1) as u64).max(frame + 1);
        let marker_value = curve[0].incoming
            + (curve[1].incoming - curve[0].incoming) * frame as f64 / second_position as f64;
        nodes.push(MixerNode {
            position: frame,
            value: marker_value as f32,
        });
        for (index, point) in curve.iter().enumerate().skip(1) {
            nodes.push(MixerNode {
                position: duration.saturating_mul(index as u64)
                    / (curve.len().saturating_sub(1)) as u64,
                value: point.incoming as f32,
            });
        }
        nodes
    }

    fn outgoing_nodes(curve: &[GainPoint], delay: u64, duration: u64) -> Vec<MixerNode> {
        let mut nodes = Vec::with_capacity(curve.len() + 1);
        nodes.push(MixerNode {
            position: 0,
            value: 1.0,
        });
        if delay > 0 {
            nodes.push(MixerNode {
                position: delay,
                value: curve[0].outgoing as f32,
            });
        }
        for (index, point) in curve.iter().enumerate().skip(1) {
            nodes.push(MixerNode {
                position: delay.saturating_add(
                    duration.saturating_mul(index as u64) / (curve.len().saturating_sub(1)) as u64,
                ),
                value: point.outgoing as f32,
            });
        }
        nodes
    }

    fn add_sync(
        context: &Arc<Context>,
        source: u32,
        sync_type: u32,
        parameter: u64,
        kind: u8,
    ) -> Result<(), String> {
        let slot = Arc::new(CallbackSlot {
            context: context.clone(),
            kind,
        });
        let callback_id = executor().next_callback_id.fetch_add(1, Ordering::AcqRel);
        executor()
            .callback_slots
            .write()
            .unwrap_or_else(|error| error.into_inner())
            .insert(callback_id, slot);
        let sync = unsafe {
            (context.api.mixer_channel_set_sync)(
                source,
                sync_type,
                parameter,
                Some(sync_trampoline),
                callback_id as usize as *mut c_void,
            )
        };
        if sync == 0 {
            executor()
                .callback_slots
                .write()
                .unwrap_or_else(|error| error.into_inner())
                .remove(&callback_id);
            return Err(format!(
                "BASS_Mixer_ChannelSetSync failed: {}",
                context.api.last_error()
            ));
        }
        context
            .slots
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .push(RawSyncSlot {
                source,
                sync,
                callback_id,
            });
        Ok(())
    }

    fn rollback_prestart(context: &Arc<Context>, terminal_state: u8) {
        context.quiescing.store(true, Ordering::Release);
        cleanup_syncs(context);
        clear_envelopes(context);
        unsafe {
            (context.api.mixer_channel_remove)(context.incoming_handle);
            (context.api.stream_free)(context.incoming_handle);
            (context.api.channel_set_attribute)(context.outgoing_handle, BASS_ATTRIB_VOL, 1.0);
        }
        context.state.store(terminal_state, Ordering::Release);
        context.terminal_pending.store(false, Ordering::Release);
    }

    fn finish_started(context: &Arc<Context>) {
        if !claim_finish(&context.state) {
            return;
        }
        context.quiescing.store(true, Ordering::Release);
        cleanup_syncs(context);
        clear_envelopes(context);
        let removed = unsafe { (context.api.mixer_channel_remove)(context.outgoing_handle) } != 0;
        if removed || context.api.last_error() == 5 {
            context.outgoing_detached.store(true, Ordering::Release);
        } else {
            context.record_error(format!(
                "outgoing detach failed: {}",
                context.api.last_error()
            ));
        }
        context.state.store(STATE_COMPLETED, Ordering::Release);
    }

    fn claim_finish(state: &AtomicU8) -> bool {
        state
            .compare_exchange(
                STATE_COMPLETING,
                STATE_FINALIZING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
    }

    fn wait_for_finish(context: &Context) {
        while context.state.load(Ordering::Acquire) == STATE_FINALIZING {
            thread::yield_now();
        }
    }

    fn clear_envelopes(context: &Context) {
        unsafe {
            (context.api.mixer_channel_set_envelope)(
                context.outgoing_handle,
                BASS_MIXER_ENV_VOL,
                ptr::null(),
                0,
            );
            (context.api.mixer_channel_set_envelope)(
                context.incoming_handle,
                BASS_MIXER_ENV_VOL,
                ptr::null(),
                0,
            );
        }
    }

    fn cleanup_syncs(context: &Arc<Context>) {
        let slots = std::mem::take(
            &mut *context
                .slots
                .lock()
                .unwrap_or_else(|error| error.into_inner()),
        );
        for slot in &slots {
            unsafe {
                (context.api.mixer_channel_remove_sync)(slot.source, slot.sync);
            }
        }
        let retained_slots = {
            let mut callback_slots = executor()
                .callback_slots
                .write()
                .unwrap_or_else(|error| error.into_inner());
            slots
                .iter()
                .filter_map(|slot| callback_slots.remove(&slot.callback_id))
                .collect::<Vec<_>>()
        };
        let deadline = Instant::now() + Duration::from_millis(100);
        while context.callback_in_flight.load(Ordering::Acquire) != 0 && Instant::now() < deadline {
            thread::yield_now();
        }
        if context.callback_in_flight.load(Ordering::Acquire) == 0 {
            drop(retained_slots);
        } else {
            let context_id = context.transition_id;
            let context = context.clone();
            executor().deferred_reclaims.fetch_add(1, Ordering::AcqRel);
            let spawned = thread::Builder::new()
                .name(format!("smart-transition-reclaim-{context_id}"))
                .spawn(move || {
                    while context.callback_in_flight.load(Ordering::Acquire) != 0 {
                        thread::sleep(Duration::from_millis(1));
                    }
                    drop(retained_slots);
                    executor().deferred_reclaims.fetch_sub(1, Ordering::AcqRel);
                });
            if spawned.is_err() {
                executor().deferred_reclaims.fetch_sub(1, Ordering::AcqRel);
            }
        }
    }

    pub fn cancel_json(transition_id: u64, reason: String) -> String {
        let context = {
            executor()
                .contexts
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .get(&transition_id)
                .cloned()
        };
        let Some(context) = context else {
            return serde_json::to_string(&serde_json::json!({
                "transitionId": transition_id,
                "state": "missing",
            }))
            .unwrap_or_default();
        };
        loop {
            let state = context.state.load(Ordering::Acquire);
            match state {
                STATE_PREPARED | STATE_ARMED => {
                    if context
                        .state
                        .compare_exchange(
                            state,
                            STATE_CANCELLING,
                            Ordering::AcqRel,
                            Ordering::Acquire,
                        )
                        .is_ok()
                    {
                        context.record_error(reason.clone());
                        rollback_prestart(&context, STATE_CANCELLED);
                        break;
                    }
                }
                STATE_STARTED => {
                    if context
                        .state
                        .compare_exchange(
                            STATE_STARTED,
                            STATE_COMPLETING,
                            Ordering::AcqRel,
                            Ordering::Acquire,
                        )
                        .is_ok()
                    {
                        finish_started(&context);
                        break;
                    }
                }
                STATE_COMPLETING => {
                    finish_started(&context);
                    wait_for_finish(&context);
                    break;
                }
                STATE_FINALIZING => {
                    wait_for_finish(&context);
                    break;
                }
                _ => break,
            }
        }
        serde_json::to_string(&context.snapshot()).unwrap_or_default()
    }

    pub fn adopt_json(transition_id: u64) -> String {
        let context = {
            executor()
                .contexts
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .get(&transition_id)
                .cloned()
        };
        let Some(context) = context else {
            return "{\"state\":\"missing\"}".to_string();
        };
        if matches!(
            context.state.load(Ordering::Acquire),
            STATE_STARTED | STATE_COMPLETING | STATE_FINALIZING | STATE_COMPLETED
        ) {
            context.adopted.store(true, Ordering::Release);
        }
        serde_json::to_string(&context.snapshot()).unwrap_or_default()
    }

    pub fn snapshot_json(transition_id: u64) -> String {
        let contexts = executor()
            .contexts
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        contexts
            .get(&transition_id)
            .and_then(|context| serde_json::to_string(&context.snapshot()).ok())
            .unwrap_or_else(|| "{\"state\":\"missing\"}".to_string())
    }

    pub fn acknowledge(transition_id: u64) -> bool {
        let mut contexts = executor()
            .contexts
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let terminal = contexts.get(&transition_id).is_some_and(|context| {
            matches!(
                context.state.load(Ordering::Acquire),
                STATE_COMPLETED | STATE_CANCELLED | STATE_FAILED
            )
        });
        if terminal {
            contexts.remove(&transition_id);
        }
        terminal
    }

    pub fn diagnostics_json() -> String {
        let contexts = executor()
            .contexts
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let active = contexts
            .values()
            .max_by_key(|context| context.transition_id)
            .map(|context| context.snapshot());
        let (bass_version, bassmix_version) = executor()
            .api
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .as_ref()
            .map(|api| (api.bass_version, api.bassmix_version))
            .unwrap_or((0, 0));
        serde_json::to_string(&serde_json::json!({
            "bassVersion": bass_version,
            "bassmixVersion": bassmix_version,
            "activeContexts": contexts.len(),
            "callbackSlots": executor()
                .callback_slots
                .read()
                .unwrap_or_else(|error| error.into_inner())
                .len(),
            "deferredReclaims": executor().deferred_reclaims.load(Ordering::Acquire),
            "active": active,
            "tempoAtCue": false,
        }))
        .unwrap_or_default()
    }

    fn outcome_json(accepted: bool, snapshot: Option<Snapshot>, error: Option<String>) -> String {
        serde_json::to_string(&ArmOutcome {
            accepted,
            snapshot,
            error,
        })
        .unwrap_or_default()
    }

    fn state_name(state: u8) -> &'static str {
        match state {
            STATE_PREPARED => "prepared",
            STATE_ARMED => "armed",
            STATE_STARTED => "started",
            STATE_COMPLETING => "completing",
            STATE_COMPLETED => "completed",
            STATE_CANCELLING => "cancelling",
            STATE_CANCELLED => "cancelled",
            STATE_FAILED => "failed",
            STATE_FINALIZING => "completing",
            _ => "unknown",
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn envelope_marker_preserves_curve() {
            let curve = (0..33)
                .map(|index| GainPoint {
                    outgoing: 1.0 - index as f64 / 32.0,
                    incoming: index as f64 / 32.0,
                })
                .collect::<Vec<_>>();
            let nodes = incoming_nodes(&curve, 48_000 * 8, 8);
            assert_eq!(nodes.len(), 34);
            assert_eq!(nodes[0].position, 0);
            assert_eq!(nodes[1].position, 8);
            let expected = curve[1].incoming * 8.0 / nodes[2].position as f64;
            assert!((nodes[1].value as f64 - expected).abs() < 1e-6);
        }

        #[test]
        fn finish_state_has_a_single_owner() {
            let state = Arc::new(AtomicU8::new(STATE_COMPLETING));
            let owners = Arc::new(AtomicUsize::new(0));
            let threads = (0..16)
                .map(|_| {
                    let state = state.clone();
                    let owners = owners.clone();
                    thread::spawn(move || {
                        if claim_finish(&state) {
                            owners.fetch_add(1, Ordering::AcqRel);
                        }
                    })
                })
                .collect::<Vec<_>>();
            for thread in threads {
                thread.join().unwrap();
            }
            assert_eq!(owners.load(Ordering::Acquire), 1);
            assert_eq!(state.load(Ordering::Acquire), STATE_FINALIZING);
        }
    }
}

#[cfg(target_os = "windows")]
pub use windows_executor::*;

#[cfg(not(target_os = "windows"))]
mod unsupported {
    use crate::frb_generated::StreamSink;

    pub fn init_events(_bass_dir: String, _sink: StreamSink<String>) -> Result<(), String> {
        Err("smart native transitions require Windows".to_string())
    }

    pub fn close_events() {}

    pub fn capabilities_json(_bass_dir: String) -> String {
        "{\"available\":false,\"tempoAtCue\":false}".to_string()
    }

    pub fn arm_json(_bass_dir: String, _request_json: String) -> String {
        "{\"accepted\":false,\"error\":\"unsupported platform\"}".to_string()
    }

    pub fn cancel_json(transition_id: u64, _reason: String) -> String {
        format!("{{\"transitionId\":{transition_id},\"state\":\"missing\"}}")
    }

    pub fn adopt_json(_transition_id: u64) -> String {
        "{\"state\":\"missing\"}".to_string()
    }

    pub fn snapshot_json(_transition_id: u64) -> String {
        "{\"state\":\"missing\"}".to_string()
    }

    pub fn acknowledge(_transition_id: u64) -> bool {
        false
    }

    pub fn diagnostics_json() -> String {
        "{\"activeContexts\":0,\"tempoAtCue\":false}".to_string()
    }
}

#[cfg(not(target_os = "windows"))]
pub use unsupported::*;
