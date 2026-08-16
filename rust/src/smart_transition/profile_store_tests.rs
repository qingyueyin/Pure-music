// Profile store 测试。

use crate::smart_transition::model::{RegionProfile, TempoProfile, TrackProfile};
use crate::smart_transition::profile_store::{
    normalize_profile_key, CacheKey, ProfileStore, StoreError, ACCESS_FLUSH_INTERVAL_MS,
};

fn region(start_ms: f64, end_ms: f64) -> RegionProfile {
    RegionProfile {
        start_ms,
        end_ms,
        average_energy_dbfs: -12.0,
        onset_density: 0.3,
        boundary_confidence: 0.7,
    }
}

fn sample_profile(profile_key: &str) -> TrackProfile {
    TrackProfile {
        profile_key: profile_key.to_string(),
        duration_ms: 240000,
        audible_start_ms: 200,
        audible_end_ms: 239000,
        integrated_rms_dbfs: -14.0,
        peak_dbfs: -2.0,
        tempo: Some(TempoProfile {
            bpm: 120.0,
            beat_times_ms: (0..16).map(|i| i as f64 * 500.0).collect(),
            downbeat_offset_ms: 0.0,
            beat_confidence: 0.8,
            downbeat_confidence: 0.6,
            stability: 0.75,
        }),
        entrance: region(0.0, 8000.0),
        exit: region(232000.0, 240000.0),
        analysis_version: 1,
        config_hash: "hash".to_string(),
    }
}

fn cache_key(profile_key: &str, modified_ns: i64, size: i64) -> CacheKey {
    CacheKey {
        profile_key: profile_key.to_string(),
        media_id: Some("media-id".to_string()),
        path: "C:/music/a.flac".to_string(),
        source_modified_ns: modified_ns,
        source_size: size,
        analysis_version: 1,
        config_hash: "hash".to_string(),
    }
}

#[test]
fn migration_is_idempotent() {
    let mut store = ProfileStore::open_in_memory().unwrap();
    store.ensure_schema().unwrap();
    store.ensure_schema().unwrap();
    // 隔离的 profile 存储不触碰主库 user_version。
    let version: i64 = store.raw_query("PRAGMA user_version").unwrap();
    assert_eq!(version, 0, "profile store 不得修改 user_version");
    // 表可用
    let key = cache_key("media:id", 100, 1000);
    store
        .upsert_profile(&key, &sample_profile(&key.profile_key))
        .unwrap();
    assert!(store.lookup_profile(&key).unwrap().is_some());
}

#[test]
fn key_fields_control_hits() {
    let mut store = ProfileStore::open_in_memory().unwrap();
    let key = cache_key("media:id", 100, 1000);
    store
        .upsert_profile(&key, &sample_profile(&key.profile_key))
        .unwrap();
    assert!(store.lookup_profile(&key).unwrap().is_some());
    // 任一 key 字段变化即未命中
    let mut k = cache_key("media:id", 101, 1000);
    assert!(store.lookup_profile(&k).unwrap().is_none());
    k = cache_key("media:id", 100, 1001);
    assert!(store.lookup_profile(&k).unwrap().is_none());
    k = cache_key("media:id", 100, 1000);
    k.analysis_version = 2;
    assert!(store.lookup_profile(&k).unwrap().is_none());
    k = cache_key("media:id", 100, 1000);
    k.config_hash = "other".to_string();
    assert!(store.lookup_profile(&k).unwrap().is_none());
    k = cache_key("media:other", 100, 1000);
    assert!(store.lookup_profile(&k).unwrap().is_none());
    // 原始 key 仍可命中
    assert!(store.lookup_profile(&key).unwrap().is_some());
}

#[test]
fn corrupt_blob_is_rejected() {
    let mut store = ProfileStore::open_in_memory().unwrap();
    let key = cache_key("media:id", 100, 1000);
    // 内容非 JSON 的损坏记录（CHECK 保证 profile_bytes 与长度一致，长度相符但内容损坏）
    store
        .raw_exec("INSERT INTO transition_profiles (profile_key, media_id, path, source_modified_ns, source_size, analysis_version, config_hash, profile_schema_version, profile_blob, profile_bytes, last_accessed_ms) VALUES ('media:id', 'media-id', 'C:/music/a.flac', 100, 1000, 1, 'hash', 1, x'00ff', 2, 1)")
        .unwrap();
    assert!(
        store.lookup_profile(&key).unwrap().is_none(),
        "损坏记录必须返回 miss"
    );
    // 损坏记录已被删除
    assert!(store.lookup_profile(&key).unwrap().is_none());
    // schemaVersion 不匹配的记录也被拒绝
    store
        .raw_exec("INSERT INTO transition_profiles (profile_key, media_id, path, source_modified_ns, source_size, analysis_version, config_hash, profile_schema_version, profile_blob, profile_bytes, last_accessed_ms) VALUES ('media:id', 'media-id', 'C:/music/a.flac', 200, 1000, 1, 'hash', 1, x'7b22736368656d6156657273696f6e223a392c2270726f66696c65223a7b7d7d', 32, 1)")
        .unwrap();
    let key2 = cache_key("media:id", 200, 1000);
    assert!(store.lookup_profile(&key2).unwrap().is_none());
}

#[test]
fn lru_limits_hold() {
    let mut store = ProfileStore::open_in_memory_with_limits(5, u64::MAX).unwrap();
    for i in 0..8 {
        let key = cache_key(&format!("media:id-{i}"), 100 + i, 1000);
        store
            .upsert_profile(&key, &sample_profile(&key.profile_key))
            .unwrap();
    }
    store.evict_profiles().unwrap();
    let count: i64 = store
        .raw_query("SELECT count(*) FROM transition_profiles")
        .unwrap();
    assert!(count <= 5, "count={count}");
    // 最早插入的 3 条被淘汰（last_accessed 相同，按 profile_id 淘汰）
    for i in 0..3 {
        let key = cache_key(&format!("media:id-{i}"), 100 + i, 1000);
        assert!(
            store.lookup_profile(&key).unwrap().is_none(),
            "k{i} should be evicted"
        );
    }
    for i in 5..8 {
        let key = cache_key(&format!("media:id-{i}"), 100 + i, 1000);
        assert!(
            store.lookup_profile(&key).unwrap().is_some(),
            "k{i} should remain"
        );
    }
}

#[test]
fn clock_rollback_is_monotonic() {
    let mut store = ProfileStore::open_in_memory().unwrap();
    let key = cache_key("media:id", 100, 1000);
    store
        .upsert_profile(&key, &sample_profile(&key.profile_key))
        .unwrap();
    store.lookup_profile(&key).unwrap();
    store.flush_accesses().unwrap();
    // 把 last_accessed 调大，模拟未来时间
    store
        .raw_exec("UPDATE transition_profiles SET last_accessed_ms = 9999999999999 WHERE profile_key = 'media:id'")
        .unwrap();
    // 再命中并 flush：MAX(old, now) 必须保持大值
    store.lookup_profile(&key).unwrap();
    store.flush_accesses().unwrap();
    let v: i64 = store
        .raw_query(
            "SELECT last_accessed_ms FROM transition_profiles WHERE profile_key = 'media:id'",
        )
        .unwrap();
    assert_eq!(v, 9999999999999, "时钟回退不得倒退 last_accessed");
}

#[test]
fn two_writers_converge() {
    let dir = std::env::temp_dir();
    let path = dir.join(format!(
        "smart_transition_test_{}.sqlite",
        std::process::id()
    ));
    let path_str = path.to_str().unwrap().to_string();
    let mut store1 = ProfileStore::open(&path_str).unwrap();
    let mut store2 = ProfileStore::open(&path_str).unwrap();
    let key = cache_key("media:id", 100, 1000);
    let mut p1 = sample_profile(&key.profile_key);
    p1.integrated_rms_dbfs = -15.0;
    let mut p2 = sample_profile(&key.profile_key);
    p2.integrated_rms_dbfs = -13.0;
    store1.upsert_profile(&key, &p1).unwrap();
    store2.upsert_profile(&key, &p2).unwrap();
    // 两个连接都收敛到最后写入者
    let from1 = store1
        .lookup_profile(&key)
        .unwrap()
        .expect("store1 sees row");
    let from2 = store2
        .lookup_profile(&key)
        .unwrap()
        .expect("store2 sees row");
    assert_eq!(from1.integrated_rms_dbfs, -13.0);
    assert_eq!(from2.integrated_rms_dbfs, -13.0);
    drop(store1);
    drop(store2);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn profile_key_normalization() {
    assert_eq!(
        normalize_profile_key(Some("AbC123"), "C:/x"),
        "media:AbC123"
    );
    assert_eq!(
        normalize_profile_key(None, "C:\\Music\\A.flac"),
        "path:c:/music/a.flac"
    );
    assert_eq!(normalize_profile_key(Some(""), "C:\\x\\"), "path:c:/x");
    assert_eq!(normalize_profile_key(None, ""), "path:".to_string());
    assert_eq!(
        normalize_profile_key(None, "C:\\Music\\e\u{301}.flac"),
        normalize_profile_key(None, "C:\\Music\\\u{00E9}.flac")
    );
    assert_eq!(normalize_profile_key(None, "C:\\"), "path:c:/");
}

#[test]
fn profile_metadata_must_match_cache_key() {
    let mut store = ProfileStore::open_in_memory().unwrap();
    let key = cache_key("media:id", 100, 1000);
    let mut profile = sample_profile(&key.profile_key);
    profile.config_hash = "other".to_string();
    assert!(matches!(
        store.upsert_profile(&key, &profile),
        Err(StoreError::InvalidBlob(_))
    ));
}

#[test]
fn access_flush_updates_only_the_full_cache_key() {
    let mut store = ProfileStore::open_in_memory().unwrap();
    let key1 = cache_key("media:id", 100, 1000);
    let key2 = cache_key("media:id", 200, 1000);
    store
        .upsert_profile(&key1, &sample_profile(&key1.profile_key))
        .unwrap();
    store
        .upsert_profile(&key2, &sample_profile(&key2.profile_key))
        .unwrap();
    store
        .raw_exec("UPDATE transition_profiles SET last_accessed_ms = CASE source_modified_ns WHEN 100 THEN 1 ELSE 2 END")
        .unwrap();
    store.lookup_profile(&key1).unwrap();
    store.flush_accesses().unwrap();
    let first: i64 = store
        .raw_query(
            "SELECT last_accessed_ms FROM transition_profiles WHERE source_modified_ns = 100",
        )
        .unwrap();
    let second: i64 = store
        .raw_query(
            "SELECT last_accessed_ms FROM transition_profiles WHERE source_modified_ns = 200",
        )
        .unwrap();
    assert!(first > 2);
    assert_eq!(second, 2);
}

#[test]
fn access_flush_runs_after_interval() {
    let mut store = ProfileStore::open_in_memory().unwrap();
    let key = cache_key("media:id", 100, 1000);
    store
        .upsert_profile(&key, &sample_profile(&key.profile_key))
        .unwrap();
    store.set_last_flush_ms_for_test(0);
    store.lookup_profile(&key).unwrap();
    let updated: i64 = store
        .raw_query(
            "SELECT last_accessed_ms FROM transition_profiles WHERE profile_key = 'media:id'",
        )
        .unwrap();
    assert!(updated >= ACCESS_FLUSH_INTERVAL_MS as i64);
}

#[test]
fn sqlite_error_categories_are_typed() {
    assert_eq!(
        ProfileStore::classify_error_code_for_test(rusqlite::ErrorCode::DatabaseBusy),
        StoreError::Busy
    );
    assert_eq!(
        ProfileStore::classify_error_code_for_test(rusqlite::ErrorCode::DatabaseLocked),
        StoreError::Busy
    );
    assert_eq!(
        ProfileStore::classify_error_code_for_test(rusqlite::ErrorCode::DatabaseCorrupt),
        StoreError::Corrupt
    );
    assert_eq!(
        ProfileStore::classify_error_code_for_test(rusqlite::ErrorCode::ReadOnly),
        StoreError::ReadOnly
    );
}
