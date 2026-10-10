use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, TransactionBehavior};

use super::DayCount;
use super::PlayCountEntry;
use super::PlayHistoryEntry;
use super::PlayHistoryStats;
use super::{init_schema, normalize_identity_part, open_connection, path_lookup_key};

pub fn increment_play_count(index_path: String, path: String) -> Result<(), String> {
    let index_dir = PathBuf::from(index_path);
    let mut conn = open_connection(&index_dir).map_err(|e| e.to_string())?;
    init_schema(&conn).map_err(|e| e.to_string())?;
    let tx = conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|e| e.to_string())?;
    let affected = tx
        .execute(
            "UPDATE audios SET play_count = play_count + 1 WHERE path = ?1",
            params![path],
        )
        .map_err(|e| e.to_string())?;
    if affected == 0 {
        return Err("audio not found in library".to_string());
    }
    record_history_row(&tx, &path)?;
    tx.commit().map_err(|e| e.to_string())?;
    Ok(())
}

/// 写入一条播放流水；路径字典只存一份路径，流水只存整数 ID。
/// 同一秒的重复记录按主键去重。
fn record_history_row(conn: &rusqlite::Connection, path: &str) -> Result<(), String> {
    conn.execute(
        "INSERT OR IGNORE INTO listen_paths(path) VALUES(?1)",
        params![path],
    )
    .map_err(|e| e.to_string())?;
    let path_id: i64 = conn
        .query_row(
            "SELECT id FROM listen_paths WHERE path = ?1",
            params![path],
            |row| row.get(0),
        )
        .map_err(|e| e.to_string())?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_secs() as i64;
    conn.execute(
        "INSERT OR IGNORE INTO play_history(path_id, played_at) VALUES(?1, ?2)",
        params![path_id, now],
    )
    .map_err(|e| e.to_string())?;
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

pub fn export_play_counts(index_path: String) -> Result<Vec<PlayCountEntry>, String> {
    let index_dir = PathBuf::from(index_path);
    let conn = open_connection(&index_dir).map_err(|e| e.to_string())?;
    init_schema(&conn).map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare("SELECT path, title, artist, album, play_count FROM audios WHERE play_count > 0")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params![], |row| {
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

fn play_count_metadata_key(title: &str, artist: &str, album: &str) -> Option<String> {
    let title = normalize_identity_part(title);
    let artist = normalize_identity_part(artist);
    let album = normalize_identity_part(album);
    if title.is_empty() && artist.is_empty() && album.is_empty() {
        return None;
    }
    Some(format!("{title}\u{1f}{artist}\u{1f}{album}"))
}

/// 按路径或唯一的标题、艺术家、专辑组合写回播放次数；不新建曲库行。
/// `overwrite` 为 false 时取本机与传入值的较大值，为 true 时直接使用传入值。
pub fn import_play_counts(
    index_path: String,
    entries: Vec<PlayCountEntry>,
    overwrite: bool,
) -> Result<u32, String> {
    let index_dir = PathBuf::from(index_path);
    let mut conn = open_connection(&index_dir).map_err(|e| e.to_string())?;
    init_schema(&conn).map_err(|e| e.to_string())?;
    let tx = conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|e| e.to_string())?;
    if overwrite {
        tx.execute("UPDATE audios SET play_count = 0", [])
            .map_err(|e| e.to_string())?;
    }

    let mut paths_by_key = HashMap::<String, Vec<String>>::new();
    let mut paths_by_metadata = HashMap::<String, Vec<String>>::new();
    {
        let mut stmt = tx
            .prepare("SELECT path, title, artist, album FROM audios")
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        for row in rows {
            let (path, title, artist, album) = row.map_err(|e| e.to_string())?;
            paths_by_key
                .entry(path_lookup_key(&path))
                .or_default()
                .push(path.clone());
            if let Some(key) = play_count_metadata_key(&title, &artist, &album) {
                paths_by_metadata.entry(key).or_default().push(path);
            }
        }
    }

    let mut imported = 0u32;
    for entry in entries {
        let play_count = entry.play_count.max(0);
        let target_path = paths_by_key
            .get(&path_lookup_key(&entry.path))
            .filter(|paths| paths.len() == 1)
            .and_then(|paths| paths.first())
            .cloned()
            .or_else(|| {
                play_count_metadata_key(&entry.title, &entry.artist, &entry.album)
                    .and_then(|key| paths_by_metadata.get(&key))
                    .filter(|paths| paths.len() == 1)
                    .and_then(|paths| paths.first())
                    .cloned()
            });
        let Some(target_path) = target_path else {
            continue;
        };
        let sql = if overwrite {
            "UPDATE audios SET play_count = ?1 WHERE path = ?2"
        } else {
            "UPDATE audios SET play_count = MAX(play_count, ?1) WHERE path = ?2"
        };
        let affected = tx
            .execute(sql, params![play_count, target_path])
            .map_err(|e| e.to_string())?;
        if affected > 0 {
            imported += 1;
        }
    }
    tx.commit().map_err(|e| e.to_string())?;
    Ok(imported)
}

/// 导出全部播放流水，按路径分组；包含已不在曲库的路径，便于删歌后恢复。
pub fn export_play_history(index_path: String) -> Result<Vec<PlayHistoryEntry>, String> {
    let index_dir = PathBuf::from(index_path);
    let conn = open_connection(&index_dir).map_err(|e| e.to_string())?;
    init_schema(&conn).map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare(
            "SELECT p.path, h.played_at FROM play_history h \
             JOIN listen_paths p ON p.id = h.path_id \
             ORDER BY p.path ASC, h.played_at ASC",
        )
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })
        .map_err(|e| e.to_string())?;
    let mut result: Vec<PlayHistoryEntry> = Vec::new();
    for row in rows {
        let (path, played_at) = row.map_err(|e| e.to_string())?;
        match result.last_mut() {
            Some(last) if last.path == path => last.played_at.push(played_at),
            _ => result.push(PlayHistoryEntry {
                path,
                played_at: vec![played_at],
            }),
        }
    }
    Ok(result)
}

/// 播放流水聚合：趋势按日、收听节律按小时、报告按星期×小时。
/// 日期/小时按本机时区（SQLite localtime）分桶。
pub fn get_play_history_stats(index_path: String) -> Result<PlayHistoryStats, String> {
    let index_dir = PathBuf::from(index_path);
    let conn = open_connection(&index_dir).map_err(|e| e.to_string())?;
    init_schema(&conn).map_err(|e| e.to_string())?;

    let (total, first_at, last_at): (i64, i64, i64) = conn
        .query_row(
            "SELECT COUNT(*), COALESCE(MIN(played_at), 0), COALESCE(MAX(played_at), 0) FROM play_history",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .map_err(|e| e.to_string())?;

    let mut daily = Vec::new();
    if total > 0 {
        let mut stmt = conn
            .prepare(
                "SELECT date(played_at, 'unixepoch', 'localtime') AS d, COUNT(*) AS c \
                 FROM play_history GROUP BY d ORDER BY d ASC",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                Ok(DayCount {
                    day: row.get(0)?,
                    count: row.get(1)?,
                })
            })
            .map_err(|e| e.to_string())?;
        for row in rows {
            daily.push(row.map_err(|e| e.to_string())?);
        }
    }

    let mut hourly = vec![0i64; 24];
    let mut weekday_hourly = vec![0i64; 7 * 24];
    {
        let mut stmt = conn
            .prepare(
                "SELECT CAST(strftime('%w', played_at, 'unixepoch', 'localtime') AS INTEGER) AS w, \
                        CAST(strftime('%H', played_at, 'unixepoch', 'localtime') AS INTEGER) AS h, \
                        COUNT(*) AS c \
                 FROM play_history GROUP BY w, h",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?))
            })
            .map_err(|e| e.to_string())?;
        for row in rows {
            let (w, h, c) = row.map_err(|e| e.to_string())?;
            if (0..7).contains(&w) && (0..24).contains(&h) {
                hourly[h as usize] += c;
                weekday_hourly[(w * 24 + h) as usize] += c;
            }
        }
    }

    Ok(PlayHistoryStats {
        total,
        first_at,
        last_at,
        daily,
        hourly,
        weekday_hourly,
    })
}

/// 导入播放流水。`overwrite` 为 true 时先清空本机流水；
/// merge 模式按 (路径, 时间戳) 去重追加。不校验路径是否在曲库中。
pub fn import_play_history(
    index_path: String,
    entries: Vec<PlayHistoryEntry>,
    overwrite: bool,
) -> Result<u32, String> {
    let index_dir = PathBuf::from(index_path);
    let mut conn = open_connection(&index_dir).map_err(|e| e.to_string())?;
    init_schema(&conn).map_err(|e| e.to_string())?;
    let tx = conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|e| e.to_string())?;
    if overwrite {
        tx.execute("DELETE FROM play_history", [])
            .map_err(|e| e.to_string())?;
    }
    let mut imported = 0u32;
    for entry in entries {
        if entry.path.is_empty() {
            continue;
        }
        tx.execute(
            "INSERT OR IGNORE INTO listen_paths(path) VALUES(?1)",
            params![entry.path],
        )
        .map_err(|e| e.to_string())?;
        let path_id: i64 = tx
            .query_row(
                "SELECT id FROM listen_paths WHERE path = ?1",
                params![entry.path],
                |row| row.get(0),
            )
            .map_err(|e| e.to_string())?;
        for played_at in entry.played_at {
            if played_at <= 0 {
                continue;
            }
            imported += tx
                .execute(
                    "INSERT OR IGNORE INTO play_history(path_id, played_at) VALUES(?1, ?2)",
                    params![path_id, played_at],
                )
                .map_err(|e| e.to_string())? as u32;
        }
    }
    tx.commit().map_err(|e| e.to_string())?;
    Ok(imported)
}
