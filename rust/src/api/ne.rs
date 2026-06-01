use aes::cipher::{BlockDecrypt, BlockEncrypt, KeyInit};
use aes::Aes128;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use md5::{Digest, Md5};
use rand::seq::SliceRandom;
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

macro_rules! ne_log {
    ($level:literal, $($arg:tt)*) => {
        eprintln!("[NE-{}] {}", $level, format!($($arg)*));
    };
}

const EAPI_KEY: &[u8; 16] = b"e82ckenh8dichen8";
const CACHE_KEY_KEY: &[u8; 16] = b")(13daqP@ssw0rd~";
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
    if data.len() % 16 != 0 {
        return Err(format!("invalid encrypted data length: {} (not a multiple of 16)", data.len()));
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
    let data = format!("{}-36cd479b6b5-{}-36cd479b6b5-{}", encrypt_path, params, digest);
    let encrypted = aes_encrypt(data.as_bytes(), EAPI_KEY);
    let hex_str: String = encrypted.iter().map(|b| format!("{:02X}", b)).collect();
    format!("params={}", hex_str)
}

fn hex_preview(data: &[u8], max_len: usize) -> String {
    let len = data.len().min(max_len);
    let preview: Vec<String> = data[..len].iter().map(|b| format!("{:02X}", b)).collect();
    let suffix = if data.len() > max_len { "..." } else { "" };
    format!("{}{}", preview.join(" "), suffix)
}

fn eapi_response_decrypt(data: &[u8]) -> Result<Vec<u8>, String> {
    aes_decrypt(data, EAPI_KEY)
}

fn get_cache_key(data: &str) -> String {
    let encrypted = aes_encrypt(data.as_bytes(), CACHE_KEY_KEY);
    BASE64.encode(encrypted)
}

fn get_anonimous_username(device_id: &str) -> String {
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
    let mut rng = rand::thread_rng();
    let mac: String = (0..6)
        .map(|_| format!("{:02X}", rng.gen::<u8>()))
        .collect::<Vec<_>>()
        .join(":");
    let random_str: String = (0..8)
        .map(|_| {
            let idx = rng.gen_range(0..26);
            (b'A' + idx) as char
        })
        .collect();
    let hash_part = hex::encode(rng.gen::<[u8; 32]>());
    format!("{}@@@{}@@@@@@{}", mac, random_str, hash_part)
}

fn get_current_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
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
    client: reqwest::blocking::Client,
    cookies: Mutex<HashMap<String, String>>,
    user_id: Mutex<Option<i64>>,
    expire: Mutex<u64>,
}

impl NetEaseCloud {
    pub fn new() -> Self {
        let client = reqwest::blocking::Client::builder().build().unwrap();

        NetEaseCloud {
            client,
            cookies: Mutex::new(HashMap::new()),
            user_id: Mutex::new(None),
            expire: Mutex::new(0),
        }
    }

    /// Headers: User-Agent, Referer, Cookie (only 3)
    fn get_request_header(&self) -> Vec<(String, String)> {
        let cookies = self.cookies.lock().unwrap();
        let mut headers = vec![
            ("User-Agent".to_string(), "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.3.203419".to_string()),
            ("Referer".to_string(), "https://music.163.com/".to_string()),
        ];
        let cookie_str: String = cookies.iter().map(|(k, v)| format!("{}={}", k, v)).collect::<Vec<_>>().join("; ");
        if !cookie_str.is_empty() {
            headers.push(("Cookie".to_string(), cookie_str));
        }
        headers
    }

    pub fn init(&self) -> Result<(), String> {
        let now = get_current_timestamp();
        let expire = self.expire.lock().unwrap();
        if *expire > now {
            ne_log!("D", "init: session still valid, expire={}", *expire);
            return Ok(());
        }
        drop(expire);

        ne_log!("I", "init: starting anonymous login");

        let device_id = generate_device_id();
        let username = get_anonimous_username(&device_id);
        let osver = format!(
            "Microsoft-Windows-10--build-{}00-64bit",
            rand::thread_rng().gen_range(200..300)
        );

        let modes = [
            "MS-iCraft B760M WIFI",
            "ASUS ROG STRIX Z790",
            "MSI MAG B550 TOMAHAWK",
            "ASRock X670E Taichi",
        ];
        let mode = modes
            .choose(&mut rand::thread_rng())
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
        ].iter().cloned().collect();

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
        let headers = self.get_request_header();

        let mut request = self.client.post(url);
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

        let headers_map: HashMap<String, String> = response.headers()
            .iter()
            .map(|(k, v)| (k.as_str().to_string(), v.to_str().unwrap_or("").to_string()))
            .collect();
        ne_log!("D", "init: response headers: {:?}", headers_map);

        let cookie_header = response.headers().get("set-cookie").cloned();

        let response_bytes = response.bytes().map_err(|e| {
            ne_log!("E", "init: failed to read response body: {}", e);
            e.to_string()
        })?;
        ne_log!("D", "init: response body size={} bytes", response_bytes.len());
        ne_log!("D", "init: response hex preview: {}", hex_preview(&response_bytes, 64));

        let data = eapi_response_decrypt(response_bytes.as_ref()).map_err(|e| {
            ne_log!("E", "init: decrypt failed: {}", e);
            ne_log!("E", "init: raw response hex: {}", hex_preview(&response_bytes, 256));
            format!("decrypt failed: {}", e)
        })?;

        let json_str = String::from_utf8(data).map_err(|e| {
            ne_log!("E", "init: UTF8 decode failed: {}", e);
            e.to_string()
        })?;
        ne_log!("D", "init: decrypted: {}", json_str);

        let json: serde_json::Value = serde_json::from_str(&json_str).map_err(|e| {
            ne_log!("E", "init: JSON parse failed: {}", e);
            e.to_string()
        })?;

        if json["code"].as_i64().unwrap_or(-1) != 200 {
            ne_log!("E", "init: login failed, code={}, body={}", json["code"].as_i64().unwrap_or(-1), json_str);
            return Err(format!("Anon login failed: {}", json_str));
        }

        ne_log!("I", "init: login successful, userId={}", json["userId"].as_i64().unwrap_or(0));

        let mut cookies = self.cookies.lock().unwrap();
        for (k, v) in &pre_cookies {
            cookies.insert(k.clone(), v.clone());
        }

        if let Some(cookies_header) = cookie_header {
            let cookie_str = cookies_header.to_str().unwrap_or("");
            for cookie_pair in cookie_str.split(';') {
                if let Some(eq_pos) = cookie_pair.find('=') {
                    let name = cookie_pair[..eq_pos].trim().to_string();
                    let value = cookie_pair[eq_pos + 1..].trim().to_string();
                    match name.as_str() {
                        "NMTID" | "MUSIC_A" | "__csrf" => {
                            cookies.insert(name, value);
                        }
                        _ => {}
                    }
                }
            }
        }

        let user_id = json["userId"].as_i64().unwrap_or(0);
        let new_expire = get_current_timestamp() + 864000;

        *self.user_id.lock().unwrap() = Some(user_id);
        *self.expire.lock().unwrap() = new_expire;

        Ok(())
    }

    pub fn get_lyric(&self, song_id: i64) -> Result<LyricResult, String> {
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
        // /eapi/song/lyric/v1 -> /api/song/lyric/v1
        let encrypt_path = "/api/song/lyric/v1";
        let body = eapi_params_encrypt(encrypt_path, &params_str);

        let url = "https://interface.music.163.com/eapi/song/lyric/v1";
        ne_log!("D", "get_lyric: POST {}", url);
        let headers = self.get_request_header();

        let mut request = self.client.post(url);
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
        ne_log!("D", "get_lyric: response body size={} bytes", response_bytes.len());
        ne_log!("D", "get_lyric: response hex preview: {}", hex_preview(&response_bytes, 64));

        let data = eapi_response_decrypt(response_bytes.as_ref()).map_err(|e| {
            ne_log!("E", "get_lyric: decrypt failed: {}", e);
            ne_log!("E", "get_lyric: raw response hex: {}", hex_preview(&response_bytes, 256));
            format!("decrypt failed: {}", e)
        })?;

        let json_str = String::from_utf8(data).map_err(|e| {
            ne_log!("E", "get_lyric: UTF8 decode failed: {}", e);
            e.to_string()
        })?;
        ne_log!("D", "get_lyric: decrypted (first 200 chars): {}", &json_str[..json_str.len().min(200)]);

        let result: LyricResult = serde_json::from_str(&json_str).map_err(|e| {
            ne_log!("E", "get_lyric: JSON parse failed: {}", e);
            e.to_string()
        })?;

        if result.code != 200 {
            ne_log!("W", "get_lyric: API returned code={}", result.code);
            return Err(format!("Get lyric failed with code: {}", result.code));
        }

        ne_log!("I", "get_lyric: success, lrc={}, yrc={}, tlyric={}",
            result.lrc.as_ref().map(|l| l.lyric.len()).unwrap_or(0),
            result.yrc.as_ref().map(|l| l.lyric.len()).unwrap_or(0),
            result.tlyric.as_ref().map(|l| l.lyric.len()).unwrap_or(0));

        Ok(result)
    }

    /// Search NeSource
    pub fn search(&self, keyword: String, limit: i32) -> Result<Vec<HashMap<String, String>>, String> {
        self.init()?;
        ne_log!("I", "search: keyword='{}', limit={}", keyword, limit);

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
        let headers = self.get_request_header();

        let mut request = self.client.post(url);
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

        ne_log!("D", "search: response body size={} bytes", response_bytes.len());
        ne_log!("D", "search: response hex preview: {}", hex_preview(&response_bytes, 128));

        if response_bytes.is_empty() {
            ne_log!("E", "search: empty response from NetEase");
            return Err("empty response from NetEase".to_string());
        }

        let data = eapi_response_decrypt(response_bytes.as_ref()).map_err(|e| {
            ne_log!("E", "search: decrypt failed: {}", e);
            ne_log!("E", "search: raw response hex: {}", hex_preview(&response_bytes, 512));
            format!("decrypt failed: {}", e)
        })?;

        let json_str = String::from_utf8(data).map_err(|e| {
            ne_log!("E", "search: UTF8 decode failed: {}", e);
            e.to_string()
        })?;
        ne_log!("D", "search: decrypted (first 500 chars): {}", &json_str[..json_str.len().min(500)]);

        let json: serde_json::Value = serde_json::from_str(&json_str).map_err(|e| {
            ne_log!("E", "search: JSON parse failed: {}", e);
            e.to_string()
        })?;

        let code = json["code"].as_i64().unwrap_or(-1);
        ne_log!("D", "search: response code={}", code);
        if code != 200 {
            ne_log!("W", "search: API returned code={}, body: {}", code, &json_str[..json_str.len().min(500)]);
            return Err(format!("Search failed with code: {}", code));
        }

        let mut results = Vec::new();
        if let Some(resources) = json["data"]["resources"].as_array() {
            ne_log!("D", "search: found {} resources", resources.len());
            for (i, resource) in resources.iter().enumerate() {
                if let Some(song) = resource["baseInfo"]["simpleSongData"].as_object() {
                    let mut map = HashMap::new();
                    map.insert("id".to_string(), song["id"].as_i64().unwrap_or(0).to_string());
                    let name = song["name"].as_str().unwrap_or("").to_string();
                    map.insert("name".to_string(), name.clone());
                    if let Some(artists) = song["ar"].as_array() {
                        let artist_names: Vec<String> = artists.iter()
                            .filter_map(|a| a["name"].as_str().map(String::from))
                            .collect();
                        let artists_str = artist_names.join(", ");
                        map.insert("artists".to_string(), artists_str);
                    }
                    if let Some(album) = song["al"].as_object() {
                        map.insert("album".to_string(), album.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string());
                    }
                    ne_log!("D", "search: [{}] {} - {}", i, name, map.get("artists").cloned().unwrap_or_default());
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
    let result = NETEASE_CLOUD.get_lyric(song_id)?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

#[flutter_rust_bridge::frb]
pub fn ne_search(keyword: String, limit: i32) -> Result<Vec<HashMap<String, String>>, String> {
    NETEASE_CLOUD.search(keyword, limit)
}
