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

fn aes_decrypt(data: &[u8], key: &[u8; 16]) -> Vec<u8> {
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
    result
}

fn eapi_params_encrypt(path: &[u8], params: &str) -> String {
    let mut hasher = Md5::new();
    hasher.update(b"nobody");
    hasher.update(path);
    hasher.update(b"use");
    hasher.update(params.as_bytes());
    hasher.update(b"md5forencrypt");
    let sign = format!("{:x}", hasher.finalize());

    let mut src = Vec::new();
    src.extend_from_slice(path);
    src.extend_from_slice(b"-36cd479b6b5-");
    src.extend_from_slice(params.as_bytes());
    src.extend_from_slice(b"-36cd479b6b5-");
    src.extend_from_slice(sign.as_bytes());

    let encrypted = aes_encrypt(&src, EAPI_KEY);
    format!("params={}", hex::encode(encrypted).to_uppercase())
}

fn eapi_response_decrypt(data: &[u8]) -> Vec<u8> {
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
    pub lyricUser: Option<LyricUser>,
    pub transUser: Option<LyricUser>,
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

    fn get_params_header(&self) -> String {
        let cookies = self.cookies.lock().unwrap();
        serde_json::json!({
            "clientSign": cookies.get("clientSign").cloned().unwrap_or_default(),
            "os": cookies.get("os").cloned().unwrap_or_else(|| "pc".to_string()),
            "appver": cookies.get("appver").cloned().unwrap_or_else(|| "3.1.3.203419".to_string()),
            "deviceId": cookies.get("deviceId").cloned().unwrap_or_default(),
            "requestId": 0,
            "osver": cookies.get("osver").cloned().unwrap_or_default(),
        })
        .to_string()
    }

    fn get_request_header(&self) -> Vec<(String, String)> {
        let cookies = self.cookies.lock().unwrap();
        let mut headers = vec![
            ("accept".to_string(), "*/*".to_string()),
            ("content-type".to_string(), "application/x-www-form-urlencoded".to_string()),
            ("mconfig-info".to_string(), r#"{"IuRPVVmc3WWul9fT":{"version":733184,"appver":"3.1.3.203419"}}"#.to_string()),
            ("origin".to_string(), "orpheus://orpheus".to_string()),
            ("user-agent".to_string(), "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.3.203419".to_string()),
            ("sec-ch-ua".to_string(), "\"Chromium\";v=\"91\"".to_string()),
            ("sec-ch-ua-mobile".to_string(), "?0".to_string()),
            ("sec-fetch-site".to_string(), "cross-site".to_string()),
            ("sec-fetch-mode".to_string(), "cors".to_string()),
            ("sec-fetch-dest".to_string(), "empty".to_string()),
            ("accept-encoding".to_string(), "gzip, deflate, br".to_string()),
            ("accept-language".to_string(), "en-US,en;q=0.9".to_string()),
        ];

        for (k, v) in cookies.iter() {
            headers.push(("cookie".to_string(), format!("{}={}", k, v)));
        }

        headers
    }

    pub fn init(&self) -> Result<(), String> {
        let now = get_current_timestamp();
        let expire = self.expire.lock().unwrap();
        if *expire > now {
            return Ok(());
        }
        drop(expire);

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

        let pre_cookies = serde_json::json!({
            "os": "pc",
            "deviceId": device_id,
            "osver": osver,
            "clientSign": client_sign,
            "channel": "netease",
            "mode": mode,
            "appver": "3.1.3.203419",
        });

        let params = serde_json::json!({
            "username": username,
            "e_r": true,
            "header": self.get_params_header(),
        });

        let params_str = params.to_string();
        let path = b"/eapi/register/anonimous".to_vec();
        let encrypted = eapi_params_encrypt(&path, &params_str);

        let url = "https://interface.music.163.com/eapi/register/anonimous";
        let headers = self.get_request_header();

        let mut request = self.client.post(url);
        for (k, v) in headers {
            request = request.header(&k, &v);
        }
        request = request.body(encrypted);

        let response = request.send().map_err(|e| e.to_string())?;

        let cookie_header = response.headers().get("set-cookie").cloned();

        let data = eapi_response_decrypt(response.bytes().map_err(|e| e.to_string())?.as_ref());
        let json_str = String::from_utf8(data).map_err(|e| e.to_string())?;
        let json: serde_json::Value = serde_json::from_str(&json_str).map_err(|e| e.to_string())?;

        if json["code"].as_i64().unwrap_or(-1) != 200 {
            return Err(format!("Anon login failed: {}", json_str));
        }

        let mut cookies = self.cookies.lock().unwrap();
        cookies.insert("WEVNSM".to_string(), "1.0.0".to_string());
        cookies.insert("os".to_string(), "pc".to_string());
        cookies.insert(
            "deviceId".to_string(),
            pre_cookies["deviceId"].as_str().unwrap_or("").to_string(),
        );
        cookies.insert(
            "osver".to_string(),
            pre_cookies["osver"].as_str().unwrap_or("").to_string(),
        );
        cookies.insert(
            "clientSign".to_string(),
            pre_cookies["clientSign"].as_str().unwrap_or("").to_string(),
        );
        cookies.insert("channel".to_string(), "netease".to_string());
        cookies.insert(
            "mode".to_string(),
            pre_cookies["mode"].as_str().unwrap_or("").to_string(),
        );
        cookies.insert("appver".to_string(), "3.1.3.203419".to_string());

        if let Some(cookies_header) = cookie_header {
            let cookie_str = cookies_header.to_str().unwrap_or("");
            for cookie_pair in cookie_str.split(';') {
                if let Some(eq_pos) = cookie_pair.find('=') {
                    let name = cookie_pair[..eq_pos].trim().to_string();
                    let value = cookie_pair[eq_pos + 1..].trim().to_string();
                    match name.as_str() {
                        "NMTID" => {
                            cookies.insert("NMTID".to_string(), value);
                        }
                        "MUSIC_A" => {
                            cookies.insert("MUSIC_A".to_string(), value);
                        }
                        "__csrf" => {
                            cookies.insert("__csrf".to_string(), value);
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

        let params = serde_json::json!({
            "id": song_id,
            "lv": "-1",
            "tv": "-1",
            "rv": "-1",
            "yv": "-1",
            "e_r": true,
            "header": self.get_params_header(),
            "cache_key": get_cache_key(&format!("e_r=true&id={}", song_id)),
        });

        let params_str = params.to_string();
        let path = b"/eapi/song/lyric/v1".to_vec();
        let encrypted = eapi_params_encrypt(&path, &params_str);

        let url = "https://interface.music.163.com/eapi/song/lyric/v1";
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
            .body(encrypted);

        let response = request.send().map_err(|e| e.to_string())?;
        let data = eapi_response_decrypt(response.bytes().map_err(|e| e.to_string())?.as_ref());
        let json_str = String::from_utf8(data).map_err(|e| e.to_string())?;
        let result: LyricResult = serde_json::from_str(&json_str).map_err(|e| e.to_string())?;

        if result.code != 200 {
            return Err(format!("Get lyric failed with code: {}", result.code));
        }

        Ok(result)
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
