use aes::cipher::{BlockDecrypt, BlockEncrypt, KeyInit};
use aes::Aes128;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use md5::{Digest, Md5};
use rand::prelude::IndexedRandom;
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

macro_rules! ne_log {
    ("E", $($arg:tt)*) => {
        log::error!(target: "ne", $($arg)*);
    };
    ("W", $($arg:tt)*) => {
        log::warn!(target: "ne", $($arg)*);
    };
    ("I", $($arg:tt)*) => {
        log::info!(target: "ne", $($arg)*);
    };
    ("D", $($arg:tt)*) => {
        log::debug!(target: "ne", $($arg)*);
    };
}

const EAPI_KEY: &[u8; 16] = b"e82ckenh8dichen8";
const CACHE_KEY: &[u8; 16] = b")(13daqP@ssw0rd~";
const DEVICE_ID_XOR_KEY: &str = "3go8&$8*3*3h0k(2)2";

fn pkcs7_pad(data: &[u8], block_size: usize) -> Vec<u8> {
    let pad_len = block_size - (data.len() % block_size);
    let mut result = data.to_vec();
    result.extend(vec![pad_len as u8; pad_len]);
    result
}

fn aes_encrypt(data: &[u8], key: &[u8; 16]) -> Vec<u8> {
    let padded = pkcs7_pad(data, 16);
    let cipher = Aes128::new(key.into());
    let mut result = Vec::new();
    for chunk in padded.chunks(16) {
        let mut block = [0u8; 16];
        block.copy_from_slice(chunk);
        let mut arr = aes::cipher::generic_array::GenericArray::from(block);
        cipher.encrypt_block(&mut arr);
        result.extend_from_slice(&arr);
    }
    result
}

fn aes_decrypt(data: &[u8], key: &[u8; 16]) -> Result<Vec<u8>, String> {
    if data.is_empty() {
        return Err("empty decryption data".to_string());
    }
    if !data.len().is_multiple_of(16) {
        return Err(format!(
            "invalid encrypted data length: {} (not a multiple of 16)",
            data.len()
        ));
    }
    let cipher = Aes128::new(key.into());
    let mut result = Vec::new();
    for chunk in data.chunks(16) {
        let mut block = [0u8; 16];
        block.copy_from_slice(chunk);
        let mut arr = aes::cipher::generic_array::GenericArray::from(block);
        cipher.decrypt_block(&mut arr);
        result.extend_from_slice(&arr);
    }
    let pad_len = result[result.len() - 1] as usize;
    if pad_len > 0 && pad_len <= 16 {
        result.truncate(result.len() - pad_len);
    }
    Ok(result)
}

/// MD5 digest format: "nobody{url}use{params}md5forencrypt"
fn eapi_md5(url: &str, params: &str) -> String {
    let message = format!("nobody{}use{}md5forencrypt", url, params);
    let mut hasher = Md5::new();
    hasher.update(message.as_bytes());
    format!("{:x}", hasher.finalize())
}

/// Encrypt params
/// Returns "params=UPPERCASE_HEX_STRING" format
fn eapi_params_encrypt(encrypt_path: &str, params: &str) -> String {
    let digest = eapi_md5(encrypt_path, params);
    let data = format!(
        "{}-36cd479b6b5-{}-36cd479b6b5-{}",
        encrypt_path, params, digest
    );
    let encrypted = aes_encrypt(data.as_bytes(), EAPI_KEY);
    let hex_str: String = encrypted.iter().map(|b| format!("{:02X}", b)).collect();
    format!("params={}", hex_str)
}

fn eapi_response_decrypt(data: &[u8]) -> Result<Vec<u8>, String> {
    aes_decrypt(data, EAPI_KEY)
}

fn get_cache_key(data: &str) -> String {
    let encrypted = aes_encrypt(data.as_bytes(), CACHE_KEY);
    BASE64.encode(encrypted)
}

fn get_anonymous_username(device_id: &str) -> String {
    let mut xored: Vec<char> = Vec::new();
    for (i, c) in device_id.chars().enumerate() {
        let key_char = DEVICE_ID_XOR_KEY
            .chars()
            .nth(i % DEVICE_ID_XOR_KEY.len())
            .unwrap_or(' ');
        xored.push((c as u8 ^ key_char as u8) as char);
    }
    let xored_str: String = xored.iter().collect();
    let mut hasher = Md5::new();
    hasher.update(xored_str.as_bytes());
    let digest = hasher.finalize();
    let combined = format!("{} {}", device_id, BASE64.encode(digest));
    BASE64.encode(combined.as_bytes())
}

fn generate_device_id() -> String {
    let mut rng = rand::rng();
    let mac: String = (0..6)
        .map(|_| format!("{:02X}", rng.random::<u8>()))
        .collect::<Vec<_>>()
        .join(":");
    let random_str: String = (0..8)
        .map(|_| {
            let idx = rng.random_range(0..26);
            (b'A' + idx) as char
        })
        .collect();
    let hash_part = hex::encode(rng.random::<[u8; 32]>());
    format!("{}@@@{}@@@@@@{}", mac, random_str, hash_part)
}

fn get_current_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis() as u64
}

fn json_plain(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Number(n) => n.to_string(),
        _ => String::new(),
    }
}

fn nested_lyric_text(root: &serde_json::Value, key: &str) -> Option<String> {
    let text = json_plain(&root[key]["lyric"]);
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

fn compact_lyric_json(root: &serde_json::Value) -> Result<String, String> {
    let code = root["code"].as_i64().unwrap_or(-1);
    if code != 200 {
        return Err(format!("Get lyric failed with code: {code}"));
    }
    let yrc = nested_lyric_text(root, "yrc");
    let main = yrc
        .clone()
        .or_else(|| nested_lyric_text(root, "lrc"))
        .ok_or_else(|| "empty lyric".to_string())?;
    let has_yrc = yrc.is_some();
    let trans = if has_yrc {
        nested_lyric_text(root, "ytlrc").or_else(|| nested_lyric_text(root, "tlyric"))
    } else {
        nested_lyric_text(root, "tlyric")
    };
    let roma = if has_yrc {
        nested_lyric_text(root, "yromalrc").or_else(|| nested_lyric_text(root, "romalrc"))
    } else {
        nested_lyric_text(root, "romalrc")
    };
    serde_json::to_string(&serde_json::json!({
        "main": main,
        "trans": trans,
        "roma": roma,
        "format": if has_yrc { "yrc" } else { "lrc" },
    }))
    .map_err(|e| e.to_string())
}

fn https_pic_url(raw: &str) -> String {
    if raw.starts_with("http:") {
        raw.replacen("http:", "https:", 1)
    } else {
        raw.to_string()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudMusicResult {
    pub code: i32,
    #[serde(flatten)]
    pub extra: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LyricResult {
    pub code: i32,
    pub lrc: Option<LyricContent>,
    pub tlyric: Option<LyricContent>,
    pub yrc: Option<LyricContent>,
    pub romalrc: Option<LyricContent>,
    #[serde(rename = "lyricUser")]
    pub lyric_user: Option<LyricUser>,
    #[serde(rename = "transUser")]
    pub trans_user: Option<LyricUser>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LyricContent {
    pub version: i32,
    pub lyric: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LyricUser {
    pub nickname: String,
}

pub struct NetEaseCloud {
    client: Mutex<Option<reqwest::blocking::Client>>,
    cookies: Mutex<HashMap<String, String>>,
    user_id: Mutex<Option<i64>>,
    expire: Mutex<u64>,
    init_mutex: Mutex<()>,
}

impl NetEaseCloud {
    pub fn new() -> Self {
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(20))
            .connect_timeout(Duration::from_secs(10))
            .build()
            .ok();
        NetEaseCloud {
            client: Mutex::new(client),
            cookies: Mutex::new(HashMap::new()),
            user_id: Mutex::new(None),
            expire: Mutex::new(0),
            init_mutex: Mutex::new(()),
        }
    }

    fn client(&self) -> Result<reqwest::blocking::Client, String> {
        self.client
            .lock()
            .map_err(|e| e.to_string())?
            .clone()
            .ok_or_else(|| "HTTP client init failed".to_string())
    }

    /// Headers: User-Agent, Referer, Cookie (only 3)
    fn get_request_header(&self) -> Result<Vec<(String, String)>, String> {
        let cookies = self.cookies.lock().map_err(|e| e.to_string())?;
        let mut headers = vec![
            ("User-Agent".to_string(), "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.3.203419".to_string()),
            ("Referer".to_string(), "https://music.163.com/".to_string()),
        ];
        let cookie_str: String = cookies
            .iter()
            .map(|(k, v)| format!("{}={}", k, v))
            .collect::<Vec<_>>()
            .join("; ");
        if !cookie_str.is_empty() {
            headers.push(("Cookie".to_string(), cookie_str));
        }
        Ok(headers)
    }

    pub fn init(&self) -> Result<(), String> {
        let _init_lock = self.init_mutex.lock().map_err(|e| e.to_string())?;

        let now = get_current_timestamp();
        let expire = self.expire.lock().map_err(|e| e.to_string())?;
        if *expire > now {
            ne_log!("D", "init: session still valid, expire={}", *expire);
            return Ok(());
        }
        drop(expire);

        ne_log!("I", "init: starting anonymous login");

        let device_id = generate_device_id();
        let username = get_anonymous_username(&device_id);
        let osver = format!(
            "Microsoft-Windows-10--build-{}00-64bit",
            rand::rng().random_range(200..300)
        );

        let modes = [
            "MS-iCraft B760M WIFI",
            "ASUS ROG STRIX Z790",
            "MSI MAG B550 TOMAHAWK",
            "ASRock X670E Taichi",
        ];
        let mode = modes
            .choose(&mut rand::rng())
            .unwrap_or(&"MS-iCraft B760M WIFI");

        let client_sign = generate_device_id();

        let pre_cookies: HashMap<String, String> = [
            ("os".to_string(), "pc".to_string()),
            ("deviceId".to_string(), device_id.clone()),
            ("osver".to_string(), osver.clone()),
            ("clientSign".to_string(), client_sign.clone()),
            ("channel".to_string(), "netease".to_string()),
            ("mode".to_string(), mode.to_string()),
            ("appver".to_string(), "3.1.3.203419".to_string()),
        ]
        .iter()
        .cloned()
        .collect();

        let params = serde_json::json!({
            "username": username,
        });

        let params_str = params.to_string();
        // path.replace("/eapi/", "/api/") => /eapi/register/anonimous -> /api/register/anonimous
        let encrypt_path = "/api/register/anonimous";
        // body is "params=HEXSTRING" with Content-Type already set by eapi_params_encrypt
        let body = eapi_params_encrypt(encrypt_path, &params_str);

        let url = "https://interface.music.163.com/eapi/register/anonimous";
        ne_log!("D", "init: POST {}", url);
        let headers = self.get_request_header()?;

        let client = self.client()?;
        let mut request = client.post(url);
        for (k, v) in headers {
            request = request.header(&k, &v);
        }
        request = request.body(body);

        let response = request.send().map_err(|e| {
            ne_log!("E", "init: request failed: {}", e);
            e.to_string()
        })?;

        let status = response.status();
        ne_log!("D", "init: status={}", status);

        let cookie_headers: Vec<String> = response
            .headers()
            .get_all("set-cookie")
            .iter()
            .filter_map(|value| value.to_str().ok().map(str::to_string))
            .collect();

        let response_bytes = response.bytes().map_err(|e| {
            ne_log!("E", "init: failed to read response body: {}", e);
            e.to_string()
        })?;
        ne_log!(
            "D",
            "init: response body size={} bytes",
            response_bytes.len()
        );

        let data = eapi_response_decrypt(response_bytes.as_ref()).map_err(|e| {
            ne_log!("E", "init: decrypt failed: {}", e);
            format!("decrypt failed: {}", e)
        })?;

        let json_str = String::from_utf8(data).map_err(|e| {
            ne_log!("E", "init: UTF8 decode failed: {}", e);
            e.to_string()
        })?;

        let json: serde_json::Value = serde_json::from_str(&json_str).map_err(|e| {
            ne_log!("E", "init: JSON parse failed: {}", e);
            e.to_string()
        })?;

        if json["code"].as_i64().unwrap_or(-1) != 200 {
            ne_log!(
                "E",
                "init: login failed, code={}",
                json["code"].as_i64().unwrap_or(-1)
            );
            return Err(format!(
                "Anon login failed: code={}",
                json["code"].as_i64().unwrap_or(-1)
            ));
        }

        ne_log!(
            "I",
            "init: login successful, userId={}",
            json["userId"].as_i64().unwrap_or(0)
        );

        let mut cookies = self.cookies.lock().map_err(|e| e.to_string())?;
        for (k, v) in &pre_cookies {
            cookies.insert(k.clone(), v.clone());
        }
        drop(cookies);

        for cookies_header in &cookie_headers {
            if let Some(cookie_pair) = cookies_header.split(';').next() {
                if let Some(eq_pos) = cookie_pair.find('=') {
                    let name = cookie_pair[..eq_pos].trim().to_string();
                    let value = cookie_pair[eq_pos + 1..].trim().to_string();
                    match name.as_str() {
                        "NMTID" | "MUSIC_A" | "__csrf" => {
                            let mut cookies = self.cookies.lock().map_err(|e| e.to_string())?;
                            cookies.insert(name, value);
                        }
                        _ => {}
                    }
                }
            }
        }

        let user_id = json["userId"].as_i64().unwrap_or(0);
        let new_expire = get_current_timestamp() + 86_400_000;

        *self.user_id.lock().map_err(|e| e.to_string())? = Some(user_id);
        *self.expire.lock().map_err(|e| e.to_string())? = new_expire;

        Ok(())
    }

    fn fetch_lyric_json(&self, song_id: i64) -> Result<serde_json::Value, String> {
        self.init()?;
        ne_log!("D", "get_lyric: song_id={}", song_id);

        let params = serde_json::json!({
            "id": song_id,
            "lv": "-1",
            "tv": "-1",
            "rv": "-1",
            "yv": "-1",
        });

        let params_str = params.to_string();
        let encrypt_path = "/api/song/lyric/v1";
        let body = eapi_params_encrypt(encrypt_path, &params_str);

        let url = "https://interface.music.163.com/eapi/song/lyric/v1";
        ne_log!("D", "get_lyric: POST {}", url);
        let headers = self.get_request_header()?;

        let client = self.client()?;
        let mut request = client.post(url);
        for (k, v) in headers {
            request = request.header(&k, &v);
        }
        request = request
            .query(&[(
                "cache_key",
                get_cache_key(&format!("e_r=true&id={}", song_id)),
            )])
            .body(body);

        let response = request.send().map_err(|e| {
            ne_log!("E", "get_lyric: request failed: {}", e);
            e.to_string()
        })?;

        let status = response.status();
        ne_log!("D", "get_lyric: status={}", status);

        let response_bytes = response.bytes().map_err(|e| {
            ne_log!("E", "get_lyric: failed to read response body: {}", e);
            e.to_string()
        })?;
        ne_log!(
            "D",
            "get_lyric: response body size={} bytes",
            response_bytes.len()
        );

        let data = eapi_response_decrypt(response_bytes.as_ref()).map_err(|e| {
            ne_log!("E", "get_lyric: decrypt failed: {}", e);
            format!("decrypt failed: {}", e)
        })?;

        let json_str = String::from_utf8(data).map_err(|e| {
            ne_log!("E", "get_lyric: UTF8 decode failed: {}", e);
            e.to_string()
        })?;

        serde_json::from_str(&json_str).map_err(|e| {
            ne_log!("E", "get_lyric: JSON parse failed: {}", e);
            e.to_string()
        })
    }

    pub fn get_lyric(&self, song_id: i64) -> Result<LyricResult, String> {
        let json = self.fetch_lyric_json(song_id)?;
        let result: LyricResult = serde_json::from_value(json).map_err(|e| {
            ne_log!("E", "get_lyric: JSON parse failed: {}", e);
            e.to_string()
        })?;

        if result.code != 200 {
            ne_log!("W", "get_lyric: API returned code={}", result.code);
            return Err(format!("Get lyric failed with code: {}", result.code));
        }

        ne_log!(
            "I",
            "get_lyric: success, lrc={}, yrc={}, tlyric={}",
            result.lrc.as_ref().map(|l| l.lyric.len()).unwrap_or(0),
            result.yrc.as_ref().map(|l| l.lyric.len()).unwrap_or(0),
            result.tlyric.as_ref().map(|l| l.lyric.len()).unwrap_or(0)
        );

        Ok(result)
    }

    /// Search NeSource
    pub fn search(
        &self,
        keyword: String,
        limit: i32,
    ) -> Result<Vec<HashMap<String, String>>, String> {
        self.init()?;
        ne_log!("I", "search: starting request, limit={}", limit);

        let params = serde_json::json!({
            "limit": limit.to_string(),
            "offset": "0",
            "keyword": keyword,
            "scene": "NORMAL",
            "needCorrect": "true",
        });

        let params_str = params.to_string();
        // /eapi/search/song/list/page -> /api/search/song/list/page
        let encrypt_path = "/api/search/song/list/page";
        let body = eapi_params_encrypt(encrypt_path, &params_str);

        let url = "https://interface.music.163.com/eapi/search/song/list/page";
        ne_log!("D", "search: POST {}", url);
        let headers = self.get_request_header()?;

        let client = self.client()?;
        let mut request = client.post(url);
        for (k, v) in headers {
            request = request.header(&k, &v);
        }
        request = request.body(body);

        let response = request.send().map_err(|e| {
            ne_log!("E", "search: request failed: {}", e);
            e.to_string()
        })?;

        let status = response.status();
        ne_log!("D", "search: status={}", status);

        let response_bytes = response.bytes().map_err(|e| {
            ne_log!("E", "search: failed to read response body: {}", e);
            e.to_string()
        })?;

        ne_log!(
            "D",
            "search: response body size={} bytes",
            response_bytes.len()
        );

        if response_bytes.is_empty() {
            ne_log!("E", "search: empty response from NetEase");
            return Err("empty response from NetEase".to_string());
        }

        let data = eapi_response_decrypt(response_bytes.as_ref()).map_err(|e| {
            ne_log!("E", "search: decrypt failed: {}", e);
            format!("decrypt failed: {}", e)
        })?;

        let json_str = String::from_utf8(data).map_err(|e| {
            ne_log!("E", "search: UTF8 decode failed: {}", e);
            e.to_string()
        })?;

        let json: serde_json::Value = serde_json::from_str(&json_str).map_err(|e| {
            ne_log!("E", "search: JSON parse failed: {}", e);
            e.to_string()
        })?;

        let code = json["code"].as_i64().unwrap_or(-1);
        ne_log!("D", "search: response code={}", code);
        if code != 200 {
            ne_log!("W", "search: API returned code={}", code);
            return Err(format!("Search failed with code: {}", code));
        }

        let mut results = Vec::new();
        if let Some(resources) = json["data"]["resources"].as_array() {
            ne_log!("D", "search: found {} resources", resources.len());
            for resource in resources.iter() {
                if let Some(song) = resource["baseInfo"]["simpleSongData"].as_object() {
                    let id = song.get("id").map(json_plain).unwrap_or_default();
                    if id.is_empty() || id == "0" {
                        continue;
                    }
                    let mut map = HashMap::new();
                    map.insert("id".to_string(), id);
                    map.insert(
                        "name".to_string(),
                        song.get("name")
                            .and_then(|v| v.as_str())
                            .unwrap_or("UNKNOWN")
                            .to_string(),
                    );
                    let artists_str = song
                        .get("ar")
                        .and_then(|v| v.as_array())
                        .map(|artists| {
                            artists
                                .iter()
                                .filter_map(|a| a["name"].as_str().map(String::from))
                                .filter(|name| !name.is_empty())
                                .collect::<Vec<_>>()
                                .join("、")
                        })
                        .filter(|s| !s.is_empty())
                        .unwrap_or_else(|| "UNKNOWN".to_string());
                    map.insert("artist".to_string(), artists_str.clone());
                    map.insert("artists".to_string(), artists_str);
                    let album = song
                        .get("al")
                        .and_then(|v| v.as_object())
                        .and_then(|album| album.get("name"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    map.insert("album".to_string(), album);
                    map.insert(
                        "dt".to_string(),
                        song.get("dt").map(json_plain).unwrap_or_default(),
                    );
                    let pic = song
                        .get("al")
                        .and_then(|v| v.as_object())
                        .and_then(|album| album.get("picUrl"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    map.insert("picUrl".to_string(), https_pic_url(pic));
                    results.push(map);
                }
            }
        } else {
            ne_log!("W", "search: no data.resources found in response");
        }

        ne_log!("I", "search: returning {} results", results.len());
        Ok(results)
    }
}

impl Default for NetEaseCloud {
    fn default() -> Self {
        Self::new()
    }
}

static NETEASE_CLOUD: std::sync::LazyLock<NetEaseCloud> =
    std::sync::LazyLock::new(NetEaseCloud::new);

#[flutter_rust_bridge::frb]
pub fn ne_lyric(song_id: i64) -> Result<String, String> {
    let json = NETEASE_CLOUD.fetch_lyric_json(song_id)?;
    compact_lyric_json(&json)
}

#[flutter_rust_bridge::frb]
pub fn ne_search(keyword: String, limit: i32) -> Result<Vec<HashMap<String, String>>, String> {
    NETEASE_CLOUD.search(keyword, limit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compact_lyric_prefers_yrc_and_ytlrc() {
        let json = serde_json::json!({
            "code": 200,
            "yrc": {"lyric": "word"},
            "lrc": {"lyric": "line"},
            "ytlrc": {"lyric": "word-trans"},
            "tlyric": {"lyric": "line-trans"},
            "yromalrc": {"lyric": "word-roma"},
            "romalrc": {"lyric": "line-roma"},
        });
        let payload: serde_json::Value =
            serde_json::from_str(&compact_lyric_json(&json).unwrap()).unwrap();
        assert_eq!(payload["main"], "word");
        assert_eq!(payload["trans"], "word-trans");
        assert_eq!(payload["roma"], "word-roma");
        assert_eq!(payload["format"], "yrc");
    }

    #[test]
    fn compact_lyric_falls_back_to_lrc_fields() {
        let json = serde_json::json!({
            "code": 200,
            "lrc": {"lyric": "line"},
            "tlyric": {"lyric": "line-trans"},
            "romalrc": {"lyric": "line-roma"},
        });
        let payload: serde_json::Value =
            serde_json::from_str(&compact_lyric_json(&json).unwrap()).unwrap();
        assert_eq!(payload["main"], "line");
        assert_eq!(payload["trans"], "line-trans");
        assert_eq!(payload["roma"], "line-roma");
        assert_eq!(payload["format"], "lrc");
    }
}
