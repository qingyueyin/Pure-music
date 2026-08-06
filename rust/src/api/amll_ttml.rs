use serde::{Deserialize, Deserializer};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

// ──────────────────────────────────────────────
// 镜像源配置
// ──────────────────────────────────────────────

static GITHUB_INDEX_URL: &str =
    "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/metadata/raw-lyrics-index.jsonl";
static GITHUB_RAW_BASE: &str =
    "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/raw-lyrics";
static BIKONOO_INDEX_URL: &str = "https://amlldb.bikonoo.com/metadata/raw-lyrics-index.jsonl";
static BIKONOO_RAW_BASE: &str = "https://amlldb.bikonoo.com/raw-lyrics";
const INDEX_CACHE_MAX_AGE: Duration = Duration::from_secs(24 * 60 * 60);
const INDEX_CACHE_FILE: &str = "amll/raw-lyrics-index.jsonl";

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

struct CachedIndex {
    path: PathBuf,
    entries: Arc<Vec<IndexEntry>>,
}

fn cache() -> &'static Mutex<Option<CachedIndex>> {
    static CACHE: std::sync::OnceLock<Mutex<Option<CachedIndex>>> = std::sync::OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

// ──────────────────────────────────────────────
// 搜索算法
// ──────────────────────────────────────────────

fn normalize_search_text(value: &str) -> String {
    let mut normalized = String::new();
    for ch in value.chars() {
        if ch == '.' {
            continue;
        }
        if ch.is_alphanumeric() {
            normalized.extend(ch.to_lowercase());
        } else if !normalized.ends_with(' ') {
            normalized.push(' ');
        }
    }
    normalized.trim().to_string()
}

fn search_terms(keyword: &str) -> Vec<String> {
    normalize_search_text(keyword)
        .split_whitespace()
        .map(str::to_string)
        .filter(|term| !term.is_empty())
        .collect()
}

fn is_common_english_term(term: &str) -> bool {
    matches!(
        term,
        "a" | "an"
            | "and"
            | "are"
            | "as"
            | "at"
            | "be"
            | "by"
            | "for"
            | "from"
            | "in"
            | "is"
            | "it"
            | "of"
            | "on"
            | "or"
            | "the"
            | "to"
            | "with"
    )
}

fn field_match_score(field: &str, term: &str, is_title: bool) -> i32 {
    if field.is_empty() {
        return 0;
    }
    if field == term {
        return if is_title { 300 } else { 100 };
    }

    let tokens: Vec<_> = field.split_whitespace().collect();
    if tokens.iter().any(|token| *token == term) {
        return if is_title { 100 } else { 80 };
    }

    let is_short_ascii_term = term.is_ascii() && term.len() < 3;
    if !is_short_ascii_term && field.contains(term) {
        return if is_title { 60 } else { 40 };
    }
    0
}

fn score_entry(entry: &IndexEntry, terms: &[String]) -> i32 {
    let normalized_titles: Vec<_> = entry
        .metadata
        .titles
        .iter()
        .map(|title| normalize_search_text(title))
        .collect();
    let normalized_artists: Vec<_> = entry
        .metadata
        .artists
        .iter()
        .map(|artist| normalize_search_text(artist))
        .collect();

    let mut active_terms: Vec<&String> = terms
        .iter()
        .filter(|term| !is_common_english_term(term))
        .collect();
    if active_terms.is_empty() {
        active_terms = terms.iter().collect();
    }

    let mut score = 0;
    for term in active_terms {
        let title_score = normalized_titles
            .iter()
            .map(|title| field_match_score(title, term, true))
            .max()
            .unwrap_or(0);
        let artist_score = normalized_artists
            .iter()
            .map(|artist| field_match_score(artist, term, false))
            .max()
            .unwrap_or(0);
        if title_score == 0 && artist_score == 0 {
            return 0;
        }
        score += title_score + artist_score;
    }

    let normalized_query = normalize_search_text(&terms.join(" "));
    if normalized_titles
        .iter()
        .any(|title| title == &normalized_query)
    {
        score += 300;
    }
    if normalized_artists
        .iter()
        .any(|artist| artist == &normalized_query)
    {
        score += 400;
    }
    score
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

fn parse_index(text: &str) -> Result<Vec<IndexEntry>, String> {
    let mut entries = Vec::new();
    let mut invalid_lines = 0;
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
            Err(_) => invalid_lines += 1,
        }
    }
    if entries.is_empty() {
        Err(format!(
            "AMLL index contains no valid entries ({invalid_lines} invalid lines)"
        ))
    } else {
        Ok(entries)
    }
}

fn write_index_cache(path: &Path, text: &str) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "AMLL cache path has no parent".to_string())?;
    std::fs::create_dir_all(parent).map_err(|e| format!("create AMLL cache dir: {e}"))?;
    std::fs::write(path, text).map_err(|e| format!("write AMLL index cache: {e}"))
}

fn resolve_index<F>(cache_file: &Path, refresh: bool, fetch: F) -> Result<Vec<IndexEntry>, String>
where
    F: FnOnce() -> Result<String, String>,
{
    let cached = std::fs::read_to_string(cache_file)
        .ok()
        .and_then(|text| parse_index(&text).ok());
    if !refresh {
        if let Some(entries) = cached {
            return Ok(entries);
        }
    }

    match fetch().and_then(|text| parse_index(&text).map(|entries| (entries, text))) {
        Ok((entries, text)) => {
            let _ = write_index_cache(cache_file, &text);
            Ok(entries)
        }
        Err(_) if cached.is_some() => Ok(cached.unwrap()),
        Err(error) => Err(error),
    }
}

fn should_refresh_index(path: &Path) -> bool {
    let Ok(modified) = std::fs::metadata(path).and_then(|metadata| metadata.modified()) else {
        return true;
    };
    SystemTime::now()
        .duration_since(modified)
        .map(|age| age > INDEX_CACHE_MAX_AGE)
        .unwrap_or(false)
}

fn download_index_text() -> Result<String, String> {
    let mut errors = Vec::new();
    for url in [BIKONOO_INDEX_URL, GITHUB_INDEX_URL] {
        match http_get(url, 20) {
            Ok(text) => return Ok(text),
            Err(error) => errors.push(error),
        }
    }
    Err(format!("AMLL index download failed: {}", errors.join("; ")))
}

pub fn amll_search_lyrics(
    keyword: &str,
    page: u32,
    page_size: u32,
    cache_dir: &str,
) -> Result<Vec<AmllSearchItem>, String> {
    let terms = search_terms(keyword);
    if terms.is_empty() {
        return Ok(vec![]);
    }

    let cache_file = Path::new(cache_dir).join(INDEX_CACHE_FILE);
    let mut cache_guard = cache()
        .lock()
        .map_err(|_| "AMLL index cache lock poisoned".to_string())?;
    let entries = match cache_guard.as_ref() {
        Some(cached) if cached.path == cache_file => Arc::clone(&cached.entries),
        None => {
            let loaded = resolve_index(
                &cache_file,
                should_refresh_index(&cache_file),
                download_index_text,
            )?;
            let entries = Arc::new(loaded);
            *cache_guard = Some(CachedIndex {
                path: cache_file,
                entries: Arc::clone(&entries),
            });
            entries
        }
        Some(_) => {
            let loaded = resolve_index(
                &cache_file,
                should_refresh_index(&cache_file),
                download_index_text,
            )?;
            let entries = Arc::new(loaded);
            *cache_guard = Some(CachedIndex {
                path: cache_file,
                entries: Arc::clone(&entries),
            });
            entries
        }
    };
    drop(cache_guard);

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
    Ok(scored
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
        .collect())
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
    let url = format!("{BIKONOO_RAW_BASE}/{id}");
    http_get(&url, 30)
        .or_else(|_| {
            let url2 = format!("{GITHUB_RAW_BASE}/{id}");
            http_get(&url2, 30)
        })
        .ok()
}

pub fn amll_clear_cache() {
    let mut cache_guard = cache().lock().unwrap();
    *cache_guard = None;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_cache_file(name: &str) -> std::path::PathBuf {
        let base = std::env::temp_dir().join(format!(
            "pure_music_amll_test_{}_{}_{}",
            name,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        base.join("raw-lyrics-index.jsonl")
    }

    fn sample_index(title: &str, file: &str) -> String {
        format!(
            r#"{{"metadata":[["musicName",["{title}"]],["artists",["Artist"]],["album",["Album"]]],"rawLyricFile":"{file}"}}"#
        )
    }

    fn test_entry(title: &str, artist: &str) -> IndexEntry {
        serde_json::from_value(serde_json::json!({
            "metadata": [
                ["musicName", [title]],
                ["artists", [artist]],
                ["album", ["Album"]]
            ],
            "rawLyricFile": "test.ttml"
        }))
        .unwrap()
    }

    #[test]
    fn ranks_title_coverage_above_common_word_matches() {
        let terms = search_terms("Proud of Us (English Version) R.E.D");
        let accurate = test_entry("Proud of Us (English Version)", "R.E.D");
        let unrelated = test_entry("The Song of You and Me (Bubbles Solo)", "HoYoFair");

        assert!(score_entry(&accurate, &terms) > score_entry(&unrelated, &terms));
        assert_eq!(score_entry(&unrelated, &terms), 0);
    }

    #[test]
    fn keeps_exact_single_term_title_match_strong() {
        let terms = search_terms("不该");
        let entry = test_entry("不该", "周杰伦");

        assert!(score_entry(&entry, &terms) >= 300);
    }

    #[test]
    fn rejects_partial_multi_term_matches() {
        let terms = search_terms("Shawn Mendes");
        let matching = test_entry("Señorita", "Shawn Mendes, Camila Cabello");
        let partial = test_entry("Reminding Me", "Shawn Hook, Vanessa Hudgens");

        assert!(score_entry(&matching, &terms) > 0);
        assert_eq!(score_entry(&partial, &terms), 0);
    }

    #[test]
    fn uses_fresh_disk_cache_without_downloading() {
        let cache_file = temp_cache_file("fresh");
        std::fs::create_dir_all(cache_file.parent().unwrap()).unwrap();
        std::fs::write(&cache_file, sample_index("Cached", "cached.ttml")).unwrap();

        let entries = resolve_index(&cache_file, false, || {
            panic!("fresh cache must not trigger a download")
        })
        .unwrap();

        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].metadata.titles, ["Cached"]);
        std::fs::remove_dir_all(cache_file.parent().unwrap()).unwrap();
    }

    #[test]
    fn keeps_stale_disk_cache_when_refresh_fails() {
        let cache_file = temp_cache_file("stale");
        std::fs::create_dir_all(cache_file.parent().unwrap()).unwrap();
        std::fs::write(&cache_file, sample_index("Cached", "cached.ttml")).unwrap();

        let entries = resolve_index(&cache_file, true, || Err("offline".to_string())).unwrap();

        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].metadata.titles, ["Cached"]);
        assert_eq!(
            std::fs::read_to_string(&cache_file).unwrap(),
            sample_index("Cached", "cached.ttml")
        );
        std::fs::remove_dir_all(cache_file.parent().unwrap()).unwrap();
    }

    #[test]
    fn persists_first_successful_download() {
        let cache_file = temp_cache_file("download");
        let downloaded = sample_index("Downloaded", "downloaded.ttml");

        let entries = resolve_index(&cache_file, true, || Ok(downloaded.clone())).unwrap();

        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].metadata.titles, ["Downloaded"]);
        assert_eq!(std::fs::read_to_string(&cache_file).unwrap(), downloaded);
        std::fs::remove_dir_all(cache_file.parent().unwrap()).unwrap();
    }

    #[test]
    fn test_search_and_download() {
        let cache_file = temp_cache_file("network");
        let results =
            amll_search_lyrics("不该", 1, 5, cache_file.parent().unwrap().to_str().unwrap())
                .unwrap();
        assert!(!results.is_empty(), "搜索'不该'应返回结果");
        let best = &results[0];
        assert_eq!(best.title, "不该");
        assert!(best.artist.contains("周杰伦"));
        assert!(best.score >= 300.0);

        let ttml = amll_get_ttml(&best.id);
        assert!(ttml.is_some(), "应能下载TTML: {}", best.id);
        assert!(ttml.unwrap().starts_with("<tt"));
        std::fs::remove_dir_all(cache_file.parent().unwrap()).unwrap();
    }
}
