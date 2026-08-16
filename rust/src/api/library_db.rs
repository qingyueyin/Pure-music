use std::collections::{HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Mutex, OnceLock,
};
use std::time::{Duration, Instant, UNIX_EPOCH};

use anyhow::{anyhow, Result};
use flutter_rust_bridge::frb;
use md5::{Digest, Md5};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};

use super::logger::log_to_dart;

const SMALL_COVER_MAX_DIMENSION: u32 = 128;
const MEDIUM_COVER_MAX_DIMENSION: u32 = 320;
const MAX_PERSISTED_SMALL_COVERS: i64 = 4096;
const MAX_PERSISTED_MEDIUM_COVERS: i64 = 512;
const MAX_PERSISTED_LARGE_COVERS: i64 = 64;
const COVER_PRUNE_READ_BATCH: i64 = 2;
const COVER_PRUNE_WRITE_BATCH: i64 = 16;
const COVER_ACCESS_REFRESH_INTERVAL_MS: i64 = 6 * 60 * 60 * 1000;
const DATABASE_LAYOUT_VERSION: &str = "2";
static INDEX_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);
static INDEX_WRITE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Clone)]
pub struct IndexAudio {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: Option<String>,
    pub track: u32,
    pub disc: u32,
    pub duration: u64,
    pub bitrate: Option<u32>,
    pub sample_rate: Option<u32>,
    pub path: String,
    pub modified: u64,
    pub created: u64,
    pub by: Option<String>,
    pub play_count: i64,
}

#[derive(Clone)]
pub struct PlayCountEntry {
    pub path: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub play_count: i64,
}

#[derive(Clone)]
pub struct IndexFolder {
    pub path: String,
    pub modified: u64,
    pub latest: u64,
    pub audios: Vec<IndexAudio>,
}

pub(crate) struct IndexFolderSnapshot {
    pub path: String,
    pub modified: u64,
}

pub(crate) struct IndexSnapshot {
    pub version: u64,
    pub folders: Vec<IndexFolderSnapshot>,
}

fn sqlite_path(index_dir: &Path) -> PathBuf {
    index_dir.join("library.sqlite")
}

fn legacy_sqlite_path(index_dir: &Path) -> PathBuf {
    index_dir.join("library.sqlite.legacy")
}

fn migrating_sqlite_path(index_dir: &Path) -> PathBuf {
    index_dir.join("library.sqlite.migrating")
}

fn sqlite_sidecar_path(path: &Path, suffix: &str) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(suffix);
    PathBuf::from(value)
}

fn index_temp_file(index_path: &Path) -> io::Result<(PathBuf, std::fs::File)> {
    let parent = index_path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "index path has no parent"))?;
    fs::create_dir_all(parent)?;
    loop {
        let sequence = INDEX_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let mut name = index_path
            .file_name()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "index path has no name"))?
            .to_os_string();
        name.push(format!(".{}.{}.tmp", std::process::id(), sequence));
        let path = parent.join(name);
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => return Ok((path, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
}

#[cfg(windows)]
fn replace_file_atomically(source: &Path, target: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows::core::PCWSTR;
    use windows::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    let source = source
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let target = target
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    unsafe {
        MoveFileExW(
            PCWSTR(source.as_ptr()),
            PCWSTR(target.as_ptr()),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    }
    .map_err(io::Error::other)
}

#[cfg(not(windows))]
fn replace_file_atomically(source: &Path, target: &Path) -> io::Result<()> {
    fs::rename(source, target)
}

fn atomic_write_with_replace<F>(index_path: &Path, bytes: &[u8], replace: F) -> io::Result<()>
where
    F: FnOnce(&Path, &Path) -> io::Result<()>,
{
    let (temp_path, mut temp_file) = index_temp_file(index_path)?;
    let write_result = temp_file
        .write_all(bytes)
        .and_then(|()| temp_file.flush())
        .and_then(|()| temp_file.sync_all());
    drop(temp_file);
    if let Err(error) = write_result {
        let _ = fs::remove_file(&temp_path);
        return Err(error);
    }
    if let Err(error) = replace(&temp_path, index_path) {
        let _ = fs::remove_file(&temp_path);
        return Err(error);
    }
    Ok(())
}

fn write_index_json(index_dir: &Path, index: &serde_json::Value) -> io::Result<()> {
    let bytes = serde_json::to_vec(index).map_err(io::Error::other)?;
    atomic_write_with_replace(
        &index_dir.join("index.json"),
        &bytes,
        replace_file_atomically,
    )
}

fn with_index_write_lock<T>(operation: impl FnOnce() -> Result<T>) -> Result<T> {
    let _guard = INDEX_WRITE_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .map_err(|_| anyhow!("index write lock poisoned"))?;
    operation()
}

fn write_index_snapshot_with<F>(
    index_dir: &Path,
    index: &serde_json::Value,
    after_json_write: F,
) -> Result<()>
where
    F: FnOnce(),
{
    with_index_write_lock(|| {
        write_index_json(index_dir, index)?;
        after_json_write();
        write_index_value_to_sqlite(index_dir, index)
    })
}

pub(crate) fn write_index_snapshot(index_dir: &Path, index: &serde_json::Value) -> Result<()> {
    write_index_snapshot_with(index_dir, index, || {})
}

#[derive(Clone, Default)]
#[frb(ignore)]
struct AudioIdentity {
    media_id: Option<String>,
    metadata_key: Option<String>,
}

fn path_lookup_key(value: &str) -> String {
    let mut normalized = value.trim().replace('\\', "/");
    while normalized.ends_with('/') && normalized.len() > 1 {
        normalized.pop();
    }
    normalized.to_lowercase()
}

#[cfg(windows)]
fn stable_file_id(path: &Path) -> Option<String> {
    use std::os::windows::io::AsRawHandle;
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::Storage::FileSystem::{
        GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
    };

    let file = std::fs::File::open(path).ok()?;
    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    unsafe {
        GetFileInformationByHandle(HANDLE(file.as_raw_handle() as isize), &mut info).ok()?;
    }
    let file_index = ((info.nFileIndexHigh as u64) << 32) | info.nFileIndexLow as u64;
    Some(format!(
        "win:{:08x}:{:016x}",
        info.dwVolumeSerialNumber, file_index
    ))
}

#[cfg(unix)]
fn stable_file_id(path: &Path) -> Option<String> {
    use std::os::unix::fs::MetadataExt;

    let metadata = std::fs::metadata(path).ok()?;
    Some(format!(
        "unix:{:016x}:{:016x}",
        metadata.dev(),
        metadata.ino()
    ))
}

#[cfg(not(any(windows, unix)))]
fn stable_file_id(_path: &Path) -> Option<String> {
    None
}

fn normalize_identity_part(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

fn metadata_match_key(
    path: &Path,
    title: &str,
    artist: &str,
    album: &str,
    album_artist: Option<&str>,
    track: u64,
    duration: u64,
    bitrate: Option<u64>,
    sample_rate: Option<u64>,
) -> String {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_lowercase();
    let material = format!(
        "{}\x1f{}\x1f{}\x1f{}\x1f{}\x1f{}\x1f{}\x1f{}\x1f{}",
        normalize_identity_part(title),
        normalize_identity_part(artist),
        normalize_identity_part(album),
        normalize_identity_part(album_artist.unwrap_or_default()),
        track,
        duration,
        bitrate.unwrap_or_default(),
        sample_rate.unwrap_or_default(),
        extension,
    );
    let mut hasher = Md5::new();
    hasher.update(material.as_bytes());
    format!("meta:{:x}", hasher.finalize())
}

fn audio_identity(
    path: &str,
    title: &str,
    artist: &str,
    album: &str,
    album_artist: Option<&str>,
    track: u64,
    duration: u64,
    bitrate: Option<u64>,
    sample_rate: Option<u64>,
) -> AudioIdentity {
    let path = Path::new(path);
    AudioIdentity {
        media_id: stable_file_id(path),
        metadata_key: Some(metadata_match_key(
            path,
            title,
            artist,
            album,
            album_artist,
            track,
            duration,
            bitrate,
            sample_rate,
        )),
    }
}

fn open_raw_connection(db_path: &Path) -> Result<Connection> {
    if let Some(parent) = db_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let conn = Connection::open(db_path)?;
    conn.busy_timeout(Duration::from_secs(2))?;
    Ok(conn)
}

fn remove_database_file(path: &Path) -> Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn remove_database_files(path: &Path) -> Result<()> {
    remove_database_file(path)?;
    remove_database_file(&sqlite_sidecar_path(path, "-wal"))?;
    remove_database_file(&sqlite_sidecar_path(path, "-shm"))?;
    Ok(())
}

fn has_database_layout_marker(conn: &Connection) -> Result<bool> {
    let marker: Option<String> = conn
        .query_row(
            "SELECT value FROM meta WHERE key = 'database_layout_version'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    Ok(marker.as_deref() == Some(DATABASE_LAYOUT_VERSION))
}

fn cover_tier_exceeds_limit(conn: &Connection, condition: &str, max_entries: i64) -> Result<bool> {
    Ok(conn.query_row(
        &format!(
            "SELECT EXISTS(
               SELECT 1 FROM cover_thumbnails
               WHERE {condition}
               LIMIT 1 OFFSET ?1
             )"
        ),
        params![max_entries],
        |row| row.get(0),
    )?)
}

fn should_rebuild_database(conn: &Connection) -> Result<bool> {
    let auto_vacuum: i64 = conn.pragma_query_value(None, "auto_vacuum", |row| row.get(0))?;
    if auto_vacuum != 0 {
        return Ok(false);
    }
    Ok(cover_tier_exceeds_limit(
        conn,
        "width <= 128 AND height <= 128",
        MAX_PERSISTED_SMALL_COVERS,
    )? || cover_tier_exceeds_limit(
        conn,
        "(width > 128 OR height > 128) AND width <= 320 AND height <= 320",
        MAX_PERSISTED_MEDIUM_COVERS,
    )? || cover_tier_exceeds_limit(
        conn,
        "width > 320 OR height > 320",
        MAX_PERSISTED_LARGE_COVERS,
    )?)
}

fn rebuild_database_from_legacy(index_dir: &Path) -> Result<()> {
    let current_path = sqlite_path(index_dir);
    let legacy_path = legacy_sqlite_path(index_dir);
    let migrating_path = migrating_sqlite_path(index_dir);
    remove_database_files(&migrating_path)?;

    let migration_result = (|| -> Result<()> {
        let mut conn = open_raw_connection(&migrating_path)?;
        conn.pragma_update(None, "auto_vacuum", "INCREMENTAL")?;
        init_schema(&conn)?;
        conn.execute(
            "ATTACH DATABASE ?1 AS legacy",
            params![legacy_path.to_string_lossy().as_ref()],
        )?;
        {
            let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
            tx.execute_batch(
                "INSERT OR REPLACE INTO meta(key, value)
                   SELECT key, value FROM legacy.meta;
                 INSERT INTO folders(path, modified, latest)
                   SELECT path, modified, latest FROM legacy.folders;
                 INSERT INTO audios(
                   path, folder_path, title, artist, album, album_artist, track, disc,
                   duration, bitrate, sample_rate, modified, created, by, play_count,
                   media_id, metadata_key
                 ) SELECT
                   path, folder_path, title, artist, album, album_artist, track, disc,
                   duration, bitrate, sample_rate, modified, created, by, play_count,
                   media_id, metadata_key
                 FROM legacy.audios;",
            )?;
            tx.execute(
                "INSERT OR REPLACE INTO meta(key, value)
                 VALUES('database_layout_version', ?1)",
                params![DATABASE_LAYOUT_VERSION],
            )?;
            tx.commit()?;
        }
        conn.execute_batch(
            "DETACH DATABASE legacy;
             PRAGMA optimize;
             PRAGMA wal_checkpoint(TRUNCATE);",
        )?;
        drop(conn);
        remove_database_file(&sqlite_sidecar_path(&migrating_path, "-wal"))?;
        remove_database_file(&sqlite_sidecar_path(&migrating_path, "-shm"))?;
        std::fs::rename(&migrating_path, &current_path)?;
        let conn = open_raw_connection(&current_path)?;
        if !has_database_layout_marker(&conn)? {
            return Err(anyhow!("rebuilt database layout marker missing"));
        }
        drop(conn);
        Ok(())
    })();

    if let Err(error) = migration_result {
        remove_database_files(&migrating_path)?;
        if legacy_path.exists() {
            remove_database_files(&current_path)?;
            std::fs::rename(&legacy_path, &current_path)?;
        }
        return Err(error);
    }

    remove_database_files(&legacy_path)?;
    Ok(())
}

type DatabaseLayoutLock = OnceLock<Mutex<()>>;
static DATABASE_LAYOUT_LOCK: DatabaseLayoutLock = OnceLock::new();

fn ensure_database_layout(index_dir: &Path) -> Result<()> {
    let _guard = DATABASE_LAYOUT_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .map_err(|_| anyhow!("database layout lock poisoned"))?;
    let current_path = sqlite_path(index_dir);
    let legacy_path = legacy_sqlite_path(index_dir);

    if !current_path.exists() && legacy_path.exists() {
        return rebuild_database_from_legacy(index_dir);
    }
    if !current_path.exists() {
        return Ok(());
    }

    let conn = open_raw_connection(&current_path)?;
    init_schema(&conn)?;
    if has_database_layout_marker(&conn)? {
        drop(conn);
        remove_database_files(&legacy_path)?;
        return Ok(());
    }
    if !should_rebuild_database(&conn)? {
        conn.execute(
            "INSERT OR REPLACE INTO meta(key, value)
             VALUES('database_layout_version', ?1)",
            params![DATABASE_LAYOUT_VERSION],
        )?;
        return Ok(());
    }
    conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
    drop(conn);
    remove_database_files(&legacy_path)?;
    remove_database_file(&sqlite_sidecar_path(&current_path, "-wal"))?;
    remove_database_file(&sqlite_sidecar_path(&current_path, "-shm"))?;
    std::fs::rename(&current_path, &legacy_path)?;
    rebuild_database_from_legacy(index_dir)
}

fn open_connection(index_dir: &Path) -> Result<Connection> {
    ensure_database_layout(index_dir)?;
    open_raw_connection(&sqlite_path(index_dir))
}

pub(crate) fn read_current_index_snapshot(index_dir: &Path) -> Result<Option<IndexSnapshot>> {
    let conn = open_connection(index_dir)?;
    init_schema(&conn)?;
    let Some(stored_signature) = stored_index_source_signature(&conn)? else {
        return Ok(None);
    };
    let current_signature = match index_source_signature(index_dir) {
        Ok(signature) => signature,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if current_signature != stored_signature {
        return Ok(None);
    }
    let version: Option<u64> = conn
        .query_row("SELECT value FROM meta WHERE key = 'version'", [], |row| {
            row.get::<_, String>(0)
        })
        .optional()?
        .and_then(|value| value.parse().ok());
    let Some(version) = version else {
        return Ok(None);
    };
    let mut stmt = conn.prepare("SELECT path, modified FROM folders ORDER BY path")?;
    let rows = stmt.query_map([], |row| {
        let modified: i64 = row.get(1)?;
        Ok(IndexFolderSnapshot {
            path: row.get(0)?,
            modified: modified.max(0) as u64,
        })
    })?;
    let folders = rows.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(Some(IndexSnapshot { version, folders }))
}

fn backfill_audio_identities(conn: &Connection) -> Result<()> {
    let missing = {
        let mut stmt = conn.prepare(
            "SELECT path, title, artist, album, album_artist, track, duration, bitrate, sample_rate
             FROM audios WHERE media_id IS NULL OR metadata_key IS NULL",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, i64>(6)?,
                row.get::<_, Option<i64>>(7)?,
                row.get::<_, Option<i64>>(8)?,
            ))
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    let mut update = conn.prepare(
        "UPDATE audios SET
           media_id = COALESCE(media_id, ?2),
           metadata_key = COALESCE(metadata_key, ?3)
         WHERE path = ?1",
    )?;
    for (path, title, artist, album, album_artist, track, duration, bitrate, sample_rate) in missing
    {
        let identity = audio_identity(
            &path,
            &title,
            &artist,
            &album,
            album_artist.as_deref(),
            track.max(0) as u64,
            duration.max(0) as u64,
            bitrate.map(|value| value.max(0) as u64),
            sample_rate.map(|value| value.max(0) as u64),
        );
        update.execute(params![path, identity.media_id, identity.metadata_key])?;
    }
    Ok(())
}

fn init_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        r#"
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA temp_store = MEMORY;
        PRAGMA auto_vacuum = INCREMENTAL;

        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS folders (
          path TEXT PRIMARY KEY,
          modified INTEGER NOT NULL,
          latest INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS audios (
          path TEXT PRIMARY KEY,
          folder_path TEXT NOT NULL,
          title TEXT NOT NULL,
          artist TEXT NOT NULL,
          album TEXT NOT NULL,
          album_artist TEXT,
          track INTEGER,
          disc INTEGER,
          duration INTEGER NOT NULL,
          bitrate INTEGER,
          sample_rate INTEGER,
          modified INTEGER NOT NULL,
          created INTEGER NOT NULL,
          by TEXT,
          play_count INTEGER NOT NULL DEFAULT 0,
          media_id TEXT,
          metadata_key TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_audios_folder_path_path ON audios(folder_path, path);
        CREATE INDEX IF NOT EXISTS idx_audios_title ON audios(title);
        CREATE INDEX IF NOT EXISTS idx_audios_artist ON audios(artist);
        CREATE INDEX IF NOT EXISTS idx_audios_album ON audios(album);

        CREATE TABLE IF NOT EXISTS cover_thumbnails (
          path TEXT NOT NULL,
          width INTEGER NOT NULL,
          height INTEGER NOT NULL,
          source_modified INTEGER NOT NULL,
          source_size INTEGER NOT NULL,
          last_accessed INTEGER NOT NULL DEFAULT 0,
          png BLOB NOT NULL,
          PRIMARY KEY (path, width, height)
        );
        "#,
    )?;
    let play_count_col = conn
        .prepare("SELECT play_count FROM audios LIMIT 1")
        .is_ok();
    if !play_count_col {
        conn.execute_batch("ALTER TABLE audios ADD COLUMN play_count INTEGER NOT NULL DEFAULT 0;")?;
    }
    let disc_col = conn.prepare("SELECT disc FROM audios LIMIT 1").is_ok();
    if !disc_col {
        conn.execute_batch("ALTER TABLE audios ADD COLUMN disc INTEGER;")?;
    }
    let media_id_col = conn.prepare("SELECT media_id FROM audios LIMIT 1").is_ok();
    if !media_id_col {
        conn.execute_batch("ALTER TABLE audios ADD COLUMN media_id TEXT;")?;
    }
    let metadata_key_col = conn
        .prepare("SELECT metadata_key FROM audios LIMIT 1")
        .is_ok();
    if !metadata_key_col {
        conn.execute_batch("ALTER TABLE audios ADD COLUMN metadata_key TEXT;")?;
    }
    let cover_last_accessed_col = conn
        .prepare("SELECT last_accessed FROM cover_thumbnails LIMIT 1")
        .is_ok();
    if !cover_last_accessed_col {
        conn.execute_batch(
            "ALTER TABLE cover_thumbnails ADD COLUMN last_accessed INTEGER NOT NULL DEFAULT 0;",
        )?;
    }
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_audios_media_id ON audios(media_id);
         CREATE INDEX IF NOT EXISTS idx_audios_metadata_key ON audios(metadata_key);
         DROP INDEX IF EXISTS idx_audios_folder_path;",
    )?;
    let identity_backfill: Option<String> = conn
        .query_row(
            "SELECT value FROM meta WHERE key = 'identity_backfill_v1'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    if identity_backfill.as_deref() != Some("1") {
        backfill_audio_identities(conn)?;
        conn.execute(
            "INSERT OR REPLACE INTO meta(key, value) VALUES('identity_backfill_v1', '1')",
            [],
        )?;
    }
    Ok(())
}

fn file_source_signature(path: &Path) -> io::Result<(i64, i64)> {
    let metadata = std::fs::metadata(path)?;
    let modified = metadata
        .modified()?
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .min(i64::MAX as u128) as i64;
    let size = metadata.len().min(i64::MAX as u64) as i64;
    Ok((modified, size))
}

fn cover_source_signature(path: &Path) -> io::Result<(i64, i64)> {
    file_source_signature(path)
}

fn index_source_signature(index_dir: &Path) -> io::Result<(i64, i64)> {
    file_source_signature(&index_dir.join("index.json"))
}

fn stored_index_source_signature(conn: &Connection) -> Result<Option<(i64, i64)>> {
    let stored_modified: Option<String> = conn
        .query_row(
            "SELECT value FROM meta WHERE key = 'index_source_modified'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let stored_size: Option<String> = conn
        .query_row(
            "SELECT value FROM meta WHERE key = 'index_source_size'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    match (stored_modified, stored_size) {
        (None, None) => Ok(None),
        (Some(modified), Some(size)) => Ok(Some((
            modified
                .parse()
                .map_err(|_| anyhow!("invalid sqlite index modified signature"))?,
            size.parse()
                .map_err(|_| anyhow!("invalid sqlite index size signature"))?,
        ))),
        _ => Err(anyhow!("incomplete sqlite index source signature")),
    }
}

fn ensure_index_source_current(conn: &Connection, index_dir: &Path) -> Result<()> {
    let stored = stored_index_source_signature(conn)?
        .ok_or_else(|| anyhow!("sqlite index source signature missing"))?;
    let current = index_source_signature(index_dir)?;
    if stored != current {
        return Err(anyhow!("sqlite index source signature mismatch"));
    }
    Ok(())
}

#[derive(Clone, Copy)]
enum CoverTier {
    Small,
    Medium,
    Large,
}

fn cover_tier(width: u32, height: u32) -> CoverTier {
    let max_dimension = width.max(height);
    if max_dimension <= SMALL_COVER_MAX_DIMENSION {
        CoverTier::Small
    } else if max_dimension <= MEDIUM_COVER_MAX_DIMENSION {
        CoverTier::Medium
    } else {
        CoverTier::Large
    }
}

fn cover_access_timestamp() -> i64 {
    std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

fn prune_cover_thumbnail_tier(conn: &Connection, tier: CoverTier, batch_size: i64) -> Result<()> {
    let (condition, max_entries) = match tier {
        CoverTier::Small => ("width <= 128 AND height <= 128", MAX_PERSISTED_SMALL_COVERS),
        CoverTier::Medium => (
            "(width > 128 OR height > 128) AND width <= 320 AND height <= 320",
            MAX_PERSISTED_MEDIUM_COVERS,
        ),
        CoverTier::Large => ("width > 320 OR height > 320", MAX_PERSISTED_LARGE_COVERS),
    };
    let deleted = conn.execute(
        &format!(
            "DELETE FROM cover_thumbnails WHERE rowid IN (
               SELECT rowid FROM cover_thumbnails
               WHERE {condition}
               ORDER BY last_accessed DESC, rowid DESC
               LIMIT ?1 OFFSET ?2
             )"
        ),
        params![batch_size, max_entries],
    )?;
    if deleted > 0 {
        conn.execute_batch("PRAGMA incremental_vacuum(32);")?;
    }
    Ok(())
}

fn read_cover_thumbnail(
    conn: &Connection,
    path: &str,
    width: u32,
    height: u32,
    source_modified: i64,
    source_size: i64,
) -> Result<Option<Vec<u8>>> {
    let result: Option<(Vec<u8>, i64)> = conn
        .query_row(
            "SELECT png, last_accessed FROM cover_thumbnails
             WHERE path = ?1 AND width = ?2 AND height = ?3
               AND source_modified = ?4 AND source_size = ?5",
            params![
                path,
                width as i64,
                height as i64,
                source_modified,
                source_size
            ],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let Some((png, last_accessed)) = result else {
        return Ok(None);
    };
    let accessed_at = cover_access_timestamp();
    if accessed_at.saturating_sub(last_accessed) >= COVER_ACCESS_REFRESH_INTERVAL_MS {
        conn.execute(
            "UPDATE cover_thumbnails SET last_accessed = ?4
             WHERE path = ?1 AND width = ?2 AND height = ?3",
            params![path, width as i64, height as i64, accessed_at],
        )?;
        prune_cover_thumbnail_tier(conn, cover_tier(width, height), COVER_PRUNE_READ_BATCH)?;
    }
    Ok(Some(png))
}

fn write_cover_thumbnail(
    conn: &Connection,
    path: &str,
    width: u32,
    height: u32,
    source_modified: i64,
    source_size: i64,
    png: &[u8],
) -> Result<()> {
    conn.execute(
        "INSERT INTO cover_thumbnails(
           path, width, height, source_modified, source_size, last_accessed, png
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(path, width, height) DO UPDATE SET
           source_modified = excluded.source_modified,
           source_size = excluded.source_size,
           last_accessed = excluded.last_accessed,
           png = excluded.png",
        params![
            path,
            width as i64,
            height as i64,
            source_modified,
            source_size,
            cover_access_timestamp(),
            png
        ],
    )?;
    prune_cover_thumbnail_tier(conn, cover_tier(width, height), COVER_PRUNE_WRITE_BATCH)?;
    Ok(())
}

type CoverConnections = OnceLock<Mutex<HashMap<PathBuf, Connection>>>;
static COVER_CONNECTIONS: CoverConnections = OnceLock::new();

fn with_cover_connection<T>(
    index_dir: &Path,
    operation: impl FnOnce(&Connection) -> Result<T>,
) -> Result<T> {
    let mut connections = COVER_CONNECTIONS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| anyhow!("cover database lock poisoned"))?;
    if !connections.contains_key(index_dir) {
        let conn = open_connection(index_dir)?;
        init_schema(&conn)?;
        connections.insert(index_dir.to_path_buf(), conn);
    }
    operation(
        connections
            .get(index_dir)
            .ok_or_else(|| anyhow!("cover database connection missing"))?,
    )
}

pub fn get_cached_cover(
    index_path: String,
    path: String,
    width: u32,
    height: u32,
) -> Result<Option<Vec<u8>>, String> {
    let (source_modified, source_size) = match cover_source_signature(Path::new(&path)) {
        Ok(signature) => signature,
        Err(_) => return Ok(None),
    };
    let index_dir = PathBuf::from(index_path);
    if let Some(png) = with_cover_connection(&index_dir, |conn| {
        read_cover_thumbnail(conn, &path, width, height, source_modified, source_size)
    })
    .map_err(|e| e.to_string())?
    {
        return Ok(Some(png));
    }

    let Some(png) = crate::api::tag_reader::get_picture_from_path(path.clone(), width, height)
    else {
        return Ok(None);
    };
    with_cover_connection(&index_dir, |conn| {
        write_cover_thumbnail(
            conn,
            &path,
            width,
            height,
            source_modified,
            source_size,
            &png,
        )
    })
    .map_err(|e| e.to_string())?;
    Ok(Some(png))
}

pub fn increment_play_count(index_path: String, path: String) -> Result<(), String> {
    let index_dir = PathBuf::from(index_path);
    let conn = open_connection(&index_dir).map_err(|e| e.to_string())?;
    init_schema(&conn).map_err(|e| e.to_string())?;
    let affected = conn
        .execute(
            "UPDATE audios SET play_count = play_count + 1 WHERE path = ?1",
            params![path],
        )
        .map_err(|e| e.to_string())?;
    if affected == 0 {
        return Err("audio not found in library".to_string());
    }
    Ok(())
}

pub fn get_top_played(index_path: String, limit: i32) -> Result<Vec<PlayCountEntry>, String> {
    let index_dir = PathBuf::from(index_path);
    let conn = open_connection(&index_dir).map_err(|e| e.to_string())?;
    init_schema(&conn).map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare(
            "SELECT path, title, artist, album, play_count FROM audios WHERE play_count > 0 ORDER BY play_count DESC, path ASC LIMIT ?1",
        )
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params![limit], |row| {
            Ok(PlayCountEntry {
                path: row.get(0)?,
                title: row.get(1)?,
                artist: row.get(2)?,
                album: row.get(3)?,
                play_count: row.get(4)?,
            })
        })
        .map_err(|e| e.to_string())?;
    let mut result = Vec::new();
    for row in rows {
        result.push(row.map_err(|e| e.to_string())?);
    }
    Ok(result)
}

pub fn get_play_count(index_path: String, path: String) -> Result<i64, String> {
    let index_dir = PathBuf::from(index_path);
    let conn = open_connection(&index_dir).map_err(|e| e.to_string())?;
    init_schema(&conn).map_err(|e| e.to_string())?;
    let count: i64 = conn
        .query_row(
            "SELECT COALESCE(play_count, 0) FROM audios WHERE path = ?1",
            params![path],
            |row| row.get(0),
        )
        .map_err(|e| e.to_string())?;
    Ok(count)
}

fn unique_play_count(candidates: &HashMap<String, Vec<i64>>, key: &str) -> Option<i64> {
    let counts = candidates.get(key)?;
    if counts.len() == 1 {
        Some(counts[0])
    } else {
        None
    }
}

fn write_index_value_to_sqlite(index_dir: &Path, index: &serde_json::Value) -> Result<()> {
    let stopwatch = Instant::now();
    let folders = index
        .get("folders")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow!("missing folders"))?;

    let version = index.get("version").and_then(|v| v.as_u64()).unwrap_or(0);
    let (index_modified, index_size) = index_source_signature(index_dir)?;

    let mut current_audio_paths = HashSet::<String>::new();
    let mut current_audio_exact_paths = HashSet::<String>::new();
    let mut current_folder_paths = HashSet::<String>::new();
    let mut current_identity_inputs = Vec::<(&str, String, u64, String)>::new();
    for folder in folders {
        let folder_path = folder
            .get("path")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("folder.path missing"))?;
        if !current_folder_paths.insert(folder_path.to_string()) {
            return Err(anyhow!("duplicate folder path"));
        }
        let audios = folder
            .get("audios")
            .and_then(|v| v.as_array())
            .ok_or_else(|| anyhow!("folder.audios missing"))?;
        for audio in audios {
            let path = audio
                .get("path")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow!("audio.path missing"))?;
            if !current_audio_exact_paths.insert(path.to_string()) {
                return Err(anyhow!("duplicate audio path"));
            }
            let title = audio.get("title").and_then(|v| v.as_str()).unwrap_or("");
            let artist = audio.get("artist").and_then(|v| v.as_str()).unwrap_or("");
            let album = audio.get("album").and_then(|v| v.as_str()).unwrap_or("");
            let album_artist = audio.get("album_artist").and_then(|v| v.as_str());
            let track = audio.get("track").and_then(|v| v.as_u64()).unwrap_or(0);
            let duration = audio.get("duration").and_then(|v| v.as_u64()).unwrap_or(0);
            let bitrate = audio.get("bitrate").and_then(|v| v.as_u64());
            let sample_rate = audio.get("sample_rate").and_then(|v| v.as_u64());
            let modified = audio.get("modified").and_then(|v| v.as_u64()).unwrap_or(0);
            let path_key = path_lookup_key(path);
            current_audio_paths.insert(path_key.clone());
            current_identity_inputs.push((
                path,
                path_key,
                modified,
                metadata_match_key(
                    Path::new(path),
                    title,
                    artist,
                    album,
                    album_artist,
                    track,
                    duration,
                    bitrate,
                    sample_rate,
                ),
            ));
        }
    }

    let mut conn = open_connection(index_dir)?;
    init_schema(&conn)?;

    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;

    let stored_folder_paths = {
        let mut stmt = tx.prepare("SELECT path FROM folders")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };

    let stored_stats = {
        let mut stmt =
            tx.prepare("SELECT path, media_id, metadata_key, play_count, modified FROM audios")?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i64>(4)?,
            ))
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    let mut play_count_by_path = HashMap::<String, i64>::new();
    let mut orphan_counts_by_media_id = HashMap::<String, Vec<i64>>::new();
    let mut orphan_counts_by_metadata_key = HashMap::<String, Vec<i64>>::new();
    let mut stored_identities = HashMap::<String, (AudioIdentity, u64)>::new();
    let mut stale_audio_paths = Vec::<String>::new();
    for (path, media_id, metadata_key, play_count, modified) in stored_stats {
        let path_key = path_lookup_key(&path);
        play_count_by_path
            .entry(path_key.clone())
            .and_modify(|count| *count = (*count).max(play_count))
            .or_insert(play_count);
        if !current_audio_exact_paths.contains(&path) {
            stale_audio_paths.push(path.clone());
        }
        if !current_audio_paths.contains(&path_key) {
            if let Some(media_id) = media_id.as_ref() {
                orphan_counts_by_media_id
                    .entry(media_id.clone())
                    .or_default()
                    .push(play_count);
            }
            if let Some(metadata_key) = metadata_key.as_ref() {
                orphan_counts_by_metadata_key
                    .entry(metadata_key.clone())
                    .or_default()
                    .push(play_count);
            }
        }
        stored_identities.insert(
            path,
            (
                AudioIdentity {
                    media_id,
                    metadata_key,
                },
                modified.max(0) as u64,
            ),
        );
    }
    let stale_folder_paths: Vec<String> = stored_folder_paths
        .into_iter()
        .filter(|path| !current_folder_paths.contains(path))
        .collect();

    let mut identities = HashMap::<String, AudioIdentity>::new();
    let mut current_media_id_counts = HashMap::<String, usize>::new();
    let mut current_metadata_key_counts = HashMap::<String, usize>::new();
    let mut reused_media_ids = 0_usize;
    let mut refreshed_media_ids = 0_usize;
    for (path, path_key, modified, metadata_key) in current_identity_inputs {
        let media_id = match stored_identities.get(path) {
            Some((identity, stored_modified)) if *stored_modified == modified => {
                reused_media_ids += 1;
                identity.media_id.clone()
            }
            _ => {
                refreshed_media_ids += 1;
                stable_file_id(Path::new(path))
            }
        };
        let identity = AudioIdentity {
            media_id,
            metadata_key: Some(metadata_key),
        };
        if let Some(media_id) = identity.media_id.as_ref() {
            *current_media_id_counts.entry(media_id.clone()).or_default() += 1;
        }
        if let Some(metadata_key) = identity.metadata_key.as_ref() {
            *current_metadata_key_counts
                .entry(metadata_key.clone())
                .or_default() += 1;
        }
        identities.insert(path_key, identity);
    }

    let mut meta_changes = 0_usize;
    let mut meta_stmt = tx.prepare(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value
         WHERE meta.value IS NOT excluded.value",
    )?;
    meta_changes += meta_stmt.execute(params!["version", version.to_string()])?;
    meta_changes +=
        meta_stmt.execute(params!["index_source_modified", index_modified.to_string()])?;
    meta_changes += meta_stmt.execute(params!["index_source_size", index_size.to_string()])?;
    drop(meta_stmt);

    let mut folder_changes = 0_usize;
    let mut audio_changes = 0_usize;
    {
        let mut folder_stmt = tx.prepare(
            "INSERT INTO folders(path, modified, latest) VALUES(?1, ?2, ?3)
             ON CONFLICT(path) DO UPDATE SET
               modified = excluded.modified,
               latest = excluded.latest
             WHERE folders.modified IS NOT excluded.modified
                OR folders.latest IS NOT excluded.latest",
        )?;
        let mut audio_stmt = tx.prepare(
            "INSERT INTO audios(path, folder_path, title, artist, album, album_artist, track, disc, duration, bitrate, sample_rate, modified, created, by, play_count, media_id, metadata_key)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
             ON CONFLICT(path) DO UPDATE SET
               folder_path = excluded.folder_path,
               title = excluded.title,
               artist = excluded.artist,
               album = excluded.album,
               album_artist = excluded.album_artist,
               track = excluded.track,
               disc = excluded.disc,
               duration = excluded.duration,
               bitrate = excluded.bitrate,
               sample_rate = excluded.sample_rate,
               modified = excluded.modified,
               created = excluded.created,
               by = excluded.by,
               play_count = excluded.play_count,
               media_id = excluded.media_id,
               metadata_key = excluded.metadata_key
             WHERE audios.folder_path IS NOT excluded.folder_path
                OR audios.title IS NOT excluded.title
                OR audios.artist IS NOT excluded.artist
                OR audios.album IS NOT excluded.album
                OR audios.album_artist IS NOT excluded.album_artist
                OR audios.track IS NOT excluded.track
                OR audios.disc IS NOT excluded.disc
                OR audios.duration IS NOT excluded.duration
                OR audios.bitrate IS NOT excluded.bitrate
                OR audios.sample_rate IS NOT excluded.sample_rate
                OR audios.modified IS NOT excluded.modified
                OR audios.created IS NOT excluded.created
                OR audios.by IS NOT excluded.by
                OR audios.play_count IS NOT excluded.play_count
                OR audios.media_id IS NOT excluded.media_id
                OR audios.metadata_key IS NOT excluded.metadata_key",
        )?;

        for folder in folders {
            let folder_path = folder
                .get("path")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow!("folder.path missing"))?;
            let modified = folder.get("modified").and_then(|v| v.as_u64()).unwrap_or(0);
            let latest = folder.get("latest").and_then(|v| v.as_u64()).unwrap_or(0);
            folder_changes +=
                folder_stmt.execute(params![folder_path, modified as i64, latest as i64])?;

            let audios = folder
                .get("audios")
                .and_then(|v| v.as_array())
                .ok_or_else(|| anyhow!("folder.audios missing"))?;

            for audio in audios {
                let path = audio
                    .get("path")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow!("audio.path missing"))?;
                let title = audio.get("title").and_then(|v| v.as_str()).unwrap_or("");
                let artist = audio.get("artist").and_then(|v| v.as_str()).unwrap_or("");
                let album = audio.get("album").and_then(|v| v.as_str()).unwrap_or("");
                let album_artist = audio
                    .get("album_artist")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
                let track = audio.get("track").and_then(|v| v.as_u64()).unwrap_or(0);
                let disc = audio.get("disc").and_then(|v| v.as_u64()).unwrap_or(0);
                let duration = audio.get("duration").and_then(|v| v.as_u64()).unwrap_or(0);
                let bitrate = audio.get("bitrate").and_then(|v| v.as_u64());
                let sample_rate = audio.get("sample_rate").and_then(|v| v.as_u64());
                let modified = audio.get("modified").and_then(|v| v.as_u64()).unwrap_or(0);
                let created = audio.get("created").and_then(|v| v.as_u64()).unwrap_or(0);
                let by = audio
                    .get("by")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
                let path_key = path_lookup_key(path);
                let identity = identities.get(&path_key).cloned().unwrap_or_default();
                let play_count = play_count_by_path
                    .get(&path_key)
                    .copied()
                    .or_else(|| {
                        identity.media_id.as_deref().and_then(|media_id| {
                            if current_media_id_counts.get(media_id) == Some(&1) {
                                unique_play_count(&orphan_counts_by_media_id, media_id)
                            } else {
                                None
                            }
                        })
                    })
                    .or_else(|| {
                        identity.metadata_key.as_deref().and_then(|metadata_key| {
                            if current_metadata_key_counts.get(metadata_key) == Some(&1) {
                                unique_play_count(&orphan_counts_by_metadata_key, metadata_key)
                            } else {
                                None
                            }
                        })
                    })
                    .unwrap_or(0);

                audio_changes += audio_stmt.execute(params![
                    path,
                    folder_path,
                    title,
                    artist,
                    album,
                    album_artist,
                    track as i64,
                    disc as i64,
                    duration as i64,
                    bitrate.map(|v| v as i64),
                    sample_rate.map(|v| v as i64),
                    modified as i64,
                    created as i64,
                    by,
                    play_count,
                    identity.media_id,
                    identity.metadata_key,
                ])?;
            }
        }
    }

    let mut removed_audios = 0_usize;
    {
        let mut stmt = tx.prepare("DELETE FROM audios WHERE path = ?1")?;
        for path in &stale_audio_paths {
            removed_audios += stmt.execute(params![path])?;
        }
    }
    let mut removed_folders = 0_usize;
    {
        let mut stmt = tx.prepare("DELETE FROM folders WHERE path = ?1")?;
        for path in &stale_folder_paths {
            removed_folders += stmt.execute(params![path])?;
        }
    }
    let removed_covers = tx.execute(
        "DELETE FROM cover_thumbnails WHERE path NOT IN (SELECT path FROM audios)",
        [],
    )?;

    tx.commit()?;

    conn.execute_batch("PRAGMA optimize;")?;
    log_to_dart(format!(
        "[perf] sqlite index sync audios={} changed={} removed={} folders={} changed={} removed={} meta={} coversRemoved={} mediaIdsReused={} mediaIdsRefreshed={} elapsed={}ms",
        current_audio_exact_paths.len(),
        audio_changes,
        removed_audios,
        current_folder_paths.len(),
        folder_changes,
        removed_folders,
        meta_changes,
        removed_covers,
        reused_media_ids,
        refreshed_media_ids,
        stopwatch.elapsed().as_millis(),
    ));

    Ok(())
}

pub fn migrate_index_json_to_sqlite(index_path: String) -> Result<()> {
    let index_dir = PathBuf::from(index_path);
    with_index_write_lock(|| {
        let index_json_path = index_dir.join("index.json");
        let bytes = std::fs::read(index_json_path)?;
        let index: serde_json::Value = serde_json::from_slice(&bytes)?;
        write_index_value_to_sqlite(&index_dir, &index)
    })
}

pub fn read_index_from_sqlite(index_path: String) -> Result<Vec<IndexFolder>> {
    let index_dir = PathBuf::from(index_path);
    let conn = open_connection(&index_dir)?;
    init_schema(&conn)?;
    ensure_index_source_current(&conn, &index_dir)?;

    let version: Option<String> = conn
        .query_row("SELECT value FROM meta WHERE key = 'version'", [], |row| {
            row.get(0)
        })
        .optional()?;
    if version.is_none() {
        return Err(anyhow!("sqlite index not initialized"));
    }

    let mut folders = Vec::new();
    {
        let mut stmt = conn.prepare("SELECT path, modified, latest FROM folders ORDER BY path")?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let path: String = row.get(0)?;
            let modified: i64 = row.get(1)?;
            let latest: i64 = row.get(2)?;
            folders.push(IndexFolder {
                path,
                modified: modified.max(0) as u64,
                latest: latest.max(0) as u64,
                audios: Vec::new(),
            });
        }
    }

    let mut folder_index = 0;
    {
        let mut stmt = conn.prepare(
            "SELECT folder_path, title, artist, album, album_artist, track, disc, duration, bitrate, sample_rate, path, modified, created, by, play_count
             FROM audios ORDER BY folder_path, path",
        )?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let folder_path: String = row.get(0)?;
            let title: String = row.get(1)?;
            let artist: String = row.get(2)?;
            let album: String = row.get(3)?;
            let album_artist: Option<String> = row.get(4)?;
            let track: Option<i64> = row.get(5)?;
            let disc: Option<i64> = row.get(6)?;
            let duration: i64 = row.get(7)?;
            let bitrate: Option<i64> = row.get(8)?;
            let sample_rate: Option<i64> = row.get(9)?;
            let path: String = row.get(10)?;
            let modified: i64 = row.get(11)?;
            let created: i64 = row.get(12)?;
            let by: Option<String> = row.get(13)?;
            let play_count: i64 = row.get(14)?;

            let audio = IndexAudio {
                title,
                artist,
                album,
                album_artist,
                track: track.unwrap_or(0).max(0) as u32,
                disc: disc.unwrap_or(0).max(0) as u32,
                duration: duration.max(0) as u64,
                bitrate: bitrate.map(|v| v.max(0) as u32),
                sample_rate: sample_rate.map(|v| v.max(0) as u32),
                path,
                modified: modified.max(0) as u64,
                created: created.max(0) as u64,
                by,
                play_count,
            };

            while folder_index < folders.len()
                && folders[folder_index].path.as_str() < folder_path.as_str()
            {
                folder_index += 1;
            }
            if folder_index < folders.len() && folders[folder_index].path == folder_path {
                folders[folder_index].audios.push(audio);
            }
        }
    }

    Ok(folders)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_dir(label: &str) -> PathBuf {
        let base = std::env::temp_dir().join(format!(
            "pure_music_{}_{}_{}",
            label,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&base).unwrap();
        base
    }

    fn test_audio(path: &Path) -> serde_json::Value {
        serde_json::json!({
            "title": "Track",
            "artist": "Artist",
            "album": "Album",
            "album_artist": "Artist",
            "track": 1,
            "disc": 1,
            "duration": 180,
            "bitrate": 320,
            "sample_rate": 44100,
            "path": path.to_string_lossy(),
            "modified": 4,
            "created": 5,
            "by": "Lofty"
        })
    }

    fn test_index(folder: &Path, audios: Vec<serde_json::Value>) -> serde_json::Value {
        serde_json::json!({
            "version": 110,
            "folders": [{
                "path": folder.to_string_lossy(),
                "modified": 1,
                "latest": 2,
                "audios": audios
            }]
        })
    }

    fn sync_test_index(base: &Path, index: &serde_json::Value) {
        write_index_snapshot(base, index).unwrap();
    }

    #[test]
    fn roundtrip_index() {
        let base = std::env::temp_dir().join(format!(
            "pure_music_test_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        ));
        std::fs::create_dir_all(&base).unwrap();

        let index = serde_json::json!({
            "version": 110,
            "folders": [{
                "path": "C:\\\\Music",
                "modified": 1,
                "latest": 2,
                "audios": [{
                    "title": "t",
                    "artist": "a",
                    "album": "al",
                    "album_artist": null,
                    "track": 0,
                    "disc": 2,
                    "duration": 3,
                    "bitrate": 320,
                    "sample_rate": 44100,
                    "path": "C:\\\\Music\\\\t.mp3",
                    "modified": 4,
                    "created": 5,
                    "by": "Lofty"
                }]
            }]
        });
        std::fs::write(base.join("index.json"), index.to_string()).unwrap();

        migrate_index_json_to_sqlite(base.to_string_lossy().to_string()).unwrap();
        let folders = read_index_from_sqlite(base.to_string_lossy().to_string()).unwrap();

        assert_eq!(folders.len(), 1);
        assert_eq!(folders[0].audios.len(), 1);
        assert_eq!(folders[0].audios[0].title, "t");
        assert_eq!(folders[0].audios[0].disc, 2);
    }

    #[test]
    fn current_index_snapshot_requires_matching_json_signature() {
        let base = test_dir("index_snapshot_signature");
        let index = test_index(&base, vec![test_audio(&base.join("track.flac"))]);
        std::fs::write(base.join("index.json"), index.to_string()).unwrap();
        migrate_index_json_to_sqlite(base.to_string_lossy().to_string()).unwrap();

        let snapshot = read_current_index_snapshot(&base).unwrap().unwrap();
        assert_eq!(snapshot.version, 110);
        assert_eq!(snapshot.folders.len(), 1);
        assert_eq!(snapshot.folders[0].path, base.to_string_lossy());

        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(base.join("index.json"))
            .unwrap();
        std::io::Write::write_all(&mut file, b" ").unwrap();
        drop(file);
        assert!(read_current_index_snapshot(&base).unwrap().is_none());
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn sqlite_read_requires_matching_json_signature() {
        let base = test_dir("sqlite_read_signature");
        let index = test_index(&base, vec![test_audio(&base.join("track.flac"))]);
        sync_test_index(&base, &index);
        assert_eq!(
            read_index_from_sqlite(base.to_string_lossy().to_string())
                .unwrap()
                .len(),
            1
        );

        let mut changed = index;
        changed["folders"][0]["audios"][0]["title"] = serde_json::json!("Changed");
        write_index_json(&base, &changed).unwrap();
        assert!(read_index_from_sqlite(base.to_string_lossy().to_string()).is_err());
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn failed_atomic_replace_keeps_previous_index() {
        let base = test_dir("atomic_index_replace");
        let index_path = base.join("index.json");
        std::fs::write(&index_path, b"old index").unwrap();
        let error = atomic_write_with_replace(&index_path, b"new index", |_, _| {
            Err(io::Error::new(io::ErrorKind::PermissionDenied, "blocked"))
        })
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(std::fs::read(&index_path).unwrap(), b"old index");
        assert_eq!(
            std::fs::read_dir(&base).unwrap().count(),
            1,
            "temporary index file should be removed"
        );
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn index_write_lock_covers_json_and_sqlite_sync() {
        let base = test_dir("serialized_index_write");
        let index = test_index(&base, vec![test_audio(&base.join("track.flac"))]);
        let (json_written_tx, json_written_rx) = std::sync::mpsc::channel();
        let (continue_tx, continue_rx) = std::sync::mpsc::channel();
        let writer_base = base.clone();
        let writer = std::thread::spawn(move || {
            write_index_snapshot_with(&writer_base, &index, || {
                json_written_tx.send(()).unwrap();
                continue_rx.recv().unwrap();
            })
            .unwrap();
        });

        json_written_rx.recv().unwrap();
        let lock_is_held = matches!(
            INDEX_WRITE_LOCK.get().unwrap().try_lock(),
            Err(std::sync::TryLockError::WouldBlock)
        );
        continue_tx.send(()).unwrap();
        writer.join().unwrap();

        assert!(lock_is_held);
        assert_eq!(
            read_index_from_sqlite(base.to_string_lossy().to_string())
                .unwrap()
                .len(),
            1
        );
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn sqlite_sync_requires_the_source_index() {
        let base = test_dir("sqlite_sync_source");
        let index = test_index(&base, Vec::new());
        assert!(write_index_value_to_sqlite(&base, &index).is_err());
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn failed_sqlite_sync_keeps_old_rows_hidden() {
        let base = test_dir("sqlite_sync_failure");
        let audio_path = base.join("track.flac");
        std::fs::write(&audio_path, [1, 2, 3, 4]).unwrap();
        let mut index = test_index(&base, vec![test_audio(&audio_path)]);
        sync_test_index(&base, &index);
        let conn = open_connection(&base).unwrap();
        conn.execute_batch(
            "CREATE TRIGGER reject_audio_update BEFORE UPDATE OF title ON audios
               BEGIN SELECT RAISE(FAIL, 'blocked'); END;",
        )
        .unwrap();
        drop(conn);

        index["folders"][0]["audios"][0]["title"] = serde_json::json!("Changed");
        write_index_json(&base, &index).unwrap();
        assert!(write_index_value_to_sqlite(&base, &index).is_err());
        let conn = open_raw_connection(&sqlite_path(&base)).unwrap();
        assert_eq!(
            conn.query_row("SELECT title FROM audios", [], |row| row
                .get::<_, String>(0))
                .unwrap(),
            "Track"
        );
        drop(conn);
        assert!(read_index_from_sqlite(base.to_string_lossy().to_string()).is_err());
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn cover_thumbnail_uses_source_signature() {
        let base = std::env::temp_dir().join(format!(
            "pure_music_cover_cache_test_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        ));
        std::fs::create_dir_all(&base).unwrap();
        let conn = open_connection(&base).unwrap();
        init_schema(&conn).unwrap();

        write_cover_thumbnail(&conn, "track.flac", 48, 48, 10, 20, &[1, 2, 3]).unwrap();
        assert_eq!(
            read_cover_thumbnail(&conn, "track.flac", 48, 48, 10, 20).unwrap(),
            Some(vec![1, 2, 3])
        );
        assert_eq!(
            read_cover_thumbnail(&conn, "track.flac", 48, 48, 11, 20).unwrap(),
            None
        );
    }

    #[test]
    fn cover_thumbnail_cache_bounds_large_tier() {
        let base = test_dir("large_cover_cache_limit");
        let conn = open_connection(&base).unwrap();
        init_schema(&conn).unwrap();
        for index in 0..(MAX_PERSISTED_LARGE_COVERS + 5) {
            write_cover_thumbnail(
                &conn,
                &format!("track-{index}.flac"),
                630,
                630,
                10,
                20,
                &[1, 2, 3],
            )
            .unwrap();
        }

        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM cover_thumbnails WHERE width > 320 OR height > 320",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, MAX_PERSISTED_LARGE_COVERS);
        assert_eq!(
            read_cover_thumbnail(&conn, "track-0.flac", 630, 630, 10, 20).unwrap(),
            None
        );
        assert_eq!(
            read_cover_thumbnail(
                &conn,
                &format!("track-{}.flac", MAX_PERSISTED_LARGE_COVERS + 4),
                630,
                630,
                10,
                20,
            )
            .unwrap(),
            Some(vec![1, 2, 3])
        );
        drop(conn);
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn oversized_legacy_cover_cache_rebuilds_without_copying_covers() {
        let base = test_dir("legacy_cover_cache_migration");
        let db_path = sqlite_path(&base);
        let conn = open_raw_connection(&db_path).unwrap();
        conn.execute_batch(
            "PRAGMA auto_vacuum = NONE;
             CREATE TABLE legacy_layout_anchor(value INTEGER);",
        )
        .unwrap();
        init_schema(&conn).unwrap();
        assert_eq!(
            conn.pragma_query_value(None, "auto_vacuum", |row| row.get::<_, i64>(0))
                .unwrap(),
            0
        );
        conn.execute("INSERT INTO meta(key, value) VALUES('version', '110')", [])
            .unwrap();
        conn.execute(
            "INSERT INTO folders(path, modified, latest) VALUES('C:/Music', 1, 2)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO audios(
               path, folder_path, title, artist, album, duration, modified, created, play_count
             ) VALUES('C:/Music/track.flac', 'C:/Music', 'Track', 'Artist', 'Album', 180, 4, 5, 7)",
            [],
        )
        .unwrap();
        for index in 0..=MAX_PERSISTED_LARGE_COVERS {
            conn.execute(
                "INSERT INTO cover_thumbnails(
                   path, width, height, source_modified, source_size, last_accessed, png
                 ) VALUES(?1, 630, 630, 10, 20, ?2, ?3)",
                params![format!("track-{index}.flac"), index, [1_u8, 2, 3]],
            )
            .unwrap();
        }
        drop(conn);

        let conn = open_connection(&base).unwrap();
        assert_eq!(
            conn.pragma_query_value(None, "auto_vacuum", |row| row.get::<_, i64>(0))
                .unwrap(),
            2
        );
        assert!(has_database_layout_marker(&conn).unwrap());
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM cover_thumbnails", [], |row| row
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            conn.query_row(
                "SELECT play_count FROM audios WHERE path = 'C:/Music/track.flac'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
            7
        );
        drop(conn);
        assert!(!legacy_sqlite_path(&base).exists());
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn identical_index_sync_does_not_rewrite_library_rows() {
        let base = test_dir("incremental_index_sync");
        let audio_path = base.join("track.flac");
        std::fs::write(&audio_path, [1, 2, 3, 4]).unwrap();
        let index = test_index(&base, vec![test_audio(&audio_path)]);
        sync_test_index(&base, &index);
        std::fs::remove_file(&audio_path).unwrap();

        let conn = open_connection(&base).unwrap();
        conn.execute_batch(
            "CREATE TABLE sync_audit(kind TEXT NOT NULL);
             CREATE TRIGGER audit_folder_insert AFTER INSERT ON folders
               BEGIN INSERT INTO sync_audit(kind) VALUES('folder_insert'); END;
             CREATE TRIGGER audit_folder_update AFTER UPDATE ON folders
               BEGIN INSERT INTO sync_audit(kind) VALUES('folder_update'); END;
             CREATE TRIGGER audit_folder_delete AFTER DELETE ON folders
               BEGIN INSERT INTO sync_audit(kind) VALUES('folder_delete'); END;
             CREATE TRIGGER audit_audio_insert AFTER INSERT ON audios
               BEGIN INSERT INTO sync_audit(kind) VALUES('audio_insert'); END;
             CREATE TRIGGER audit_audio_update AFTER UPDATE ON audios
               BEGIN INSERT INTO sync_audit(kind) VALUES('audio_update'); END;
             CREATE TRIGGER audit_audio_delete AFTER DELETE ON audios
               BEGIN INSERT INTO sync_audit(kind) VALUES('audio_delete'); END;",
        )
        .unwrap();
        drop(conn);

        sync_test_index(&base, &index);
        let conn = open_connection(&base).unwrap();
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM sync_audit", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
            0
        );
        drop(conn);

        let mut changed = index;
        changed["folders"][0]["audios"][0]["title"] = serde_json::json!("Changed");
        sync_test_index(&base, &changed);
        let conn = open_connection(&base).unwrap();
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM sync_audit", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
            1
        );
        drop(conn);
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn play_count_survives_file_rename() {
        let base = test_dir("play_count_rename");
        let old_path = base.join("old.flac");
        let new_path = base.join("renamed.flac");
        std::fs::write(&old_path, [1, 2, 3, 4]).unwrap();
        sync_test_index(&base, &test_index(&base, vec![test_audio(&old_path)]));
        increment_play_count(
            base.to_string_lossy().to_string(),
            old_path.to_string_lossy().to_string(),
        )
        .unwrap();

        std::fs::rename(&old_path, &new_path).unwrap();
        sync_test_index(&base, &test_index(&base, vec![test_audio(&new_path)]));

        assert_eq!(
            get_play_count(
                base.to_string_lossy().to_string(),
                new_path.to_string_lossy().to_string(),
            )
            .unwrap(),
            1
        );
        assert!(get_play_count(
            base.to_string_lossy().to_string(),
            old_path.to_string_lossy().to_string(),
        )
        .is_err());
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn play_count_survives_unique_metadata_match() {
        let base = test_dir("play_count_metadata");
        let moved_dir = base.join("moved");
        std::fs::create_dir_all(&moved_dir).unwrap();
        let old_path = base.join("old.flac");
        let new_path = moved_dir.join("new.flac");
        std::fs::write(&old_path, [1, 2, 3, 4]).unwrap();
        std::fs::write(&new_path, [1, 2, 3, 4]).unwrap();
        sync_test_index(&base, &test_index(&base, vec![test_audio(&old_path)]));
        increment_play_count(
            base.to_string_lossy().to_string(),
            old_path.to_string_lossy().to_string(),
        )
        .unwrap();

        sync_test_index(&base, &test_index(&moved_dir, vec![test_audio(&new_path)]));

        assert_eq!(
            get_play_count(
                base.to_string_lossy().to_string(),
                new_path.to_string_lossy().to_string(),
            )
            .unwrap(),
            1
        );
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn ambiguous_metadata_does_not_duplicate_play_count() {
        let base = test_dir("play_count_ambiguous");
        let old_path = base.join("old.flac");
        let first_path = base.join("first.flac");
        let second_path = base.join("second.flac");
        for path in [&old_path, &first_path, &second_path] {
            std::fs::write(path, [1, 2, 3, 4]).unwrap();
        }
        sync_test_index(&base, &test_index(&base, vec![test_audio(&old_path)]));
        increment_play_count(
            base.to_string_lossy().to_string(),
            old_path.to_string_lossy().to_string(),
        )
        .unwrap();

        sync_test_index(
            &base,
            &test_index(
                &base,
                vec![test_audio(&first_path), test_audio(&second_path)],
            ),
        );

        assert_eq!(
            get_play_count(
                base.to_string_lossy().to_string(),
                first_path.to_string_lossy().to_string(),
            )
            .unwrap(),
            0
        );
        assert_eq!(
            get_play_count(
                base.to_string_lossy().to_string(),
                second_path.to_string_lossy().to_string(),
            )
            .unwrap(),
            0
        );
        std::fs::remove_dir_all(base).unwrap();
    }
}
