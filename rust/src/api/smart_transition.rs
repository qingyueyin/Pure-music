use std::collections::{HashMap, VecDeque};
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::UNIX_EPOCH;

use flutter_rust_bridge::frb;

use crate::frb_generated::StreamSink;

use crate::smart_transition::analyzer::analyze_file;
use crate::smart_transition::config::{analysis_config_hash, AnalysisConfig};
use crate::smart_transition::model::TrackProfile;
use crate::smart_transition::planner::{plan_transition, Relationship, RuntimeConstraints};
use crate::smart_transition::profile_store::{normalize_profile_key, CacheKey, ProfileStore};

const MEMORY_PROFILE_LIMIT: usize = 64;
const MEMORY_BYTES_LIMIT: usize = 32 * 1024 * 1024;

struct MemoryProfile {
    profile: TrackProfile,
    bytes: usize,
}

#[derive(Default)]
#[frb(ignore)]
struct MemoryProfileCache {
    values: HashMap<CacheKey, MemoryProfile>,
    order: VecDeque<CacheKey>,
    bytes: usize,
}

impl MemoryProfileCache {
    fn get(&mut self, key: &CacheKey) -> Option<TrackProfile> {
        let profile = self.values.get(key)?.profile.clone();
        self.order.retain(|entry| entry != key);
        self.order.push_back(key.clone());
        Some(profile)
    }

    fn insert(&mut self, key: CacheKey, profile: TrackProfile) {
        let bytes = serde_json::to_vec(&profile)
            .map(|value| value.len())
            .unwrap_or(0);
        if let Some(previous) = self.values.remove(&key) {
            self.bytes = self.bytes.saturating_sub(previous.bytes);
        }
        self.order.retain(|entry| entry != &key);
        self.order.push_back(key.clone());
        self.bytes = self.bytes.saturating_add(bytes);
        self.values.insert(key, MemoryProfile { profile, bytes });
        while self.values.len() > MEMORY_PROFILE_LIMIT || self.bytes > MEMORY_BYTES_LIMIT {
            let Some(oldest) = self.order.pop_front() else {
                break;
            };
            if let Some(removed) = self.values.remove(&oldest) {
                self.bytes = self.bytes.saturating_sub(removed.bytes);
            }
        }
    }
}

type ActiveJobs = HashMap<u64, Arc<AtomicBool>>;

fn active_jobs() -> &'static Mutex<ActiveJobs> {
    static ACTIVE: OnceLock<Mutex<ActiveJobs>> = OnceLock::new();
    ACTIVE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn memory_cache() -> &'static Mutex<MemoryProfileCache> {
    static CACHE: OnceLock<Mutex<MemoryProfileCache>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(MemoryProfileCache::default()))
}

pub fn analyze_smart_transition_track(
    job_id: u64,
    path: String,
    media_id: Option<String>,
    library_root: String,
) -> Result<String, String> {
    let cancel = Arc::new(AtomicBool::new(false));
    {
        let mut active = active_jobs()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if let Some(previous) = active.insert(job_id, cancel.clone()) {
            previous.store(true, Ordering::Release);
        }
    }
    let result = analyze_with_cache(&path, media_id.as_deref(), &library_root, &cancel)
        .and_then(|profile| serde_json::to_string(&profile).map_err(|error| error.to_string()));
    let mut active = active_jobs()
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    if active
        .get(&job_id)
        .is_some_and(|current| Arc::ptr_eq(current, &cancel))
    {
        active.remove(&job_id);
    }
    result
}

#[frb(sync)]
pub fn cancel_smart_transition_analysis(job_id: u64) -> bool {
    let active = active_jobs()
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let Some(cancel) = active.get(&job_id) else {
        return false;
    };
    cancel.store(true, Ordering::Release);
    true
}

pub fn plan_smart_transition_json(
    outgoing_profile_json: String,
    incoming_profile_json: String,
    is_gapless_candidate: bool,
    is_same_album: bool,
    user_speed: f64,
    pitch: f64,
    tempo_at_cue_available: bool,
    outgoing_replay_gain_db: f64,
    incoming_replay_gain_db: f64,
) -> Result<String, String> {
    let outgoing: TrackProfile =
        serde_json::from_str(&outgoing_profile_json).map_err(|error| error.to_string())?;
    let incoming: TrackProfile =
        serde_json::from_str(&incoming_profile_json).map_err(|error| error.to_string())?;
    let config = AnalysisConfig::default();
    let plan = plan_transition(
        &outgoing,
        &incoming,
        &Relationship {
            is_gapless_candidate,
            is_same_album,
        },
        &RuntimeConstraints {
            user_speed,
            pitch,
            tempo_at_cue_available,
            bass_tempo_min_percent: -95.0,
            bass_tempo_max_percent: 500.0,
            outgoing_replay_gain_db,
            incoming_replay_gain_db,
        },
        &config,
    )
    .map_err(|error| error.to_string())?;
    serde_json::to_string(&plan).map_err(|error| error.to_string())
}

#[frb(sync)]
pub fn smart_transition_analysis_config_json() -> Result<String, String> {
    let config = AnalysisConfig::default();
    let hash = analysis_config_hash(&config).map_err(|error| error.to_string())?;
    serde_json::to_string(&serde_json::json!({
        "analysisVersion": config.analysis_version,
        "configHash": hash,
    }))
    .map_err(|error| error.to_string())
}

pub fn init_smart_transition_events(
    bass_dir: String,
    sink: StreamSink<String>,
) -> Result<(), String> {
    crate::smart_transition::executor::init_events(bass_dir, sink)
}

#[frb(sync)]
pub fn close_smart_transition_events() {
    crate::smart_transition::executor::close_events();
}

#[frb(sync)]
pub fn smart_transition_capabilities_json(bass_dir: String) -> String {
    crate::smart_transition::executor::capabilities_json(bass_dir)
}

#[frb(sync)]
pub fn arm_smart_transition_json(bass_dir: String, request_json: String) -> String {
    crate::smart_transition::executor::arm_json(bass_dir, request_json)
}

#[frb(sync)]
pub fn cancel_native_smart_transition_json(transition_id: u64, reason: String) -> String {
    crate::smart_transition::executor::cancel_json(transition_id, reason)
}

#[frb(sync)]
pub fn adopt_native_smart_transition_json(transition_id: u64) -> String {
    crate::smart_transition::executor::adopt_json(transition_id)
}

#[frb(sync)]
pub fn native_smart_transition_snapshot_json(transition_id: u64) -> String {
    crate::smart_transition::executor::snapshot_json(transition_id)
}

#[frb(sync)]
pub fn acknowledge_native_smart_transition(transition_id: u64) -> bool {
    crate::smart_transition::executor::acknowledge(transition_id)
}

#[frb(sync)]
pub fn smart_transition_diagnostics_json() -> String {
    crate::smart_transition::executor::diagnostics_json()
}

fn analyze_with_cache(
    path: &str,
    media_id: Option<&str>,
    library_root: &str,
    cancelled: &AtomicBool,
) -> Result<TrackProfile, String> {
    let config = AnalysisConfig::default();
    let config_hash = analysis_config_hash(&config).map_err(|error| error.to_string())?;
    let metadata = fs::metadata(path).map_err(|error| error.to_string())?;
    let modified_ns = metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_nanos().min(i64::MAX as u128) as i64)
        .unwrap_or(0);
    let absolute_path = fs::canonicalize(path)
        .unwrap_or_else(|_| Path::new(path).to_path_buf())
        .to_string_lossy()
        .into_owned();
    let key = CacheKey {
        profile_key: normalize_profile_key(media_id, &absolute_path),
        media_id: media_id.map(str::to_string),
        path: absolute_path,
        source_modified_ns: modified_ns,
        source_size: metadata.len().min(i64::MAX as u64) as i64,
        analysis_version: config.analysis_version,
        config_hash,
    };
    let database_path = Path::new(library_root).join("library.sqlite");
    if let Some(database_path) = database_path.to_str() {
        if let Ok(mut store) = ProfileStore::open(database_path) {
            if let Ok(Some(profile)) = store.lookup_profile(&key) {
                return Ok(profile);
            }
        }
    }
    if let Some(profile) = memory_cache()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .get(&key)
    {
        return Ok(profile);
    }
    let profile = analyze_file(path, key.profile_key.clone(), &config, cancelled)
        .map_err(|error| error.to_string())?;
    if cancelled.load(Ordering::Acquire) {
        return Err("analysis cancelled".to_string());
    }
    let mut persisted = false;
    if let Some(database_path) = database_path.to_str() {
        if let Ok(mut store) = ProfileStore::open(database_path) {
            persisted = store.upsert_profile(&key, &profile).is_ok();
        }
    }
    if !persisted {
        memory_cache()
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .insert(key, profile.clone());
    }
    Ok(profile)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::smart_sort::plan_smart_sort_json;
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new(label: &str) -> Self {
            let unique = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system clock after epoch")
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "pure_music_{label}_{}_{}",
                std::process::id(),
                unique
            ));
            fs::create_dir_all(&path).expect("create test directory");
            Self(path)
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn write_test_wav(path: &Path, frequency_hz: f64, gain: f64) {
        const SAMPLE_RATE: u32 = 16_000;
        const DURATION_SECONDS: u32 = 6;
        const CHANNELS: u16 = 1;
        const BITS_PER_SAMPLE: u16 = 16;
        let sample_count = SAMPLE_RATE * DURATION_SECONDS;
        let data_size = sample_count * u32::from(BITS_PER_SAMPLE / 8);
        let mut file = std::fs::File::create(path).expect("create wav fixture");
        file.write_all(b"RIFF").unwrap();
        file.write_all(&(36 + data_size).to_le_bytes()).unwrap();
        file.write_all(b"WAVEfmt ").unwrap();
        file.write_all(&16u32.to_le_bytes()).unwrap();
        file.write_all(&1u16.to_le_bytes()).unwrap();
        file.write_all(&CHANNELS.to_le_bytes()).unwrap();
        file.write_all(&SAMPLE_RATE.to_le_bytes()).unwrap();
        file.write_all(&(SAMPLE_RATE * 2).to_le_bytes()).unwrap();
        file.write_all(&2u16.to_le_bytes()).unwrap();
        file.write_all(&BITS_PER_SAMPLE.to_le_bytes()).unwrap();
        file.write_all(b"data").unwrap();
        file.write_all(&data_size.to_le_bytes()).unwrap();
        let beat_samples = SAMPLE_RATE / 2;
        let click_samples = SAMPLE_RATE / 100;
        for index in 0..sample_count {
            let time = index as f64 / SAMPLE_RATE as f64;
            let tone = gain * (2.0 * std::f64::consts::PI * frequency_hz * time).sin();
            let beat_offset = index % beat_samples;
            let click = if beat_offset < click_samples {
                0.55 * (1.0 - beat_offset as f64 / click_samples as f64)
            } else {
                0.0
            };
            let sample = ((tone + click).clamp(-1.0, 1.0) * i16::MAX as f64) as i16;
            file.write_all(&sample.to_le_bytes()).unwrap();
        }
        file.flush().unwrap();
    }

    fn sort_feature(profile: &TrackProfile) -> serde_json::Value {
        serde_json::json!({
            "integratedRmsDbfs": profile.integrated_rms_dbfs,
            "bpm": profile.tempo.as_ref().map(|tempo| tempo.bpm).unwrap_or(0.0),
            "entranceOnsetDensity": profile.entrance.onset_density,
            "entranceEnergyDbfs": profile.entrance.average_energy_dbfs,
            "exitOnsetDensity": profile.exit.onset_density,
            "exitEnergyDbfs": profile.exit.average_energy_dbfs,
        })
    }

    #[test]
    fn real_wav_analysis_flows_through_public_sort_json_api() {
        let directory = TestDirectory::new("analysis_sort_e2e");
        let first_path = directory.0.join("first.wav");
        let second_path = directory.0.join("second.wav");
        write_test_wav(&first_path, 220.0, 0.12);
        write_test_wav(&second_path, 440.0, 0.32);
        let library_root = directory.0.to_string_lossy().into_owned();

        let first_json = analyze_smart_transition_track(
            9_001,
            first_path.to_string_lossy().into_owned(),
            Some("fixture-first".to_string()),
            library_root.clone(),
        )
        .expect("analyze first fixture");
        let second_json = analyze_smart_transition_track(
            9_002,
            second_path.to_string_lossy().into_owned(),
            Some("fixture-second".to_string()),
            library_root,
        )
        .expect("analyze second fixture");
        let first: TrackProfile = serde_json::from_str(&first_json).unwrap();
        let second: TrackProfile = serde_json::from_str(&second_json).unwrap();
        assert_eq!(first.duration_ms, 6_000);
        assert_eq!(second.duration_ms, 6_000);
        assert!(first.integrated_rms_dbfs.is_finite());
        assert!(second.integrated_rms_dbfs > first.integrated_rms_dbfs);

        let payload = serde_json::json!({
            "features": [sort_feature(&first), sort_feature(&second)],
            "playCounts": [2, 8],
        });
        let output_json = plan_smart_sort_json(payload.to_string(), 0.82, 0.85, 0, 0.5, 0, 0)
            .expect("plan analyzed fixtures");
        let output: serde_json::Value = serde_json::from_str(&output_json).unwrap();
        let mut order = output["order"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_u64().unwrap())
            .collect::<Vec<_>>();
        order.sort_unstable();
        assert_eq!(order, vec![0, 1]);
        for key in ["idealCurve", "actualCurve"] {
            let curve = output[key].as_array().unwrap();
            assert_eq!(curve.len(), 2);
            assert!(curve
                .iter()
                .all(|value| value.as_f64().unwrap().is_finite()));
        }
    }
}
