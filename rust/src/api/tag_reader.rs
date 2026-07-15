use std::{
    collections::{HashSet, VecDeque},
    fs::{self},
    io::{self, Cursor, Write},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{Duration, UNIX_EPOCH},
};

use image::imageops;
use lofty::config::{ParseOptions, ParsingMode, WriteOptions};
use lofty::prelude::{Accessor, AudioFile, ItemKey, TaggedFileExt};
use lofty::probe::Probe;
use lofty::tag::Tag;
use windows::{
    core::Interface,
    core::HSTRING,
    Storage::{
        FileProperties::ThumbnailMode,
        StorageFile,
        Streams::{DataReader, IInputStream},
    },
};

use crate::frb_generated::StreamSink;

use super::library_db;
use super::logger::log_to_dart;

/// 将迭代器中的字符串去重后用 "/" 拼接。
/// FLAC Vorbis Comment 可能包含重复的多值标签（如多个相同的 ARTIST）。
fn join_deduped<'a>(items: impl IntoIterator<Item = &'a str>) -> String {
    let mut seen = HashSet::new();
    let mut result = String::new();
    for item in items {
        if seen.insert(item.to_string()) {
            if !result.is_empty() {
                result.push('/');
            }
            result.push_str(item);
        }
    }
    result
}

#[derive(Clone)]
pub struct AudioExtraItem {
    pub key: String,
    pub value: String,
}

#[derive(Clone)]
pub struct AudioExtraMetadata {
    pub extension: String,
    pub file_size: u64,
    pub channels: Option<u8>,
    pub bit_depth: Option<u8>,
    pub items: Vec<AudioExtraItem>,
    pub replaygain_track_gain: Option<String>,
    pub replaygain_track_peak: Option<String>,
    pub replaygain_album_gain: Option<String>,
    pub replaygain_album_peak: Option<String>,
}

/// for Flutter
pub fn read_audio_extra_metadata(path: String) -> AudioExtraMetadata {
    let file_size = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    let extension = Path::new(&path)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string();

    let mut channels: Option<u8> = None;
    let mut bit_depth: Option<u8> = None;
    let mut items: Vec<AudioExtraItem> = vec![];
    let mut replaygain_track_gain: Option<String> = None;
    let mut replaygain_track_peak: Option<String> = None;
    let mut replaygain_album_gain: Option<String> = None;
    let mut replaygain_album_peak: Option<String> = None;

    let options = ParseOptions::new()
        .parsing_mode(ParsingMode::Relaxed)
        .read_tags(true)
        .read_cover_art(false)
        .read_properties(true);

    let tagged_file = match Probe::open(&path)
        .and_then(|p| p.options(options).read())
    {
        Ok(val) => val,
        Err(err) => {
            log_to_dart(format!("{:?}: {}", path, err));
            return AudioExtraMetadata {
                extension,
                file_size,
                channels: None,
                bit_depth: None,
                items: vec![],
                replaygain_track_gain: None,
                replaygain_track_peak: None,
                replaygain_album_gain: None,
                replaygain_album_peak: None,
            };
        }
    };

    let props = tagged_file.properties();
    channels = props.channels();
    bit_depth = props.bit_depth();

    if let Some(tag) = tagged_file.primary_tag().or_else(|| tagged_file.first_tag()) {
        let mut push_kv = |key: &str, val: Option<&str>| {
            if let Some(v) = val {
                if !v.trim().is_empty() {
                    items.push(AudioExtraItem {
                        key: key.to_string(),
                        value: v.to_string(),
                    });
                }
            }
        };

        let track_artist = join_deduped(tag.get_strings(&ItemKey::TrackArtist));
        let album_artist = join_deduped(tag.get_strings(&ItemKey::AlbumArtist));

        push_kv(
            "genre",
            tag.get(&ItemKey::Genre).and_then(|v| v.value().text()),
        );
        push_kv(
            "date",
            tag.get(&ItemKey::RecordingDate).and_then(|v| v.value().text()),
        );
        push_kv(
            "year",
            tag.get(&ItemKey::Year).and_then(|v| v.value().text()),
        );
        push_kv(
            "release_date",
            tag.get(&ItemKey::ReleaseDate).and_then(|v| v.value().text()),
        );
        push_kv(
            "disc",
            tag.get(&ItemKey::DiscNumber).and_then(|v| v.value().text()),
        );
        push_kv(
            "disc_total",
            tag.get(&ItemKey::DiscTotal).and_then(|v| v.value().text()),
        );
        push_kv(
            "track_total",
            tag.get(&ItemKey::TrackTotal).and_then(|v| v.value().text()),
        );
        push_kv(
            "artist",
            if track_artist.is_empty() {
                None
            } else {
                Some(track_artist.as_str())
            },
        );
        push_kv(
            "album_artist",
            if album_artist.is_empty() {
                None
            } else {
                Some(album_artist.as_str())
            },
        );
        push_kv(
            "composer",
            tag.get(&ItemKey::Composer).and_then(|v| v.value().text()),
        );
        push_kv(
            "lyricist",
            tag.get(&ItemKey::Lyricist).and_then(|v| v.value().text()),
        );
        push_kv(
            "label",
            tag.get(&ItemKey::Label).and_then(|v| v.value().text()),
        );
        push_kv(
            "comment",
            tag.get(&ItemKey::Comment).and_then(|v| v.value().text()),
        );
        push_kv(
            "encoded_by",
            tag.get(&ItemKey::EncodedBy).and_then(|v| v.value().text()),
        );
        push_kv(
            "encoder",
            tag.get(&ItemKey::EncoderSoftware)
                .and_then(|v| v.value().text())
                .or_else(|| tag.get(&ItemKey::EncodedBy).and_then(|v| v.value().text())),
        );
        push_kv(
            "encoder_settings",
            tag.get(&ItemKey::EncoderSettings).and_then(|v| v.value().text()),
        );
        replaygain_track_gain = tag
            .get(&ItemKey::ReplayGainTrackGain)
            .and_then(|v| v.value().text())
            .map(|s| s.to_string());
        replaygain_track_peak = tag
            .get(&ItemKey::ReplayGainTrackPeak)
            .and_then(|v| v.value().text())
            .map(|s| s.to_string());
        replaygain_album_gain = tag
            .get(&ItemKey::ReplayGainAlbumGain)
            .and_then(|v| v.value().text())
            .map(|s| s.to_string());
        replaygain_album_peak = tag
            .get(&ItemKey::ReplayGainAlbumPeak)
            .and_then(|v| v.value().text())
            .map(|s| s.to_string());
        push_kv(
            "bpm",
            tag.get(&ItemKey::Bpm)
                .and_then(|v| v.value().text())
                .or_else(|| tag.get(&ItemKey::IntegerBpm).and_then(|v| v.value().text())),
        );
        push_kv(
            "language",
            tag.get(&ItemKey::Language).and_then(|v| v.value().text()),
        );
        push_kv(
            "copyright",
            tag.get(&ItemKey::CopyrightMessage)
                .and_then(|v| v.value().text()),
        );
        push_kv(
            "license",
            tag.get(&ItemKey::License).and_then(|v| v.value().text()),
        );
    }

    AudioExtraMetadata {
        extension,
        file_size,
        channels,
        bit_depth,
        items,
        replaygain_track_gain,
        replaygain_track_peak,
        replaygain_album_gain,
        replaygain_album_peak,
    }
}

/// K: extension, V: can read tags by using Lofty
static SUPPORTED_FORMATS: phf::Map<&'static str, bool> = phf::phf_map! {
    "mp3" => true, "mp2" => false, "mp1" => false,
    "ogg" => true,
    "wav" => true, "wave" => true,
    "aif" => true, "aiff" => true, "aifc" => true,
    // 通过 Windows 系统支持
    "asf" => false, "wma" => false,
    "aac" => true, "adts" => true,
    "m4a" => true,
    "mka" => false, "webm" => false,
    "ac3" => false,
    "amr" => false, "3ga" => false,
    "flac" => true,
    "mpc" => true,
    // 插件支持
    "mid" => false,
    "wv" => true, "wvc" => true,
    "opus" => true,
    "dsf" => false, "dff" => false,
    "ape" => true,
};

pub struct IndexActionState {
    /// completed / total
    pub progress: f64,

    /// describe action state
    pub message: String,
}

#[derive(Debug)]
struct Audio {
    title: String,
    artist: String,
    album: String,
    album_artist: Option<String>,
    track: Option<u32>,
    /// in secs
    duration: u64,
    /// kbps
    bitrate: Option<u32>,
    sample_rate: Option<u32>,
    /// absolute path
    path: String,
    /// secs since UNIX_EPOCH
    modified: u64,
    /// secs since UNIX_EPOCH
    created: u64,
    /// 标签获取方式
    by: Option<String>,
}

impl Audio {
    fn new_with_path(path: impl AsRef<Path>, by: Option<String>) -> Option<Self> {
        let path = path.as_ref();
        Some(Audio {
            title: path.file_name()?.to_string_lossy().to_string(),
            artist: "UNKNOWN".to_string(),
            album: "UNKNOWN".to_string(),
            album_artist: None,
            track: None,
            duration: 0,
            bitrate: None,
            sample_rate: None,
            path: path.to_string_lossy().to_string(),
            modified: 0,
            created: 0,
            by,
        })
    }

    fn to_json_value(&self) -> serde_json::Value {
        serde_json::json!({
            "title": self.title,
            "artist": self.artist,
            "album": self.album,
            "album_artist": self.album_artist,
            "track": self.track,
            "duration": self.duration,
            "bitrate": self.bitrate,
            "sample_rate": self.sample_rate,
            "path": self.path,
            "modified": self.modified,
            "created": self.created,
            "by": self.by
        })
    }

    /// 不支持：None  
    /// WAV/AIFF 等 RIFF 格式优先走 Windows API（处理系统编码 locale 问题）  
    /// 其他格式：Lofty 优先 → Windows API 回退  
    /// 再不能的话：title: filename 代替
    fn read_from_path(path: impl AsRef<Path>) -> Option<Self> {
        let path = path.as_ref();
        let ext_lower = path
            .extension()?
            .to_ascii_lowercase()
            .to_string_lossy()
            .to_string();
        let lofty_support: bool = *SUPPORTED_FORMATS.get(&ext_lower)?;

        let file_metadata = match fs::metadata(path) {
            Ok(val) => val,
            Err(err) => {
                log_to_dart(err.to_string());
                return None;
            }
        };
        let modified = file_metadata
            .modified()
            .unwrap_or(UNIX_EPOCH)
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_secs();
        let created = file_metadata
            .created()
            .unwrap_or(UNIX_EPOCH)
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_secs();

        // WAV/AIFF 等 RIFF 格式：RIFF INFO 块编码依赖系统 locale，
        // Windows API 能正确处理，Lofty 会乱码 CJK 文本。
        // 因此 WAV/AIFF 优先走 Windows → Lofty 回退。
        let is_riff_format = matches!(
            ext_lower.as_str(),
            "wav" | "wave" | "aif" | "aiff" | "aifc"
        );

        if is_riff_format {
            match Self::read_by_win_music_properties(path, modified, created) {
                Ok(value) => return Some(value),
                Err(_) => {
                    // Windows API 失败，回退到 Lofty
                    if let Some(value) = Self::read_by_lofty(path, modified, created) {
                        return Some(value);
                    }
                    return Self::new_with_path(path, None);
                }
            }
        }

        if lofty_support {
            if let Some(value) = Self::read_by_lofty(path, modified, created) {
                return Some(value);
            }

            match Self::read_by_win_music_properties(path, modified, created) {
                Ok(value) => Some(value),
                Err(err) => {
                    log_to_dart(format!("{:?}: {}", path, err));
                    Self::new_with_path(path, None)
                }
            }
        } else {
            Self::new_with_path(path, None)
        }
    }

    /// 使用 lofty 获取音乐标签。只在文件名不正确、没有标签或包含不支持的编码时返回 None
    fn read_by_lofty(path: impl AsRef<Path>, modified: u64, created: u64) -> Option<Self> {
        let path = path.as_ref();
        let mut file = match std::fs::File::open(path) {
            Ok(f) => f,
            Err(err) => {
                log_to_dart(format!("{:?}: {}", path, err));
                return None;
            }
        };
        let tagged_file = match lofty::read_from(&mut file) {
            Ok(val) => val,
            Err(err) => {
                log_to_dart(format!("{:?}: {}", path, err));
                return None;
            }
        };

        let properties = tagged_file.properties();

        if let Some(tag) = tagged_file
            .primary_tag()
            .or_else(|| tagged_file.first_tag())
        {
            let artist = {
                let joined = join_deduped(tag.get_strings(&ItemKey::TrackArtist));
                if joined.is_empty() {
                    "UNKNOWN".to_string()
                } else {
                    joined
                }
            };

            let album_artist = {
                let joined = join_deduped(tag.get_strings(&ItemKey::AlbumArtist));
                if joined.is_empty() {
                    None
                } else {
                    Some(joined)
                }
            };

            return Some(Audio {
                title: tag
                    .title()
                    .unwrap_or(path.file_name()?.to_string_lossy())
                    .to_string(),
                artist,
                album: tag
                    .album()
                    .map(|a| a.to_string())
                    .unwrap_or_else(|| "UNKNOWN".to_string()),
                album_artist,
                track: tag.track(),
                duration: properties.duration().as_secs(),
                bitrate: properties.audio_bitrate(),
                sample_rate: properties.sample_rate(),
                path: path.to_string_lossy().to_string(),
                modified,
                created,
                by: Some("Lofty".to_string()),
            });
        }

        Some(Audio {
            title: path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
            artist: std::borrow::Cow::Borrowed("UNKNOWN").to_string(),
            album: std::borrow::Cow::Borrowed("UNKNOWN").to_string(),
            album_artist: None,
            track: None,
            duration: properties.duration().as_secs(),
            bitrate: properties.audio_bitrate(),
            sample_rate: properties.sample_rate(),
            path: path.to_string_lossy().to_string(),
            modified,
            created,
            by: Some("Lofty".to_string()),
        })
    }

    /// 使用 Windows Api 获取音乐标签。会因为各种原因返回 Err
    fn read_by_win_music_properties(
        path: impl AsRef<Path>,
        modified: u64,
        created: u64,
    ) -> Result<Self, windows::core::Error> {
        let path = path.as_ref();
        let storage_file = StorageFile::GetFileFromPathAsync(&HSTRING::from(path))?.get()?;
        let music_properties = storage_file
            .Properties()?
            .GetMusicPropertiesAsync()?
            .get()?;

        let duration: Duration = music_properties.Duration()?.into();

        let mut title = music_properties
            .Title()
            .or_else(|_| storage_file.Name())?
            .to_string();
        if title.is_empty() {
            title = storage_file.Name()?.to_string();
        }

        let mut artist = music_properties
            .Artist()
            .unwrap_or(HSTRING::from("UNKNOWN"))
            .to_string();
        if artist.is_empty() {
            artist = "UNKNOWN".to_string();
        }

        let mut album = music_properties
            .Album()
            .unwrap_or(HSTRING::from("UNKNOWN"))
            .to_string();
        if album.is_empty() {
            album = "UNKNOWN".to_string();
        }

        let album_artist = music_properties
            .AlbumArtist()
            .unwrap_or(HSTRING::from(""))
            .to_string();
        let album_artist = if album_artist.is_empty() {
            None
        } else {
            Some(album_artist)
        };

        Ok(Audio {
            title,
            artist,
            album,
            album_artist,
            track: Some(music_properties.TrackNumber()?),
            duration: duration.as_secs(),
            bitrate: Some(music_properties.Bitrate()? / 1000),
            sample_rate: None,
            path: path.to_string_lossy().to_string(),
            modified,
            created,
            by: Some("Windows".to_string()),
        })
    }
}

#[derive(Debug)]
struct AudioFolder {
    path: String,
    /// secs since UNIX_EPOCH
    modified: u64,
    /// biggest created in audios. secs since UNIX_EPOCH
    latest: u64,
    audios: Vec<Audio>,
}

impl AudioFolder {
    fn to_json_value(&self) -> serde_json::Value {
        let mut audios_json: Vec<serde_json::Value> = Vec::new();
        for audio in &self.audios {
            audios_json.push(audio.to_json_value());
        }

        serde_json::json!({
            "path": self.path,
            "modified": self.modified,
            "latest": self.latest,
            "audios": audios_json,
        })
    }

    /// 扫描路径为 path 的文件夹
    fn read_from_folder(path: impl AsRef<Path>) -> Result<AudioFolder, io::Error> {
        let path = path.as_ref();

        let dir = match fs::read_dir(path) {
            Ok(val) => val,
            Err(err) => {
                log_to_dart(format!("{:?}: {}", path, err));
                return Err(err);
            }
        };

        let mut audios: Vec<Audio> = vec![];
        let mut latest: u64 = 0;

        for item in dir {
            let entry = match item {
                Ok(value) => value,
                Err(_) => continue,
            };

            let file_type = match entry.file_type() {
                Ok(value) => value,
                Err(_) => continue,
            };

            if file_type.is_file() {
                if let Some(audio_item) = Audio::read_from_path(entry.path()) {
                    if audio_item.created > latest {
                        latest = audio_item.created;
                    }

                    audios.push(audio_item);
                }
            }
        }

        if !audios.is_empty() {
            return Ok(AudioFolder {
                path: path.to_string_lossy().to_string(),
                modified: fs::metadata(path)?
                    .modified()?
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or(Duration::ZERO)
                    .as_secs(),
                latest,
                audios,
            });
        }

        Err(io::Error::new(
            io::ErrorKind::NotFound,
            path.to_string_lossy() + " has no music.",
        ))
    }

    /// 扫描路径为 path 的文件夹及其所有子文件夹。
    fn read_from_folder_recursively(
        folder: impl AsRef<Path>,
        result: &mut Vec<Self>,
        scanned_count: &mut u64,
        total_count: &mut u64,
        scanned_folders: &mut HashSet<String>,
        sink: &StreamSink<IndexActionState>,
    ) -> Result<(), io::Error> {
        // total_count 已被外部预计为准确的目录总数，在此不递增
        let folder = folder.as_ref();
        if scanned_folders.contains(&folder.to_string_lossy().to_string()) {
            return Ok(());
        }

        let dir = match fs::read_dir(folder) {
            Ok(val) => val,
            Err(err) => {
                log_to_dart(format!("{:?}: {}", folder, err));
                return Ok(());
            }
        };

        let _ = sink.add(IndexActionState {
            progress: *scanned_count as f64 / *total_count as f64,
            message: String::from("正在扫描 ") + &folder.to_string_lossy(),
        });

        scanned_folders.insert(folder.to_string_lossy().to_string());
        let mut audios: Vec<Audio> = vec![];
        let mut latest: u64 = 0;

        for item in dir {
            let entry = match item {
                Ok(value) => value,
                Err(err) => {
                    log_to_dart(err.to_string());
                    continue;
                }
            };

            let file_type = match entry.file_type() {
                Ok(value) => value,
                Err(err) => {
                    log_to_dart(err.to_string());
                    continue;
                }
            };

            if file_type.is_dir() {
                let _ = Self::read_from_folder_recursively(
                    entry.path(),
                    result,
                    scanned_count,
                    total_count,
                    scanned_folders,
                    sink,
                );
            } else if let Some(metadata) = Audio::read_from_path(entry.path()) {
                if metadata.created > latest {
                    latest = metadata.created;
                }

                audios.push(metadata);
            }
        }

        if !audios.is_empty() {
            if let Ok(metadata) = fs::metadata(folder) {
                if let Ok(modified) = metadata.modified() {
                    result.push(AudioFolder {
                        path: folder.to_string_lossy().to_string(),
                        modified: modified
                            .duration_since(UNIX_EPOCH)
                            .unwrap_or(Duration::ZERO)
                            .as_secs(),
                        latest,
                        audios,
                    });
                }
            }
        }

        *scanned_count += 1;
        let _ = sink.add(IndexActionState {
            progress: *scanned_count as f64 / *total_count as f64,
            message: String::new(),
        });

        Ok(())
    }
}

fn _get_picture_by_windows(path: &str) -> Result<Vec<u8>, windows::core::Error> {
    let file = StorageFile::GetFileFromPathAsync(&HSTRING::from(path))?.get()?;
    let thumbnail = file
        .GetThumbnailAsyncOverloadDefaultSizeDefaultOptions(ThumbnailMode::MusicView)?
        .get()?;

    let size = thumbnail.Size()? as u32;
    let stream: IInputStream = thumbnail.cast()?;

    let mut buffer = vec![0u8; size as usize];
    let data_reader = DataReader::CreateDataReader(&stream)?;
    data_reader.LoadAsync(size)?.get()?;
    data_reader.ReadBytes(&mut buffer)?;

    data_reader.Close()?;
    stream.Close()?;

    Ok(buffer)
}

fn _get_picture_by_lofty(path: &str) -> Option<Vec<u8>> {
    let options = ParseOptions::new()
        .parsing_mode(ParsingMode::Relaxed)
        .read_tags(true)
        .read_cover_art(true)
        .read_properties(false);

    let tagged_file = match Probe::open(path)
        .and_then(|p| p.options(options).read())
    {
        Ok(f) => f,
        Err(_) => return None,
    };

    let tag = tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())?;

    Some(tag.pictures().first()?.data().to_vec())
}

const PICTURE_CACHE_CAPACITY: usize = 96;
type PictureCache = OnceLock<Mutex<VecDeque<(String, Vec<u8>)>>>;
static PICTURE_CACHE: PictureCache = OnceLock::new();

fn _picture_cache_key(path: &str, width: u32, height: u32) -> String {
    let modified_secs = fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{path}|{modified_secs}|{width}x{height}")
}

/// for Flutter  
/// 一次调用完成封面读取+颜色提取，避免 image bytes 穿越 FFI 两次
pub fn get_picture_and_colors(
    path: String,
    width: u32,
    height: u32,
    num_colors: i32,
) -> (Option<Vec<u8>>, Vec<u32>) {
    let pic = match _get_picture_by_lofty(&path) {
        Some(p) => p,
        None => match _get_picture_by_windows(&path) {
            Ok(val) => val,
            Err(err) => {
                log_to_dart(format!("fail to get pic: {}", err));
                return (None, vec![]);
            }
        },
    };
    let colors = super::color_extraction::extract_colors_from_image(pic.clone(), num_colors);

    let resized_png = match image::load_from_memory(&pic) {
        Ok(loaded) => {
            let ratio = loaded.width() as f32 / loaded.height() as f32;
            let (rw, rh) = if ratio > 1.0 {
                (width, (width as f32 / ratio).round() as u32)
            } else {
                ((height as f32 * ratio).round() as u32, height)
            };
            let resized = image::imageops::resize(&loaded, rw, rh, image::imageops::FilterType::Triangle);
            let mut buf = std::io::Cursor::new(Vec::new());
            if resized.write_to(&mut buf, image::ImageFormat::Png).is_ok() {
                Some(buf.into_inner())
            } else {
                None
            }
        }
        Err(_) => None,
    };

    (resized_png, colors)
}

/// for Flutter  
/// 如果无法通过 Lofty 获取则通过 Windows 获取
pub fn get_picture_from_path(path: String, width: u32, height: u32) -> Option<Vec<u8>> {
    let cache_key = _picture_cache_key(&path, width, height);
    if let Ok(cache_lock) = PICTURE_CACHE.get_or_init(|| Mutex::new(VecDeque::new())).lock()
    {
        if let Some(pos) = cache_lock.iter().position(|(k, _)| k == &cache_key) {
            let mut cache = cache_lock;
            if let Some((k, v)) = cache.remove(pos) {
                let val = v.clone();
                cache.push_front((k, v));
                return Some(val);
            }
        }
    }

    let pic_option =
        _get_picture_by_lofty(&path).or_else(|| match _get_picture_by_windows(&path) {
            Ok(val) => Some(val),
            Err(err) => {
                log_to_dart(format!("fail to get pic: {}", err));
                None
            }
        });

    if let Some(pic) = &pic_option {
        if let Ok(loaded_pic) = image::load_from_memory(pic) {
            // 计算新的宽高，保持原比例
            let pic_ratio = loaded_pic.width() as f32 / loaded_pic.height() as f32;

            let (result_width, result_height) = if pic_ratio > 1.0 {
                (width, (width as f32 / pic_ratio).round() as u32)
            } else {
                ((height as f32 * pic_ratio).round() as u32, height)
            };

            let resized_img = imageops::resize(
                &loaded_pic,
                result_width,
                result_height,
                imageops::FilterType::Triangle,
            );

            let mut output = Cursor::new(Vec::new());
            if resized_img.write_to(&mut output, image::ImageFormat::Png).is_ok() {
                let out = output.into_inner();
                if let Ok(mut cache) =
                    PICTURE_CACHE.get_or_init(|| Mutex::new(VecDeque::new())).lock()
                {
                    if let Some(pos) = cache.iter().position(|(k, _)| k == &cache_key) {
                        cache.remove(pos);
                    }
                    cache.push_front((cache_key, out.clone()));
                    while cache.len() > PICTURE_CACHE_CAPACITY {
                        cache.pop_back();
                    }
                }
                return Some(out);
            }
        }
    }

    pic_option
}

fn _get_lyric_from_lofty(path: &str) -> Option<String> {
    let path_ref = Path::new(&path);
    let options = ParseOptions::new()
        .parsing_mode(ParsingMode::Relaxed)
        .read_tags(true);
    let probe = match Probe::open(path_ref) {
        Ok(v) => v,
        Err(err) => {
            log_to_dart(format!("lofty probe open error: {:?}", err.kind()));
            return None;
        }
    };
    let tagged_file = match probe.options(options).read() {
        Ok(f) => f,
        Err(err) => {
            log_to_dart(format!("lofty probe read error: {:?}", err.kind()));
            return None;
        }
    };
    let tag = match tagged_file.primary_tag().or_else(|| tagged_file.first_tag()) {
        Some(t) => t,
        None => {
            log_to_dart("lofty: no primary/first tag found".to_string());
            return None;
        }
    };
    // 遍历所有 ItemKey::Lyrics（可能有多个 USLT/LYRICS 帧）
    for item in tag.get_items(&ItemKey::Lyrics) {
        if let Some(lyric) = item.value().text() {
            let text = lyric.to_string();
            if !text.trim().is_empty() {
                return Some(text);
            }
            log_to_dart("lofty: lyric text is empty".to_string());
        } else {
            log_to_dart("lofty: lyric value text() returned None".to_string());
        }
    }

    log_to_dart("lofty: no ItemKey::Lyrics found, scanning all items".to_string());

    // fallback: 遍历所有 tag item，寻找可能包含歌词的字段
    for item in tag.items() {
        let key_str = format!("{:?}", item.key());
        // 跳过常见的非歌词字段
        if key_str.to_lowercase().contains("picture")
            || key_str.to_lowercase().contains("cover")
        {
            continue;
        }
        if let Some(val) = item.value().text() {
            let text = val.to_string().trim().to_string();
            if text.is_empty() {
                continue;
            }
            // 判断是否像歌词：包含时间戳标记 [mm:ss 或包含换行符
            let has_timestamp = text.contains('[') && (text.contains(':') || text.contains('.'));
            let has_newlines = text.contains('\n');
            if has_timestamp || has_newlines {
                log_to_dart(format!(
                    "lofty: found lyric-like content in key={:?}, len={}",
                    item.key(),
                    text.len()
                ));
                return Some(text);
            }
        }
    }
    log_to_dart("lofty: no lyric-like content found in any tag item".to_string());
    None
}

fn _get_lyric_from_lrc_file(path: &str) -> anyhow::Result<String> {
    let mut lrc_file_path = PathBuf::from(path);
    lrc_file_path.set_extension("lrc");

    let lrc_bytes = fs::read(lrc_file_path)?;

    let is_le = lrc_bytes.starts_with(&[0xFF, 0xFE]);
    let is_utf16 = (is_le || lrc_bytes.starts_with(&[0xFE, 0xFF])) && lrc_bytes.len() % 2 == 0;

    if is_utf16 {
        let convert_fn = match is_le {
            true => u16::from_le_bytes,
            false => u16::from_be_bytes,
        };

        let mut u16_bytes: Vec<u16> = vec![];
        let mut chunk_iter = lrc_bytes.chunks_exact(2);
        chunk_iter.next();

        for chunk in chunk_iter {
            u16_bytes.push(convert_fn([chunk[0], chunk[1]]));
        }
        Ok(String::from_utf16(&u16_bytes)?)
    } else {
        Ok(String::from_utf8(lrc_bytes)?)
    }
}

/// for Flutter   
/// 只支持读取 ID3V2, VorbisComment, Mp4Ilst 存储的内嵌歌词
/// 以及相同目录相同文件名的 .lrc 外挂歌词（utf-8 or utf-16）
pub fn get_lyric_from_path(path: String) -> Option<String> {
    _get_lyric_from_lofty(&path).or_else(|| match _get_lyric_from_lrc_file(&path) {
        Ok(val) => Some(val),
        Err(err) => {
            log_to_dart(format!("fail to get lrc: {err}"));
            None
        }
    })
}

/// for Flutter
/// 写入歌词到音频文件标签（ID3/VorbisComment/MP4 等），使用 Lofty 的 `ItemKey::Lyrics` 映射
/// 使用 ParsingMode::Relaxed 兼容更多有问题的标签文件
pub fn write_lyric_to_path(path: String, lyric: String) -> Result<(), String> {
    let path_ref = Path::new(&path);
    let options = ParseOptions::new()
        .parsing_mode(ParsingMode::Relaxed)
        .read_cover_art(true)
        .read_properties(false)
        .read_tags(true);

    let mut tagged_file = match Probe::open(path_ref) {
        Ok(v) => match v.options(options).read() {
            Ok(f) => f,
            Err(err) => return Err(format!("Error reading file: {:?}", err.kind())),
        },
        Err(err) => return Err(format!("Error opening file: {:?}", err.kind())),
    };

    let tag = if let Some(tag) = tagged_file.primary_tag_mut() {
        tag
    } else if let Some(tag) = tagged_file.first_tag_mut() {
        tag
    } else {
        let tag_type = tagged_file.primary_tag_type();
        tagged_file.insert_tag(Tag::new(tag_type));
        if let Some(tag) = tagged_file.primary_tag_mut() {
            tag
        } else if let Some(tag) = tagged_file.first_tag_mut() {
            tag
        } else {
            return Err("failed to create tag".to_string());
        }
    };

    tag.insert_text(ItemKey::Lyrics, lyric);
    tagged_file
        .save_to_path(&path, WriteOptions::default())
        .map_err(|e| format!("Error saving lyrics: {:?}", e.kind()))?;
    Ok(())
}

/// 递归计数所有子目录（含自身）。
fn count_subdirs(folder: impl AsRef<Path>, count: &mut u64, seen: &mut HashSet<String>) {
    let folder_str = folder.as_ref().to_string_lossy().to_string();
    if !seen.insert(folder_str) {
        return;
    }
    *count += 1;
    if let Ok(dir) = fs::read_dir(folder.as_ref()) {
        for entry in dir.flatten() {
            if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                count_subdirs(entry.path(), count, seen);
            }
        }
    }
}

/// for Flutter  
/// 扫描给定路径下所有子文件夹（包括自己）的音乐文件并把索引保存在 index_path/index.json。
pub fn build_index_from_folders_recursively(
    folders: Vec<String>,
    index_path: String,
    sink: StreamSink<IndexActionState>,
) -> Result<(), io::Error> {
    let index_dir = PathBuf::from(&index_path);
    let mut audio_folders: Vec<AudioFolder> = vec![];
    let mut scanned: u64 = 0;
    let mut seen: HashSet<String> = HashSet::new();
    let mut total: u64 = 0;
    for item in &folders {
        count_subdirs(Path::new(item), &mut total, &mut seen);
    }
    let mut scanned_folders: HashSet<String> = HashSet::new();

    for item in &folders {
        let _ = AudioFolder::read_from_folder_recursively(
            Path::new(item),
            &mut audio_folders,
            &mut scanned,
            &mut total,
            &mut scanned_folders,
            &sink,
        );
    }

    let mut audio_folders_json: Vec<serde_json::Value> = vec![];
    for item in &audio_folders {
        audio_folders_json.push(item.to_json_value());
    }
    let json_value = serde_json::json!({
        "version": 110,
        "folders": audio_folders_json,
    });

    let mut index_path = PathBuf::from(index_path);
    index_path.push("index.json");
    fs::File::create(index_path)?.write_all(json_value.to_string().as_bytes())?;

    if let Err(err) = library_db::write_index_value_to_sqlite(&index_dir, &json_value) {
        log_to_dart(format!("sqlite index write failed: {}", err));
    }

    Ok(())
}

fn _update_index_below_1_1_0(
    index: &serde_json::Value,
    index_path: &PathBuf,
    sink: &StreamSink<IndexActionState>,
) -> Result<(), io::Error> {
    let mut audio_folders_json: Vec<serde_json::Value> = vec![];
    let folders = index.as_array().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "index is not an array"))?;
    for item in folders {
        let path = item["path"].as_str().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing 'path' field"))?;
        let _ = sink.add(IndexActionState {
            progress: audio_folders_json.len() as f64 / folders.len() as f64,
            message: String::from("正在扫描 ") + path,
        });
        let folder_path = Path::new(path);
        if let Ok(audio_folder) = AudioFolder::read_from_folder(folder_path) {
            audio_folders_json.push(audio_folder.to_json_value());
            let _ = sink.add(IndexActionState {
                progress: audio_folders_json.len() as f64 / folders.len() as f64,
                message: String::new(),
            });
        }
    }
    fs::File::create(index_path)?.write_all(
        serde_json::json!({
            "version": 110,
            "folders": audio_folders_json,
        })
        .to_string()
        .as_bytes(),
    )?;

    if let Some(index_dir) = index_path.parent() {
        if let Err(err) =
            library_db::migrate_index_json_to_sqlite(index_dir.to_string_lossy().to_string())
        {
            log_to_dart(format!("sqlite index migrate failed: {}", err));
        }
    }

    Ok(())
}

fn discover_new_audio_folders(
    root: &Path,
    existing_paths: &HashSet<String>,
    new_entries: &mut Vec<serde_json::Value>,
    scanned: &mut HashSet<String>,
) {
    let dir_str = root.to_string_lossy().to_string();
    if !scanned.insert(dir_str.clone()) {
        return;
    }

    if !existing_paths.contains(&dir_str) {
        if let Ok(audio_folder) = AudioFolder::read_from_folder(root) {
            new_entries.push(audio_folder.to_json_value());
            return;
        }
    }

    if let Ok(entries) = fs::read_dir(root) {
        for entry in entries.flatten() {
            if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                discover_new_audio_folders(
                    &entry.path(),
                    existing_paths,
                    new_entries,
                    scanned,
                );
            }
        }
    }
}

fn add_missing_audio_files(folder_path: &str, audios: &mut Vec<serde_json::Value>, latest: u64) -> u64 {
    let existing_audio_paths: HashSet<String> = audios
        .iter()
        .filter_map(|item| item["path"].as_str().map(|path| path.to_string()))
        .collect();
    let mut new_latest = latest;
    let dir = match fs::read_dir(folder_path) {
        Ok(value) => value,
        Err(_) => return new_latest,
    };
    for entry in dir {
        let entry = match entry {
            Ok(value) => value,
            Err(_) => continue,
        };
        let file_type = match entry.file_type() {
            Ok(value) => value,
            Err(_) => continue,
        };
        if file_type.is_dir() {
            continue;
        }

        let entry_path = entry.path().to_string_lossy().to_string();
        if existing_audio_paths.contains(&entry_path) {
            continue;
        }

        if let Some(new_audio) = Audio::read_from_path(entry.path()) {
            if new_audio.created > new_latest {
                new_latest = new_audio.created;
            }
            audios.push(new_audio.to_json_value());
        }
    }
    new_latest
}

/// for Flutter   
/// 读取 index_path/index.json，检查更新。不可能重新读取被修改的文件夹下所有的音乐标签，这样太耗时。  
///
/// [LOWEST_VERSION] 指定可以继承的 index 的最低版本。
/// 如果 index version < [LOWEST_VERSION] 或者是 index 根本没有 version 再或者格式不符合要求，就转到
/// [_update_index_below_1_1_0] 更新 index；
/// 如果 index version >= [LOWEST_VERSION] 则进行更新。
///
/// 如果文件夹不存在，删除记录。  
/// 如果文件夹被修改（再次读取到的 modified > 记录的 modified），就更新它。没有则跳过它
/// 1. 遍历该文件夹索引，判断文件是否存在，不存在则删除记录
/// 2. 遍历该文件夹索引，如果文件被修改（再次读取到的 modified > 记录的 modified），重新读取标签；没有则跳过它
/// 3. 遍历该文件夹，添加索引中不存在的音乐文件
pub fn update_index(index_path: String, sink: StreamSink<IndexActionState>) -> anyhow::Result<()> {
    let index_dir = PathBuf::from(&index_path);
    let mut index_path = PathBuf::from(index_path);
    index_path.push("index.json");
    let index = fs::read(&index_path)?;
    let mut index: serde_json::Value = serde_json::from_slice(&index)?;

    let version = index["version"].as_u64();
    if version.is_none() {
        return Ok(_update_index_below_1_1_0(&index, &index_path, &sink)?);
    }

    let folders = index["folders"].as_array_mut().ok_or_else(|| anyhow::anyhow!("missing 'folders' field"))?;
    // 删除访问不到的文件夹的记录
    folders.retain(|item| {
        let path = match item["path"].as_str() {
            Some(p) => p,
            None => return false,
        };

        Path::new(path).exists()
    });

    let mut updated = 0;
    let total = folders.len();

    for folder_item in folders.iter_mut() {
        let folder_path = match folder_item["path"].as_str() {
            Some(p) => p.to_string(),
            None => continue,
        };
        let latest = folder_item["latest"].as_u64().unwrap_or(0);
        let old_folder_modified = folder_item["modified"].as_u64().unwrap_or(0);

        // 始终清理已不存在的文件，不依赖文件夹修改时间
        {
            let audios = match folder_item["audios"].as_array_mut() {
                Some(a) => a,
                None => continue,
            };
            audios.retain(|item| {
                let path = match item["path"].as_str() {
                    Some(p) => p,
                    None => return false,
                };
                Path::new(path).exists()
            });
        }

        let new_folder_modified = match fs::metadata(&folder_path) {
            Ok(value) => match value.modified() {
                Ok(value) => value
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or(Duration::ZERO)
                    .as_secs(),
                Err(_) => continue,
            },
            Err(_) => continue,
        };

        // 文件夹未被修改时不重读旧标签，但仍检查新增文件
        if new_folder_modified <= old_folder_modified {
            if let Some(audios) = folder_item["audios"].as_array_mut() {
                let new_latest = add_missing_audio_files(&folder_path, audios, latest);
                folder_item["latest"] = serde_json::json!(new_latest);
            }
            updated += 1;
            continue;
        }

        let _ = sink.add(IndexActionState {
            progress: updated as f64 / total as f64,
            message: String::from("正在更新 ") + &folder_path,
        });

        folder_item["modified"] = serde_json::json!(new_folder_modified);

        let audios = match folder_item["audios"].as_array_mut() {
            Some(a) => a,
            None => continue,
        };
        for audio_item in &mut *audios {
            let old_audio_modified = audio_item["modified"].as_u64().unwrap_or(0);
            let audio_path = match audio_item["path"].as_str() {
                Some(p) => p,
                None => continue,
            };
            let new_audio_modified = match fs::metadata(audio_path) {
                Ok(value) => match value.modified() {
                    Ok(value) => value
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or(Duration::ZERO)
                        .as_secs(),
                    Err(_) => continue,
                },
                Err(_) => continue,
            };
            // 跳过没有被修改的文件
            if new_audio_modified <= old_audio_modified {
                continue;
            }

            // 重新读取被修改的音乐文件的标签并更新
            if let Some(modified_audio) = Audio::read_from_path(Path::new(audio_path)) {
                *audio_item = modified_audio.to_json_value();
            }
        }

        // 添加新增的音乐文件
        let new_latest = add_missing_audio_files(&folder_path, audios, latest);
        folder_item["latest"] = serde_json::json!(new_latest);

        updated += 1;
        let _ = sink.add(IndexActionState {
            progress: updated as f64 / total as f64,
            message: String::new(),
        });
    }

    // 发现未索引的新增子文件夹
    {
        let existing_paths: HashSet<String> = folders
            .iter()
            .filter_map(|f| f.get("path").and_then(|v| v.as_str()).map(String::from))
            .collect();
        let mut new_entries: Vec<serde_json::Value> = Vec::new();
        let mut scanned_dirs: HashSet<String> = HashSet::new();
        // 从每个已知文件夹根部递归查找
        for folder_item in folders.iter() {
            if let Some(root_path) = folder_item["path"].as_str() {
                let _ = sink.add(IndexActionState {
                    progress: 0.0,
                    message: format!("正在检查新增文件夹 {}", root_path),
                });
                discover_new_audio_folders(
                    Path::new(root_path),
                    &existing_paths,
                    &mut new_entries,
                    &mut scanned_dirs,
                );
            }
        }
        folders.extend(new_entries);
    }

    fs::File::create(index_path)?.write_all(index.to_string().as_bytes())?;

    if let Err(err) = library_db::write_index_value_to_sqlite(&index_dir, &index) {
        log_to_dart(format!("sqlite index write failed: {}", err));
    }

    Ok(())
}
