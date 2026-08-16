// 隔离的 profile store。新增 transition_profiles 表，不接入现有 library_db.rs。
// SQL 与文档第 10 节逐项一致；上限由代码和测试保证，不依赖表约束自动保证。

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use unicode_normalization::UnicodeNormalization;

use crate::smart_transition::config::PROFILE_SCHEMA_VERSION;
use crate::smart_transition::model::{validate_track_profile, TrackProfile};

pub const MAX_PROFILES: u64 = 10_000;
pub const MAX_PROFILE_BYTES: u64 = 256 * 1024 * 1024;
pub const BLOB_LIMIT_BYTES: usize = 8 * 1024 * 1024;
pub const ACCESS_FLUSH_THRESHOLD: usize = 32;
pub const ACCESS_FLUSH_INTERVAL_MS: u64 = 30_000;
const SCHEMA_SQL: &str = "
CREATE TABLE IF NOT EXISTS transition_profiles (
  profile_id INTEGER PRIMARY KEY,
  profile_key TEXT NOT NULL,
  media_id TEXT,
  path TEXT NOT NULL,
  source_modified_ns INTEGER NOT NULL,
  source_size INTEGER NOT NULL CHECK (source_size >= 0),
  analysis_version INTEGER NOT NULL,
  config_hash TEXT NOT NULL,
  profile_schema_version INTEGER NOT NULL,
  profile_blob BLOB NOT NULL CHECK (length(profile_blob) <= 8388608),
  profile_bytes INTEGER NOT NULL CHECK (profile_bytes = length(profile_blob)),
  last_accessed_ms INTEGER NOT NULL,
  UNIQUE (
    profile_key,
    source_modified_ns,
    source_size,
    analysis_version,
    profile_schema_version,
    config_hash
  )
);
CREATE INDEX IF NOT EXISTS idx_transition_profiles_lru
ON transition_profiles(last_accessed_ms, profile_id);
";

#[derive(Debug, Clone, PartialEq)]
pub enum StoreError {
    Busy,
    ReadOnly,
    Corrupt,
    InvalidBlob(String),
    Other(String),
}

fn map_err(e: rusqlite::Error) -> StoreError {
    match e {
        rusqlite::Error::SqliteFailure(f, _) => map_error_code(f.code),
        other => StoreError::Other(other.to_string()),
    }
}

fn map_error_code(code: rusqlite::ErrorCode) -> StoreError {
    match code {
        rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked => StoreError::Busy,
        rusqlite::ErrorCode::ReadOnly => StoreError::ReadOnly,
        rusqlite::ErrorCode::DatabaseCorrupt | rusqlite::ErrorCode::NotADatabase => {
            StoreError::Corrupt
        }
        other => StoreError::Other(format!("sqlite error {other:?}")),
    }
}

/// 缓存键：完整 UNIQUE key 的字段，任一变化即缓存未命中。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CacheKey {
    pub profile_key: String,
    pub media_id: Option<String>,
    pub path: String,
    pub source_modified_ns: i64,
    pub source_size: i64,
    pub analysis_version: u32,
    pub config_hash: String,
}

/// profile_key：media:<exact media_id>；缺失时 path:<normalized>。
pub fn normalize_profile_key(media_id: Option<&str>, path: &str) -> String {
    match media_id {
        Some(id) if !id.is_empty() => format!("media:{id}"),
        _ => format!("path:{}", normalize_path(path)),
    }
}

/// Windows 路径规范化：绝对化、统一分隔符、去尾分隔符、大小写折叠；
/// 不解析不存在文件的 symlink。NFC 需 unicode-normalization crate，暂以大小写折叠替代。
fn normalize_path(path: &str) -> String {
    if path.is_empty() {
        return String::new();
    }
    let absolute = if Path::new(path).is_absolute() {
        PathBuf::from(path)
    } else {
        std::env::current_dir()
            .map(|current| current.join(path))
            .unwrap_or_else(|_| PathBuf::from(path))
    };
    let mut lexical = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                lexical.pop();
            }
            _ => lexical.push(component.as_os_str()),
        }
    }
    let unified = lexical.to_string_lossy().replace('\\', "/");
    let nfc: String = unified.nfc().collect();
    let folded: String = nfc.chars().flat_map(char::to_lowercase).collect();
    folded.nfc().collect()
}

pub struct ProfileStore {
    conn: Connection,
    access_set: HashMap<CacheKey, u64>,
    last_flush_ms: u64,
    max_profiles: u64,
    max_profile_bytes: u64,
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl ProfileStore {
    pub fn open(path: &str) -> Result<Self, StoreError> {
        let conn = Connection::open(path).map_err(map_err)?;
        conn.busy_timeout(Duration::from_secs(5)).map_err(map_err)?;
        let mut store = ProfileStore {
            conn,
            access_set: HashMap::new(),
            last_flush_ms: now_ms(),
            max_profiles: MAX_PROFILES,
            max_profile_bytes: MAX_PROFILE_BYTES,
        };
        store.ensure_schema()?;
        Ok(store)
    }

    pub fn open_in_memory() -> Result<Self, StoreError> {
        let conn = Connection::open_in_memory().map_err(map_err)?;
        conn.busy_timeout(Duration::from_secs(5)).map_err(map_err)?;
        let mut store = ProfileStore {
            conn,
            access_set: HashMap::new(),
            last_flush_ms: now_ms(),
            max_profiles: MAX_PROFILES,
            max_profile_bytes: MAX_PROFILE_BYTES,
        };
        store.ensure_schema()?;
        Ok(store)
    }

    /// 测试专用：内存库 + 自定义淘汰上限。
    #[cfg(test)]
    pub fn open_in_memory_with_limits(
        max_profiles: u64,
        max_profile_bytes: u64,
    ) -> Result<Self, StoreError> {
        let mut store = Self::open_in_memory()?;
        store.max_profiles = max_profiles;
        store.max_profile_bytes = max_profile_bytes;
        Ok(store)
    }

    pub fn ensure_schema(&mut self) -> Result<(), StoreError> {
        // 只建表和索引，不触碰 user_version：主库版本策略属于 Codex 集成范围
        // （任务卡 13.8 停止条件），本模块是隔离的 profile 存储。
        let tx = self.conn.transaction().map_err(map_err)?;
        tx.execute_batch(SCHEMA_SQL).map_err(map_err)?;
        tx.commit().map_err(map_err)?;
        Ok(())
    }

    /// 严格 lookup：完整 UNIQUE key 匹配 + blob 校验。损坏/不兼容记录删除后返回 miss。
    pub fn lookup_profile(&mut self, key: &CacheKey) -> Result<Option<TrackProfile>, StoreError> {
        let row: Option<(Vec<u8>, i64)> = self
            .conn
            .query_row(
                "SELECT profile_blob, profile_bytes FROM transition_profiles
                 WHERE profile_key = ?1 AND source_modified_ns = ?2 AND source_size = ?3
                   AND analysis_version = ?4 AND profile_schema_version = ?5 AND config_hash = ?6",
                params![
                    key.profile_key,
                    key.source_modified_ns,
                    key.source_size,
                    key.analysis_version as i64,
                    PROFILE_SCHEMA_VERSION as i64,
                    key.config_hash
                ],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(map_err)?;
        let Some((blob, stored_bytes)) = row else {
            return Ok(None);
        };
        let decoded = decode_profile_blob(&blob);
        let ok = stored_bytes >= 0
            && blob.len() == stored_bytes as usize
            && blob.len() <= BLOB_LIMIT_BYTES
            && decoded
                .as_ref()
                .map(|profile| profile_matches_key(profile, key))
                .unwrap_or(false);
        if !ok {
            self.delete_profile(key)?;
            return Ok(None);
        }
        let profile = decoded.expect("checked above");
        let now = now_ms();
        self.access_set.insert(key.clone(), now);
        if self.access_set.len() >= ACCESS_FLUSH_THRESHOLD
            || now.saturating_sub(self.last_flush_ms) >= ACCESS_FLUSH_INTERVAL_MS
        {
            self.flush_accesses()?;
        }
        Ok(Some(profile))
    }

    /// 校验通过后 upsert：BEGIN IMMEDIATE + 完整 UNIQUE key + 事务内淘汰。
    pub fn upsert_profile(
        &mut self,
        key: &CacheKey,
        profile: &TrackProfile,
    ) -> Result<(), StoreError> {
        validate_track_profile(profile).map_err(|e| StoreError::InvalidBlob(e.to_string()))?;
        if profile.profile_key != key.profile_key {
            return Err(StoreError::InvalidBlob(
                "profile_key mismatch with cache key".to_string(),
            ));
        }
        if profile.analysis_version != key.analysis_version
            || profile.config_hash != key.config_hash
        {
            return Err(StoreError::InvalidBlob(
                "profile version or config hash mismatch with cache key".to_string(),
            ));
        }
        let blob = encode_profile_blob(profile)?;
        let (mp, mb) = (self.max_profiles, self.max_profile_bytes);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(map_err)?;
        tx.execute(
            "INSERT INTO transition_profiles (
                profile_key, media_id, path, source_modified_ns, source_size,
                analysis_version, config_hash, profile_schema_version,
                profile_blob, profile_bytes, last_accessed_ms
             ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
             ON CONFLICT(profile_key, source_modified_ns, source_size,
                         analysis_version, profile_schema_version, config_hash)
             DO UPDATE SET media_id=excluded.media_id, path=excluded.path,
                           profile_blob=excluded.profile_blob,
                           profile_bytes=excluded.profile_bytes,
                           last_accessed_ms=excluded.last_accessed_ms",
            params![
                key.profile_key,
                key.media_id,
                key.path,
                key.source_modified_ns,
                key.source_size,
                key.analysis_version as i64,
                key.config_hash,
                PROFILE_SCHEMA_VERSION as i64,
                blob,
                blob.len() as i64,
                now_ms() as i64
            ],
        )
        .map_err(map_err)?;
        // upsert 后该 key 的 pending 访问已由行的 last_accessed 反映，清理内存 access set
        self.access_set.remove(key);
        evict_in_tx(&tx, mp, mb)?;
        tx.commit().map_err(map_err)?;
        Ok(())
    }

    /// 批量更新 last_accessed_ms = max(old, now)，时钟回退不倒退。
    pub fn flush_accesses(&mut self) -> Result<(), StoreError> {
        if self.access_set.is_empty() {
            return Ok(());
        }
        let now = now_ms();
        let pending = std::mem::take(&mut self.access_set);
        let result = (|| {
            let tx = self
                .conn
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(map_err)?;
            {
                let mut stmt = tx
                    .prepare(
                        "UPDATE transition_profiles SET last_accessed_ms = MAX(last_accessed_ms, ?1)
                         WHERE profile_key = ?2 AND source_modified_ns = ?3 AND source_size = ?4
                           AND analysis_version = ?5 AND profile_schema_version = ?6 AND config_hash = ?7",
                    )
                    .map_err(map_err)?;
                for (key, timestamp) in &pending {
                    stmt.execute(params![
                        now.max(*timestamp) as i64,
                        key.profile_key,
                        key.source_modified_ns,
                        key.source_size,
                        key.analysis_version as i64,
                        PROFILE_SCHEMA_VERSION as i64,
                        key.config_hash,
                    ])
                    .map_err(map_err)?;
                }
            }
            tx.commit().map_err(map_err)
        })();
        if let Err(error) = result {
            for (key, timestamp) in pending {
                self.access_set
                    .entry(key)
                    .and_modify(|current| *current = (*current).max(timestamp))
                    .or_insert(timestamp);
            }
            return Err(error);
        }
        self.last_flush_ms = now;
        Ok(())
    }

    /// 超出上限时按 (last_accessed_ms, profile_id) 确定性淘汰。
    pub fn evict_profiles(&mut self) -> Result<usize, StoreError> {
        let (mp, mb) = (self.max_profiles, self.max_profile_bytes);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(map_err)?;
        let n = evict_in_tx(&tx, mp, mb)?;
        tx.commit().map_err(map_err)?;
        Ok(n)
    }
}

fn evict_in_tx(
    tx: &Transaction<'_>,
    max_profiles: u64,
    max_profile_bytes: u64,
) -> Result<usize, StoreError> {
    let mut evicted = 0usize;
    loop {
        let (count, total): (i64, i64) = tx
            .query_row(
                "SELECT count(*), COALESCE(sum(profile_bytes), 0) FROM transition_profiles",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .map_err(map_err)?;
        if (count as u64) <= max_profiles && (total as u64) <= max_profile_bytes {
            break;
        }
        let to_delete = ((count as u64).saturating_sub(max_profiles)).max(1).min(8) as i64;
        let removed = tx
            .execute(
                "DELETE FROM transition_profiles WHERE profile_id IN (
                    SELECT profile_id FROM transition_profiles
                    ORDER BY last_accessed_ms ASC, profile_id ASC LIMIT ?1
                 )",
                [to_delete],
            )
            .map_err(map_err)?;
        if removed == 0 {
            break;
        }
        evicted += removed;
    }
    Ok(evicted)
}

impl ProfileStore {
    fn delete_profile(&mut self, key: &CacheKey) -> Result<(), StoreError> {
        self.access_set.remove(key);
        self.conn
            .execute(
                "DELETE FROM transition_profiles
                 WHERE profile_key = ?1 AND source_modified_ns = ?2 AND source_size = ?3
                   AND analysis_version = ?4 AND profile_schema_version = ?5 AND config_hash = ?6",
                params![
                    key.profile_key,
                    key.source_modified_ns,
                    key.source_size,
                    key.analysis_version as i64,
                    PROFILE_SCHEMA_VERSION as i64,
                    key.config_hash
                ],
            )
            .map_err(map_err)?;
        Ok(())
    }
}

fn encode_profile_blob(profile: &TrackProfile) -> Result<Vec<u8>, StoreError> {
    let value = serde_json::json!({
        "schemaVersion": PROFILE_SCHEMA_VERSION,
        "profile": profile,
    });
    let bytes = serde_json::to_vec(&value).map_err(|e| StoreError::InvalidBlob(e.to_string()))?;
    if bytes.len() > BLOB_LIMIT_BYTES {
        return Err(StoreError::InvalidBlob(format!(
            "blob {} bytes exceeds limit",
            bytes.len()
        )));
    }
    Ok(bytes)
}

fn decode_profile_blob(blob: &[u8]) -> Result<TrackProfile, StoreError> {
    let value: serde_json::Value =
        serde_json::from_slice(blob).map_err(|e| StoreError::InvalidBlob(format!("json: {e}")))?;
    let schema = value
        .get("schemaVersion")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    if schema != PROFILE_SCHEMA_VERSION as u64 {
        return Err(StoreError::InvalidBlob(format!(
            "schemaVersion {schema} != {PROFILE_SCHEMA_VERSION}"
        )));
    }
    let profile: TrackProfile =
        serde_json::from_value(value.get("profile").cloned().unwrap_or_default())
            .map_err(|e| StoreError::InvalidBlob(format!("profile: {e}")))?;
    validate_track_profile(&profile).map_err(|e| StoreError::InvalidBlob(e.to_string()))?;
    Ok(profile)
}

fn profile_matches_key(profile: &TrackProfile, key: &CacheKey) -> bool {
    profile.profile_key == key.profile_key
        && profile.analysis_version == key.analysis_version
        && profile.config_hash == key.config_hash
}

impl Drop for ProfileStore {
    fn drop(&mut self) {
        let _ = self.flush_accesses();
    }
}

#[cfg(test)]
impl ProfileStore {
    /// 测试专用：直接执行 SQL。
    pub fn raw_exec(&self, sql: &str) -> Result<(), StoreError> {
        self.conn.execute_batch(sql).map_err(map_err)
    }

    /// 测试专用：查询单值。
    pub fn raw_query<T: rusqlite::types::FromSql>(&self, sql: &str) -> Result<T, StoreError> {
        self.conn.query_row(sql, [], |r| r.get(0)).map_err(map_err)
    }

    pub fn set_last_flush_ms_for_test(&mut self, value: u64) {
        self.last_flush_ms = value;
    }

    pub fn classify_error_code_for_test(code: rusqlite::ErrorCode) -> StoreError {
        map_error_code(code)
    }
}
