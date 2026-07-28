use serde::{Deserialize, Deserializer};
use std::sync::Mutex;

// ──────────────────────────────────────────────
// 镜像源配置
// ──────────────────────────────────────────────

static GITHUB_INDEX_URL: &str =
    "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/metadata/raw-lyrics-index.jsonl";
static GITHUB_RAW_BASE: &str =
    "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/raw-lyrics";
static BIKONOO_INDEX_URL: &str =
    "https://amlldb.bikonoo.com/metadata/raw-lyrics-index.jsonl";
static BIKONOO_RAW_BASE: &str =
    "https://amlldb.bikonoo.com/raw-lyrics";

// ──────────────────────────────────────────────
// 索引解析（与 Unilyric 一致的结构化解析）
// ──────────────────────────────────────────────

#[derive(Debug, Clone)]
struct Metadata {
    titles: Vec<String>,
    artists: Vec<String>,
    albums: Vec<String>,
}

fn deserialize_metadata<'de, D>(deserializer: D) -> Result<Metadata, D::Error>
where
    D: Deserializer<'de>,
{
    let raw: Vec<(String, Vec<String>)> = Deserialize::deserialize(deserializer)?;
    let mut meta = Metadata {
        titles: Vec::new(),
        artists: Vec::new(),
        albums: Vec::new(),
    };
    for (key, val) in raw {
        match key.as_str() {
            "musicName" => meta.titles = val,
            "artists" => meta.artists = val,
            "album" => meta.albums = val,
            _ => {}
        }
    }
    Ok(meta)
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IndexEntry {
    #[serde(deserialize_with = "deserialize_metadata")]
    metadata: Metadata,
    raw_lyric_file: String,
}

// ──────────────────────────────────────────────
// 内存缓存
// ──────────────────────────────────────────────

fn cache() -> &'static Mutex<Option<Vec<IndexEntry>>> {
    static CACHE: std::sync::OnceLock<Mutex<Option<Vec<IndexEntry>>>> =
        std::sync::OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

// ──────────────────────────────────────────────
// 搜索算法
// ──────────────────────────────────────────────

fn score_entry(entry: &IndexEntry, terms: &[String]) -> i32 {
    let mut s = 0;
    for t in terms {
        for title in &entry.metadata.titles {
            let low = title.to_lowercase();
            if low == *t {
                s += 300;
            } else if low.starts_with(t) || low.ends_with(t) {
                s += 200;
            } else if low.contains(t) {
                s += 100;
            }
        }
        for artist in &entry.metadata.artists {
            let low = artist.to_lowercase();
            if low.contains(t) {
                s += 50;
            }
        }
    }
    s
}

// ──────────────────────────────────────────────
// FRB 导出
// ──────────────────────────────────────────────

#[derive(Clone)]
pub struct AmllSearchItem {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub score: f64,
}

fn download_index(url: &str) -> Result<Vec<IndexEntry>, String> {
    let text = http_get(url, 120)?;
    let mut entries = Vec::new();
    for line in text.lines() {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<IndexEntry>(line) {
            Ok(entry) => {
                if !entry.metadata.titles.is_empty() && !entry.raw_lyric_file.is_empty() {
                    entries.push(entry);
                }
            }
            Err(_) => {}
        }
    }
    Ok(entries)
}

pub fn amll_search_lyrics(
    keyword: &str,
    page: u32,
    page_size: u32,
) -> Vec<AmllSearchItem> {
    let terms: Vec<String> = keyword
        .to_lowercase()
        .split_whitespace()
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty())
        .collect();
    if terms.is_empty() {
        return vec![];
    }

    let cache_guard = cache().lock().unwrap();
    let entries = match cache_guard.as_ref() {
        Some(e) => e.clone(),
        None => {
            drop(cache_guard);
            let downloaded = download_index(GITHUB_INDEX_URL)
                .or_else(|_| download_index(BIKONOO_INDEX_URL))
                .unwrap_or_default();
            let mut cache_guard = cache().lock().unwrap();
            *cache_guard = Some(downloaded.clone());
            downloaded
        }
    };

    let mut scored: Vec<_> = entries
        .iter()
        .map(|e| {
            let score = score_entry(e, &terms);
            (e, score)
        })
        .filter(|(_, s)| *s >= 50)
        .collect();

    scored.sort_by(|a, b| b.1.cmp(&a.1));

    let start = ((page.max(1) - 1) * page_size) as usize;
    scored
        .into_iter()
        .skip(start)
        .take(page_size as usize)
        .map(|(e, s)| {
            let title = e.metadata.titles.first().cloned().unwrap_or_default();
            let artist = e.metadata.artists.join(", ");
            let album = e.metadata.albums.first().cloned().unwrap_or_default();
            AmllSearchItem {
                id: e.raw_lyric_file.clone(),
                title,
                artist,
                album,
                score: s as f64,
            }
        })
        .collect()
}

fn http_get(url: &str, timeout_secs: u64) -> Result<String, String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(timeout_secs))
        .connect_timeout(std::time::Duration::from_secs(15))
        .build()
        .map_err(|e| format!("client: {e}"))?;
    let resp = client.get(url).send().map_err(|e| format!("HTTP: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("status {}", resp.status()));
    }
    resp.text().map_err(|e| format!("body: {e}"))
}

pub fn amll_get_ttml(id: &str) -> Option<String> {
    let url = format!("{GITHUB_RAW_BASE}/{id}");
    http_get(&url, 30).or_else(|_| {
        let url2 = format!("{BIKONOO_RAW_BASE}/{id}");
        http_get(&url2, 30)
    }).ok()
}

pub fn amll_clear_cache() {
    let mut cache_guard = cache().lock().unwrap();
    *cache_guard = None;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_search_and_download() {
        let results = amll_search_lyrics("不该", 1, 5);
        assert!(!results.is_empty(), "搜索'不该'应返回结果");
        let best = &results[0];
        assert_eq!(best.title, "不该");
        assert!(best.artist.contains("周杰伦"));
        assert!(best.score >= 300.0);

        let ttml = amll_get_ttml(&best.id);
        assert!(ttml.is_some(), "应能下载TTML: {}", best.id);
        assert!(ttml.unwrap().starts_with("<tt"));
    }
}
