use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, UNIX_EPOCH};

use anyhow::{anyhow, Result};
use md5::{Digest, Md5};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};

#[derive(Clone)]
pub struct IndexAudio {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: Option<String>,
    pub track: u32,
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

fn sqlite_path(index_dir: &Path) -> PathBuf {
    index_dir.join("library.sqlite")
}

#[derive(Clone, Default)]
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

fn open_connection(index_dir: &Path) -> Result<Connection> {
    let db_path = sqlite_path(index_dir);
    if let Some(parent) = db_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let conn = Connection::open(db_path)?;
    conn.busy_timeout(Duration::from_secs(2))?;
    Ok(conn)
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

        CREATE INDEX IF NOT EXISTS idx_audios_folder_path ON audios(folder_path);
        CREATE INDEX IF NOT EXISTS idx_audios_title ON audios(title);
        CREATE INDEX IF NOT EXISTS idx_audios_artist ON audios(artist);
        CREATE INDEX IF NOT EXISTS idx_audios_album ON audios(album);

        CREATE TABLE IF NOT EXISTS cover_thumbnails (
          path TEXT NOT NULL,
          width INTEGER NOT NULL,
          height INTEGER NOT NULL,
          source_modified INTEGER NOT NULL,
          source_size INTEGER NOT NULL,
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
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_audios_media_id ON audios(media_id);
         CREATE INDEX IF NOT EXISTS idx_audios_metadata_key ON audios(metadata_key);",
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

fn cover_source_signature(path: &Path) -> Result<(i64, i64)> {
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

fn read_cover_thumbnail(
    conn: &Connection,
    path: &str,
    width: u32,
    height: u32,
    source_modified: i64,
    source_size: i64,
) -> Result<Option<Vec<u8>>> {
    Ok(conn
        .query_row(
            "SELECT png FROM cover_thumbnails
             WHERE path = ?1 AND width = ?2 AND height = ?3
               AND source_modified = ?4 AND source_size = ?5",
            params![
                path,
                width as i64,
                height as i64,
                source_modified,
                source_size
            ],
            |row| row.get(0),
        )
        .optional()?)
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
           path, width, height, source_modified, source_size, png
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(path, width, height) DO UPDATE SET
           source_modified = excluded.source_modified,
           source_size = excluded.source_size,
           png = excluded.png",
        params![
            path,
            width as i64,
            height as i64,
            source_modified,
            source_size,
            png
        ],
    )?;
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
            "SELECT path, title, artist, album, play_count FROM audios WHERE play_count > 0 ORDER BY play_count DESC LIMIT ?1",
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

pub(crate) fn write_index_value_to_sqlite(
    index_dir: &Path,
    index: &serde_json::Value,
) -> Result<()> {
    let folders = index
        .get("folders")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow!("missing folders"))?;

    let version = index.get("version").and_then(|v| v.as_u64()).unwrap_or(0);

    let mut identities = HashMap::<String, AudioIdentity>::new();
    let mut current_audio_paths = HashSet::<String>::new();
    let mut current_media_id_counts = HashMap::<String, usize>::new();
    let mut current_metadata_key_counts = HashMap::<String, usize>::new();
    for folder in folders {
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
            let album_artist = audio.get("album_artist").and_then(|v| v.as_str());
            let track = audio.get("track").and_then(|v| v.as_u64()).unwrap_or(0);
            let duration = audio.get("duration").and_then(|v| v.as_u64()).unwrap_or(0);
            let bitrate = audio.get("bitrate").and_then(|v| v.as_u64());
            let sample_rate = audio.get("sample_rate").and_then(|v| v.as_u64());
            let identity = audio_identity(
                path,
                title,
                artist,
                album,
                album_artist,
                track,
                duration,
                bitrate,
                sample_rate,
            );
            if let Some(media_id) = identity.media_id.as_ref() {
                *current_media_id_counts.entry(media_id.clone()).or_default() += 1;
            }
            if let Some(metadata_key) = identity.metadata_key.as_ref() {
                *current_metadata_key_counts
                    .entry(metadata_key.clone())
                    .or_default() += 1;
            }
            let path_key = path_lookup_key(path);
            current_audio_paths.insert(path_key.clone());
            identities.insert(path_key, identity);
        }
    }

    let mut conn = open_connection(index_dir)?;
    init_schema(&conn)?;

    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;

    let stored_stats = {
        let mut stmt = tx.prepare("SELECT path, media_id, metadata_key, play_count FROM audios")?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, i64>(3)?,
            ))
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    let mut play_count_by_path = HashMap::<String, i64>::new();
    let mut orphan_counts_by_media_id = HashMap::<String, Vec<i64>>::new();
    let mut orphan_counts_by_metadata_key = HashMap::<String, Vec<i64>>::new();
    for (path, media_id, metadata_key, play_count) in stored_stats {
        let path_key = path_lookup_key(&path);
        play_count_by_path
            .entry(path_key.clone())
            .and_modify(|count| *count = (*count).max(play_count))
            .or_insert(play_count);
        if current_audio_paths.contains(&path_key) {
            continue;
        }
        if let Some(media_id) = media_id {
            orphan_counts_by_media_id
                .entry(media_id)
                .or_default()
                .push(play_count);
        }
        if let Some(metadata_key) = metadata_key {
            orphan_counts_by_metadata_key
                .entry(metadata_key)
                .or_default()
                .push(play_count);
        }
    }

    tx.execute("DELETE FROM audios", [])?;
    tx.execute("DELETE FROM folders", [])?;

    tx.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES('version', ?1)",
        params![version.to_string()],
    )?;

    {
        let mut folder_stmt =
            tx.prepare("INSERT INTO folders(path, modified, latest) VALUES(?1, ?2, ?3)")?;
        let mut audio_stmt = tx.prepare(
            "INSERT INTO audios(path, folder_path, title, artist, album, album_artist, track, duration, bitrate, sample_rate, modified, created, by, play_count, media_id, metadata_key)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
        )?;

        for folder in folders {
            let folder_path = folder
                .get("path")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow!("folder.path missing"))?;
            let modified = folder.get("modified").and_then(|v| v.as_u64()).unwrap_or(0);
            let latest = folder.get("latest").and_then(|v| v.as_u64()).unwrap_or(0);
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

                audio_stmt.execute(params![
                    path,
                    folder_path,
                    title,
                    artist,
                    album,
                    album_artist,
                    track as i64,
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
    tx.execute(
        "DELETE FROM cover_thumbnails WHERE path NOT IN (SELECT path FROM audios)",
        [],
    )?;

    tx.commit()?;

    conn.execute_batch("PRAGMA optimize;")?;

    Ok(())
}

pub fn migrate_index_json_to_sqlite(index_path: String) -> Result<()> {
    let index_dir = PathBuf::from(index_path);
    let index_json_path = index_dir.join("index.json");
    let bytes = std::fs::read(index_json_path)?;
    let index: serde_json::Value = serde_json::from_slice(&bytes)?;
    write_index_value_to_sqlite(&index_dir, &index)
}

pub fn read_index_from_sqlite(index_path: String) -> Result<Vec<IndexFolder>> {
    let index_dir = PathBuf::from(index_path);
    let conn = open_connection(&index_dir)?;
    init_schema(&conn)?;

    let version: Option<String> = conn
        .query_row("SELECT value FROM meta WHERE key = 'version'", [], |row| {
            row.get(0)
        })
        .optional()?;
    if version.is_none() {
        return Err(anyhow!("sqlite index not initialized"));
    }

    let mut folders: Vec<(String, u64, u64)> = vec![];
    {
        let mut stmt = conn.prepare("SELECT path, modified, latest FROM folders ORDER BY path")?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let path: String = row.get(0)?;
            let modified: i64 = row.get(1)?;
            let latest: i64 = row.get(2)?;
            folders.push((path, modified.max(0) as u64, latest.max(0) as u64));
        }
    }

    let mut audios_by_folder: HashMap<String, Vec<IndexAudio>> = HashMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT folder_path, title, artist, album, album_artist, track, duration, bitrate, sample_rate, path, modified, created, by, play_count
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
            let duration: i64 = row.get(6)?;
            let bitrate: Option<i64> = row.get(7)?;
            let sample_rate: Option<i64> = row.get(8)?;
            let path: String = row.get(9)?;
            let modified: i64 = row.get(10)?;
            let created: i64 = row.get(11)?;
            let by: Option<String> = row.get(12)?;
            let play_count: i64 = row.get(13)?;

            let audio = IndexAudio {
                title,
                artist,
                album,
                album_artist,
                track: track.unwrap_or(0).max(0) as u32,
                duration: duration.max(0) as u64,
                bitrate: bitrate.map(|v| v.max(0) as u32),
                sample_rate: sample_rate.map(|v| v.max(0) as u32),
                path,
                modified: modified.max(0) as u64,
                created: created.max(0) as u64,
                by,
                play_count,
            };

            audios_by_folder.entry(folder_path).or_default().push(audio);
        }
    }

    let mut result = Vec::with_capacity(folders.len());
    for (path, modified, latest) in folders {
        let audios = audios_by_folder.remove(&path).unwrap_or_default();
        result.push(IndexFolder {
            path,
            modified,
            latest,
            audios,
        });
    }

    Ok(result)
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
    fn play_count_survives_file_rename() {
        let base = test_dir("play_count_rename");
        let old_path = base.join("old.flac");
        let new_path = base.join("renamed.flac");
        std::fs::write(&old_path, [1, 2, 3, 4]).unwrap();
        write_index_value_to_sqlite(&base, &test_index(&base, vec![test_audio(&old_path)]))
            .unwrap();
        increment_play_count(
            base.to_string_lossy().to_string(),
            old_path.to_string_lossy().to_string(),
        )
        .unwrap();

        std::fs::rename(&old_path, &new_path).unwrap();
        write_index_value_to_sqlite(&base, &test_index(&base, vec![test_audio(&new_path)]))
            .unwrap();

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
        write_index_value_to_sqlite(&base, &test_index(&base, vec![test_audio(&old_path)]))
            .unwrap();
        increment_play_count(
            base.to_string_lossy().to_string(),
            old_path.to_string_lossy().to_string(),
        )
        .unwrap();

        write_index_value_to_sqlite(&base, &test_index(&moved_dir, vec![test_audio(&new_path)]))
            .unwrap();

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
        write_index_value_to_sqlite(&base, &test_index(&base, vec![test_audio(&old_path)]))
            .unwrap();
        increment_play_count(
            base.to_string_lossy().to_string(),
            old_path.to_string_lossy().to_string(),
        )
        .unwrap();

        write_index_value_to_sqlite(
            &base,
            &test_index(
                &base,
                vec![test_audio(&first_path), test_audio(&second_path)],
            ),
        )
        .unwrap();

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
