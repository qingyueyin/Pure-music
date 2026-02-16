use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Result};
use rusqlite::{params, Connection, OptionalExtension};

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

fn open_connection(index_dir: &Path) -> Result<Connection> {
    let db_path = sqlite_path(index_dir);
    if let Some(parent) = db_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    Ok(Connection::open(db_path)?)
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
          by TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_audios_folder_path ON audios(folder_path);
        CREATE INDEX IF NOT EXISTS idx_audios_title ON audios(title);
        CREATE INDEX IF NOT EXISTS idx_audios_artist ON audios(artist);
        CREATE INDEX IF NOT EXISTS idx_audios_album ON audios(album);
        "#,
    )?;
    Ok(())
}

pub(crate) fn write_index_value_to_sqlite(index_dir: &Path, index: &serde_json::Value) -> Result<()> {
    let folders = index
        .get("folders")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow!("missing folders"))?;

    let version = index.get("version").and_then(|v| v.as_u64()).unwrap_or(0);

    let mut conn = open_connection(index_dir)?;
    init_schema(&conn)?;

    let tx = conn.transaction()?;

    tx.execute("DELETE FROM audios", [])?;
    tx.execute("DELETE FROM folders", [])?;
    tx.execute("DELETE FROM meta WHERE key = 'version'", [])?;
    tx.execute(
        "INSERT INTO meta(key, value) VALUES('version', ?1)",
        params![version.to_string()],
    )?;

    {
        let mut folder_stmt =
            tx.prepare("INSERT INTO folders(path, modified, latest) VALUES(?1, ?2, ?3)")?;
        let mut audio_stmt = tx.prepare(
            "INSERT INTO audios(path, folder_path, title, artist, album, album_artist, track, duration, bitrate, sample_rate, modified, created, by)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
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
                let by = audio.get("by").and_then(|v| v.as_str()).map(|s| s.to_string());

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
                ])?;
            }
        }
    }

    tx.commit()?;
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
        .query_row("SELECT value FROM meta WHERE key = 'version'", [], |row| row.get(0))
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
            "SELECT folder_path, title, artist, album, album_artist, track, duration, bitrate, sample_rate, path, modified, created, by
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

    #[test]
    fn roundtrip_index() {
        let base = std::env::temp_dir()
            .join(format!(
                "coriander_player_test_{}_{}",
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
}
