use std::{
    collections::{HashMap, HashSet, VecDeque},
    fs::{self},
    io::{self, Cursor},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc, Mutex, OnceLock,
    },
    time::{Duration, UNIX_EPOCH},
};

use dsf_meta::DsfFile;
use flutter_rust_bridge::frb;
use id3::TagLike;
use image::imageops;
use lofty::config::{ParseOptions, ParsingMode, WriteOptions};
use lofty::prelude::{Accessor, AudioFile, ItemKey, TaggedFileExt};
use lofty::probe::Probe;
use lofty::tag::{ItemValue, Tag, TagItem, TagType};
use midly::{Format as MidiFormat, MetaMessage, Smf, Timing, TrackEventKind};
use ndsd_read::{dff_reader::DFFReader, DSDFormat, DSDReader};
use ratag::tag::{Basic as RatagBasic, Picture as RatagPicture};
use symphonia::{
    core::{
        codecs::CodecParameters,
        formats::{probe::Hint, Attachment, FormatOptions, TrackType},
        io::MediaSourceStream,
        meta::{MetadataContainer, MetadataOptions, RawValue, StandardTag, Tag as SymphoniaTag},
        units::Timestamp,
    },
    default::get_probe,
};
use windows::{
    core::Interface,
    core::HSTRING,
    Storage::{
        FileProperties::ThumbnailMode,
        StorageFile,
        Streams::{DataReader, IInputStream},
    },
    Win32::System::WinRT::{RoInitialize, RoUninitialize, RO_INIT_MULTITHREADED},
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

#[derive(Clone, Copy)]
struct DsfAudioProperties {
    duration: u64,
    bitrate: Option<u32>,
    sample_rate: Option<u32>,
    channels: Option<u8>,
    bit_depth: Option<u8>,
}

fn is_dsf_path(path: &Path) -> bool {
    path.extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("dsf"))
}

fn is_dff_path(path: &Path) -> bool {
    path.extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("dff"))
}

fn is_asf_path(path: &Path) -> bool {
    path.extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("asf") || ext.eq_ignore_ascii_case("wma"))
}

fn is_midi_path(path: &Path) -> bool {
    path.extension().is_some_and(|ext| {
        ext.eq_ignore_ascii_case("mid")
            || ext.eq_ignore_ascii_case("midi")
            || ext.eq_ignore_ascii_case("kar")
            || ext.eq_ignore_ascii_case("rmi")
    })
}

fn is_generic_id3_path(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| ext.to_ascii_lowercase())
        .is_some_and(|ext| matches!(ext.as_str(), "ac3" | "a52" | "amr" | "3ga"))
}

fn file_name(path: &Path) -> Option<String> {
    path.file_name()
        .map(|name| name.to_string_lossy().to_string())
}

fn estimated_bitrate(path: &Path, duration: u64) -> Option<u32> {
    if duration == 0 {
        return None;
    }
    fs::metadata(path)
        .ok()
        .map(|metadata| metadata.len().saturating_mul(8) / duration / 1000)
        .and_then(|value| u32::try_from(value).ok())
}

fn optional_nonempty(value: Option<String>) -> Option<String> {
    value.filter(|value| !value.trim().is_empty())
}

fn unknown_if_empty(value: Option<String>) -> String {
    optional_nonempty(value).unwrap_or_else(|| "UNKNOWN".to_string())
}

fn read_id3_from_bytes(bytes: &[u8]) -> Option<id3::Tag> {
    id3::Tag::read_from2(Cursor::new(bytes)).ok()
}

fn read_dsf_audio_properties(file: &DsfFile) -> DsfAudioProperties {
    let fmt = file.fmt_chunk();
    let sample_rate = fmt.sampling_frequency();
    let channels = fmt.channel_num();
    let bit_depth = fmt.bits_per_sample();
    let duration = if sample_rate == 0 {
        0
    } else {
        fmt.sample_count() / u64::from(sample_rate)
    };
    let bitrate = sample_rate
        .checked_mul(channels)
        .and_then(|value| value.checked_mul(bit_depth))
        .map(|value| value / 1000);

    DsfAudioProperties {
        duration,
        bitrate,
        sample_rate: (sample_rate > 0).then_some(sample_rate),
        channels: u8::try_from(channels).ok(),
        bit_depth: u8::try_from(bit_depth).ok(),
    }
}

fn read_by_dsf(path: &Path, modified: u64, created: u64) -> Option<Audio> {
    let file = DsfFile::open(path).ok()?;
    let tag = file.id3_tag().as_ref();
    let properties = read_dsf_audio_properties(&file);
    let title = tag
        .and_then(|tag| tag.title().map(str::to_string))
        .or_else(|| file_name(path))?;

    Some(Audio {
        title,
        artist: unknown_if_empty(tag.and_then(|tag| tag.artist().map(str::to_string))),
        album: unknown_if_empty(tag.and_then(|tag| tag.album().map(str::to_string))),
        album_artist: tag.and_then(|tag| tag.album_artist().map(str::to_string)),
        track: tag.and_then(|tag| tag.track()),
        disc: tag.and_then(|tag| tag.disc()),
        duration: properties.duration,
        bitrate: properties.bitrate,
        sample_rate: properties.sample_rate,
        path: path.to_string_lossy().to_string(),
        modified,
        created,
        by: Some("DSF".to_string()),
    })
}

fn read_by_asf(path: &Path, modified: u64, created: u64) -> Option<Audio> {
    let metadata = RatagBasic::from_file(path).ok()?;
    let windows = Audio::read_by_win_music_properties(path, modified, created).ok();
    let artist = join_deduped(metadata.artists.iter().map(String::as_str));
    Some(Audio {
        title: metadata
            .title
            .or_else(|| windows.as_ref().map(|value| value.title.clone()))
            .or_else(|| file_name(path))?,
        artist: unknown_if_empty((!artist.is_empty()).then_some(artist)),
        album: unknown_if_empty(
            metadata
                .album
                .or_else(|| windows.as_ref().map(|value| value.album.clone())),
        ),
        album_artist: metadata.album_artist,
        track: metadata.track,
        disc: metadata.disc,
        duration: metadata
            .length
            .map(|value| value.as_secs())
            .or_else(|| windows.as_ref().map(|value| value.duration))
            .unwrap_or(0),
        bitrate: windows.as_ref().and_then(|value| value.bitrate),
        sample_rate: windows.as_ref().and_then(|value| value.sample_rate),
        path: path.to_string_lossy().to_string(),
        modified,
        created,
        by: Some("ratag".to_string()),
    })
}

fn id3_tag_items(tag: &id3::Tag) -> Vec<(String, String)> {
    let mut items = Vec::new();
    let mut push = |key: &str, value: Option<String>| {
        if let Some(value) = optional_nonempty(value) {
            items.push((key.to_string(), value));
        }
    };
    push("year", tag.year().map(|value| value.to_string()));
    push("genre", tag.genre().map(str::to_string));
    push(
        "comment",
        tag.comments().next().map(|value| value.text.clone()),
    );
    push("track", tag.track().map(|value| value.to_string()));
    push("disc", tag.disc().map(|value| value.to_string()));
    push(
        "copyright",
        tag.get("TCOP")
            .and_then(|frame| frame.content().text())
            .map(str::to_string),
    );
    push(
        "composer",
        tag.get("TCOM")
            .and_then(|frame| frame.content().text())
            .map(str::to_string),
    );
    push("album_artist", tag.album_artist().map(str::to_string));
    items
}

fn read_by_id3(path: &Path, modified: u64, created: u64) -> Option<Audio> {
    let tag = id3::Tag::read_from_path(path).ok()?;
    let windows = Audio::read_by_win_music_properties(path, modified, created).ok();
    Some(Audio {
        title: tag
            .title()
            .map(str::to_string)
            .or_else(|| windows.as_ref().map(|value| value.title.clone()))
            .or_else(|| file_name(path))?,
        artist: unknown_if_empty(
            tag.artist()
                .map(str::to_string)
                .or_else(|| windows.as_ref().map(|value| value.artist.clone())),
        ),
        album: unknown_if_empty(
            tag.album()
                .map(str::to_string)
                .or_else(|| windows.as_ref().map(|value| value.album.clone())),
        ),
        album_artist: tag.album_artist().map(str::to_string),
        track: tag.track(),
        disc: tag.disc(),
        duration: windows.as_ref().map(|value| value.duration).unwrap_or(0),
        bitrate: windows.as_ref().and_then(|value| value.bitrate),
        sample_rate: windows.as_ref().and_then(|value| value.sample_rate),
        path: path.to_string_lossy().to_string(),
        modified,
        created,
        by: Some("ID3".to_string()),
    })
}

struct MidiMetadata {
    title: Option<String>,
    duration: u64,
    items: Vec<(String, String)>,
}

fn midi_text(value: &[u8]) -> Option<String> {
    optional_nonempty(Some(String::from_utf8_lossy(value).trim().to_string()))
}

fn midi_track_info(track: &[midly::TrackEvent<'_>]) -> (u64, Vec<(u64, u32)>, Vec<String>) {
    let mut ticks = 0_u64;
    let mut tempos = Vec::new();
    let mut names = Vec::new();
    for event in track {
        ticks = ticks.saturating_add(u64::from(event.delta.as_int()));
        if let TrackEventKind::Meta(meta) = event.kind {
            match meta {
                MetaMessage::Tempo(value) => tempos.push((ticks, value.as_int())),
                MetaMessage::TrackName(value) => {
                    if let Some(value) = midi_text(value) {
                        names.push(value);
                    }
                }
                _ => {}
            }
        }
    }
    (ticks, tempos, names)
}

fn midi_metrical_micros(ticks: u64, mut tempos: Vec<(u64, u32)>, ticks_per_beat: u32) -> u128 {
    if ticks == 0 || ticks_per_beat == 0 {
        return 0;
    }
    tempos.sort_unstable_by_key(|(tick, _)| *tick);
    let mut elapsed_micros = 0_u128;
    let mut previous_tick = 0_u64;
    let mut tempo = 500_000_u32;
    for (tempo_tick, next_tempo) in tempos {
        if tempo_tick > ticks {
            break;
        }
        elapsed_micros = elapsed_micros.saturating_add(
            u128::from(tempo_tick.saturating_sub(previous_tick)) * u128::from(tempo)
                / u128::from(ticks_per_beat),
        );
        previous_tick = tempo_tick;
        tempo = next_tempo.max(1);
    }
    elapsed_micros = elapsed_micros.saturating_add(
        u128::from(ticks.saturating_sub(previous_tick)) * u128::from(tempo)
            / u128::from(ticks_per_beat),
    );
    elapsed_micros
}

fn midi_track_micros(ticks: u64, tempos: Vec<(u64, u32)>, timing: Timing) -> u128 {
    match timing {
        Timing::Metrical(ticks_per_beat) => {
            midi_metrical_micros(ticks, tempos, u32::from(ticks_per_beat.as_int()))
        }
        Timing::Timecode(fps, ticks_per_frame) => {
            if ticks_per_frame == 0 {
                0
            } else {
                (ticks as f64 * 1_000_000.0
                    / (f64::from(fps.as_f32()) * f64::from(ticks_per_frame)))
                    as u128
            }
        }
    }
}

fn read_midi_metadata(path: &Path) -> Option<MidiMetadata> {
    let bytes = fs::read(path).ok()?;
    parse_midi_metadata(&bytes)
}

fn midi_payload(bytes: &[u8]) -> Option<&[u8]> {
    if bytes.starts_with(b"MThd") {
        return Some(bytes);
    }
    if bytes.len() < 12 || !bytes.starts_with(b"RIFF") || &bytes[8..12] != b"RMID" {
        return None;
    }
    let riff_size = u32::from_le_bytes(bytes[4..8].try_into().ok()?) as usize;
    let riff_end = 8_usize.checked_add(riff_size)?.min(bytes.len());
    let mut offset = 12_usize;
    while offset.checked_add(8)? <= riff_end {
        let chunk_size =
            u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().ok()?) as usize;
        let data_start = offset + 8;
        let data_end = data_start.checked_add(chunk_size)?;
        if data_end > riff_end {
            return None;
        }
        if &bytes[offset..offset + 4] == b"data" {
            return Some(&bytes[data_start..data_end]);
        }
        offset = data_end.checked_add(chunk_size & 1)?;
    }
    None
}

fn parse_midi_metadata(bytes: &[u8]) -> Option<MidiMetadata> {
    let smf = Smf::parse(midi_payload(bytes)?).ok()?;
    let mut track_info = Vec::with_capacity(smf.tracks.len());
    let mut title = None;
    let mut items = Vec::new();
    for track in &smf.tracks {
        let (ticks, tempos, names) = midi_track_info(track);
        if title.is_none() {
            title = names.first().cloned();
        }
        for name in names {
            items.push(("track_name".to_string(), name));
        }
        for event in track {
            if let TrackEventKind::Meta(meta) = event.kind {
                let (key, value) = match meta {
                    MetaMessage::Copyright(value) => ("copyright", midi_text(value)),
                    MetaMessage::Text(value) => ("text", midi_text(value)),
                    MetaMessage::InstrumentName(value) => ("instrument", midi_text(value)),
                    _ => continue,
                };
                if let Some(value) = value {
                    items.push((key.to_string(), value));
                }
            }
        }
        track_info.push((ticks, tempos));
    }
    let duration_micros = match smf.header.format {
        MidiFormat::Sequential => track_info
            .into_iter()
            .map(|(ticks, tempos)| midi_track_micros(ticks, tempos, smf.header.timing))
            .sum(),
        MidiFormat::SingleTrack | MidiFormat::Parallel => {
            let max_ticks = track_info
                .iter()
                .map(|(ticks, _)| *ticks)
                .max()
                .unwrap_or(0);
            let tempos = track_info
                .into_iter()
                .flat_map(|(_, tempos)| tempos)
                .collect();
            midi_track_micros(max_ticks, tempos, smf.header.timing)
        }
    };
    let duration = u64::try_from(duration_micros / 1_000_000).unwrap_or(u64::MAX);
    Some(MidiMetadata {
        title,
        duration,
        items,
    })
}

fn read_by_midi(path: &Path, modified: u64, created: u64) -> Option<Audio> {
    let metadata = read_midi_metadata(path)?;
    Some(Audio {
        title: metadata.title.or_else(|| file_name(path))?,
        artist: "UNKNOWN".to_string(),
        album: "UNKNOWN".to_string(),
        album_artist: None,
        track: None,
        disc: None,
        duration: metadata.duration,
        bitrate: estimated_bitrate(path, metadata.duration),
        sample_rate: None,
        path: path.to_string_lossy().to_string(),
        modified,
        created,
        by: Some("midly".to_string()),
    })
}

struct DffMetadata {
    title: Option<String>,
    artist: Option<String>,
    album: Option<String>,
    album_artist: Option<String>,
    track: Option<u32>,
    disc: Option<u32>,
    duration: u64,
    bitrate: Option<u32>,
    sample_rate: Option<u32>,
    channels: Option<u8>,
    picture: Option<Vec<u8>>,
    items: Vec<(String, String)>,
}

fn read_dff_metadata(path: &Path) -> Option<DffMetadata> {
    let path_string = path.to_string_lossy();
    let mut reader = DFFReader::new(&path_string).ok()?;
    let mut format = DSDFormat::default();
    reader.open(&mut format).ok()?;
    let dsd_metadata = reader.get_metadata();
    let id3_tag = dsd_metadata
        .and_then(|metadata| metadata.id3_raw.as_deref())
        .and_then(read_id3_from_bytes);
    let id3_tag = id3_tag.as_ref();
    let duration = if format.sampling_rate == 0 {
        0
    } else {
        format.total_samples.saturating_mul(8) / u64::from(format.sampling_rate)
    };
    let title = id3_tag
        .and_then(|tag| tag.title().map(str::to_string))
        .or_else(|| dsd_metadata.and_then(|metadata| metadata.title.clone()));
    let artist = id3_tag
        .and_then(|tag| tag.artist().map(str::to_string))
        .or_else(|| dsd_metadata.and_then(|metadata| metadata.artist.clone()));
    let album = id3_tag
        .and_then(|tag| tag.album().map(str::to_string))
        .or_else(|| dsd_metadata.and_then(|metadata| metadata.album.clone()));
    let album_artist = id3_tag.and_then(|tag| tag.album_artist().map(str::to_string));
    let picture = id3_tag
        .and_then(|tag| tag.pictures().next().map(|picture| picture.data.clone()))
        .or_else(|| {
            dsd_metadata.and_then(|metadata| {
                metadata
                    .cover_art
                    .first()
                    .map(|picture| picture.data.clone())
            })
        });
    let mut items = Vec::new();
    let mut push_item = |key: &str, value: Option<String>| {
        if let Some(value) = optional_nonempty(value) {
            items.push((key.to_string(), value));
        }
    };
    push_item(
        "year",
        id3_tag
            .and_then(|tag| tag.year())
            .or_else(|| dsd_metadata.and_then(|metadata| metadata.year.map(|year| year as i32)))
            .map(|value| value.to_string()),
    );
    push_item(
        "genre",
        id3_tag
            .and_then(|tag| tag.genre().map(str::to_string))
            .or_else(|| dsd_metadata.and_then(|metadata| metadata.genre.clone())),
    );
    push_item("artist", artist.clone());
    push_item("album_artist", album_artist.clone());
    push_item(
        "track",
        id3_tag
            .and_then(|tag| tag.track())
            .map(|value| value.to_string()),
    );
    push_item(
        "disc",
        id3_tag
            .and_then(|tag| tag.disc())
            .map(|value| value.to_string()),
    );

    Some(DffMetadata {
        title,
        artist,
        album,
        album_artist,
        track: id3_tag.and_then(|tag| tag.track()),
        disc: id3_tag.and_then(|tag| tag.disc()),
        duration,
        bitrate: estimated_bitrate(path, duration),
        sample_rate: (format.sampling_rate > 0).then_some(format.sampling_rate),
        channels: u8::try_from(format.num_channels).ok(),
        picture,
        items,
    })
}

fn read_by_dff(path: &Path, modified: u64, created: u64) -> Option<Audio> {
    let metadata = read_dff_metadata(path)?;
    Some(Audio {
        title: metadata.title.or_else(|| file_name(path))?,
        artist: unknown_if_empty(metadata.artist),
        album: unknown_if_empty(metadata.album),
        album_artist: metadata.album_artist,
        track: metadata.track,
        disc: metadata.disc,
        duration: metadata.duration,
        bitrate: metadata.bitrate,
        sample_rate: metadata.sample_rate,
        path: path.to_string_lossy().to_string(),
        modified,
        created,
        by: Some("DFF".to_string()),
    })
}

fn parse_alternative_number(value: &str) -> Option<u32> {
    value.split('/').next()?.trim().parse().ok()
}

struct SymphoniaMetadata {
    title: Option<String>,
    artist: Option<String>,
    album: Option<String>,
    album_artist: Option<String>,
    track: Option<u32>,
    disc: Option<u32>,
    duration: u64,
    bitrate: Option<u32>,
    sample_rate: Option<u32>,
    channels: Option<u8>,
    picture: Option<Vec<u8>>,
    items: Vec<(String, String)>,
}

fn is_symphonia_path(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|ext| ext.to_str())
            .map(|ext| ext.to_ascii_lowercase())
            .as_deref(),
        Some("mp1")
            | Some("mp2")
            | Some("mpa")
            | Some("ogg")
            | Some("oga")
            | Some("opus")
            | Some("spx")
            | Some("mka")
            | Some("mkv")
            | Some("webm")
            | Some("weba")
            | Some("caf")
            | Some("mp4")
            | Some("m4a")
            | Some("m4b")
            | Some("m4p")
            | Some("m4r")
            | Some("m4v")
            | Some("3gp")
            | Some("3g2")
            | Some("flac")
            | Some("wav")
            | Some("wave")
            | Some("aif")
            | Some("aiff")
            | Some("aifc")
    )
}

fn read_by_symphonia(path: &Path, modified: u64, created: u64) -> Option<Audio> {
    let metadata = read_symphonia_metadata(path)?;
    let title = metadata.title.or_else(|| {
        path.file_name()
            .map(|name| name.to_string_lossy().to_string())
    })?;

    Some(Audio {
        title,
        artist: metadata.artist.unwrap_or_else(|| "UNKNOWN".to_string()),
        album: metadata.album.unwrap_or_else(|| "UNKNOWN".to_string()),
        album_artist: metadata.album_artist,
        track: metadata.track,
        disc: metadata.disc,
        duration: metadata.duration,
        bitrate: metadata.bitrate,
        sample_rate: metadata.sample_rate,
        path: path.to_string_lossy().to_string(),
        modified,
        created,
        by: Some("Symphonia".to_string()),
    })
}

fn symphonia_raw_value(value: &RawValue) -> Option<String> {
    let value = match value {
        RawValue::String(value) => value.to_string(),
        RawValue::StringList(value) => join_deduped(value.iter().map(String::as_str)),
        RawValue::SignedInt(value) => value.to_string(),
        RawValue::UnsignedInt(value) => value.to_string(),
        RawValue::Float(value) => value.to_string(),
        RawValue::Boolean(value) => value.to_string(),
        RawValue::Binary(_) | RawValue::Flag => return None,
        _ => return None,
    };
    optional_nonempty(Some(value))
}

fn symphonia_standard_value(tag: &SymphoniaTag) -> Option<(String, String)> {
    let (key, value) = match tag.std.as_ref()? {
        StandardTag::Album(value) => ("album", value.to_string()),
        StandardTag::AlbumArtist(value) => ("albumartist", value.to_string()),
        StandardTag::Artist(value) => ("artist", value.to_string()),
        StandardTag::Comment(value) => ("comment", value.to_string()),
        StandardTag::Composer(value) => ("composer", value.to_string()),
        StandardTag::Conductor(value) => ("conductor", value.to_string()),
        StandardTag::Copyright(value) => ("copyright", value.to_string()),
        StandardTag::DiscNumber(value) => ("discnumber", value.to_string()),
        StandardTag::DiscTotal(value) => ("disctotal", value.to_string()),
        StandardTag::Encoder(value) => ("encoder", value.to_string()),
        StandardTag::EncoderSettings(value) => ("encodersettings", value.to_string()),
        StandardTag::Genre(value) => ("genre", value.to_string()),
        StandardTag::Label(value) => ("label", value.to_string()),
        StandardTag::Language(value) => ("language", value.to_string()),
        StandardTag::Lyrics(value) => ("lyrics", value.to_string()),
        StandardTag::RecordingDate(value) => ("recordingdate", value.to_string()),
        StandardTag::RecordingYear(value) => ("recordingyear", value.to_string()),
        StandardTag::ReplayGainAlbumGain(value) => ("replaygain_album_gain", value.to_string()),
        StandardTag::ReplayGainAlbumPeak(value) => ("replaygain_album_peak", value.to_string()),
        StandardTag::ReplayGainTrackGain(value) => ("replaygain_track_gain", value.to_string()),
        StandardTag::ReplayGainTrackPeak(value) => ("replaygain_track_peak", value.to_string()),
        StandardTag::TrackNumber(value) => ("tracknumber", value.to_string()),
        StandardTag::TrackTitle(value) => ("title", value.to_string()),
        StandardTag::TrackTotal(value) => ("tracktotal", value.to_string()),
        _ => return None,
    };
    optional_nonempty(Some(value)).map(|value| (key.to_string(), value))
}

fn merge_symphonia_field(field: &mut Option<String>, value: String) {
    if let Some(existing) = field.take() {
        *field = Some(join_deduped([existing.as_str(), value.as_str()]));
    } else {
        *field = Some(value);
    }
}

#[derive(Default)]
#[frb(ignore)]
struct SymphoniaTagCollection {
    title: Option<String>,
    artist: Option<String>,
    album: Option<String>,
    album_artist: Option<String>,
    track_number: Option<u32>,
    disc_number: Option<u32>,
    items: Vec<(String, String)>,
    picture: Option<Vec<u8>>,
}

fn collect_symphonia_tags(container: &MetadataContainer, tags: &mut SymphoniaTagCollection) {
    for tag in &container.tags {
        let (key, value) = if let Some((key, value)) = symphonia_standard_value(tag) {
            (key, value)
        } else {
            let value = match symphonia_raw_value(&tag.raw.value) {
                Some(value) => value,
                None => continue,
            };
            (tag.raw.key.to_ascii_lowercase(), value)
        };
        tags.items.push((key.clone(), value.clone()));
        match key.as_str() {
            "title" | "tracktitle" | "tit2" | "title/trackname" | "©nam" => {
                merge_symphonia_field(&mut tags.title, value)
            }
            "artist" | "trackartist" | "tpe1" | "©art" => {
                merge_symphonia_field(&mut tags.artist, value)
            }
            "album" | "talb" | "©alb" => merge_symphonia_field(&mut tags.album, value),
            "albumartist" | "album artist" | "albumartistname" | "tpe2" | "aart" => {
                merge_symphonia_field(&mut tags.album_artist, value)
            }
            "track" | "tracknumber" | "trck" | "trkn" => {
                tags.track_number = parse_alternative_number(&value);
            }
            "disc" | "discnumber" | "tpos" | "disk" => {
                tags.disc_number = parse_alternative_number(&value);
            }
            _ => {}
        }
    }
    if tags.picture.is_none() {
        tags.picture = container
            .visuals
            .iter()
            .find(|visual| !visual.data.is_empty())
            .map(|visual| visual.data.to_vec());
    }
}

fn is_image_attachment(name: &str, media_type: Option<&str>) -> bool {
    media_type.is_some_and(|value| {
        value.eq_ignore_ascii_case("image/jpeg")
            || value.eq_ignore_ascii_case("image/png")
            || value.eq_ignore_ascii_case("image/webp")
    }) || Path::new(name).extension().is_some_and(|ext| {
        matches!(
            ext.to_str()
                .map(|value| value.to_ascii_lowercase())
                .as_deref(),
            Some("jpg") | Some("jpeg") | Some("png") | Some("webp")
        )
    })
}

fn read_symphonia_metadata(path: &Path) -> Option<SymphoniaMetadata> {
    let source = fs::File::open(path).ok()?;
    let media_source = MediaSourceStream::new(Box::new(source), Default::default());
    let mut hint = Hint::new();
    if let Some(extension) = path.extension().and_then(|ext| ext.to_str()) {
        hint.with_extension(extension);
    }
    let probed = get_probe()
        .probe(
            &hint,
            media_source,
            FormatOptions::default(),
            MetadataOptions::default(),
        )
        .ok()?;
    let mut format = probed;
    let (track_id, duration, sample_rate, channels) = {
        let track = format.default_track(TrackType::Audio)?;
        let audio_params = match track.codec_params.as_ref()? {
            CodecParameters::Audio(params) => params,
            _ => return None,
        };
        let duration = track
            .duration
            .zip(track.time_base)
            .and_then(|(duration, time_base)| {
                time_base
                    .calc_time(Timestamp::from(duration.get() as i64))
                    .map(|time| time.as_secs().max(0) as u64)
            })
            .or_else(|| {
                track
                    .num_frames
                    .zip(track.time_base)
                    .and_then(|(frames, time_base)| {
                        time_base
                            .calc_time(Timestamp::from(frames as i64))
                            .map(|time| time.as_secs().max(0) as u64)
                    })
            })
            .unwrap_or(0);
        (
            track.id,
            duration,
            audio_params.sample_rate,
            audio_params
                .channels
                .as_ref()
                .and_then(|value| u8::try_from(value.count()).ok()),
        )
    };
    let bitrate = estimated_bitrate(path, duration);
    let mut tags = SymphoniaTagCollection::default();

    if let Some(revision) = format.metadata().skip_to_latest() {
        collect_symphonia_tags(&revision.media, &mut tags);
        if let Some(track_metadata) = revision
            .per_track
            .iter()
            .find(|metadata| metadata.track_id == u64::from(track_id))
        {
            let mut track_tags = SymphoniaTagCollection::default();
            collect_symphonia_tags(&track_metadata.metadata, &mut track_tags);
            tags.title = track_tags.title.or(tags.title);
            tags.artist = track_tags.artist.or(tags.artist);
            tags.album = track_tags.album.or(tags.album);
            tags.album_artist = track_tags.album_artist.or(tags.album_artist);
            tags.track_number = track_tags.track_number.or(tags.track_number);
            tags.disc_number = track_tags.disc_number.or(tags.disc_number);
            tags.items.extend(track_tags.items);
            tags.picture = track_tags.picture.or(tags.picture);
        }
    }
    if tags.picture.is_none() {
        tags.picture = format
            .attachments()
            .iter()
            .find_map(|attachment| match attachment {
                Attachment::File(file)
                    if is_image_attachment(&file.name, file.media_type.as_deref()) =>
                {
                    Some(file.data.to_vec())
                }
                _ => None,
            });
    }

    Some(SymphoniaMetadata {
        title: tags.title,
        artist: tags.artist,
        album: tags.album,
        album_artist: tags.album_artist,
        track: tags.track_number,
        disc: tags.disc_number,
        duration,
        bitrate,
        sample_rate,
        channels,
        picture: tags.picture,
        items: tags.items,
    })
}

fn read_by_alternative(path: &Path, modified: u64, created: u64) -> Option<Audio> {
    if is_dsf_path(path) {
        return read_by_dsf(path, modified, created);
    }
    if is_dff_path(path) {
        return read_by_dff(path, modified, created);
    }
    if is_asf_path(path) {
        return read_by_asf(path, modified, created);
    }
    if is_midi_path(path) {
        return read_by_midi(path, modified, created);
    }
    if is_generic_id3_path(path) {
        return read_by_id3(path, modified, created);
    }
    if is_symphonia_path(path) {
        if let Some(metadata) = read_by_symphonia(path, modified, created) {
            return Some(metadata);
        }
    }
    read_by_id3(path, modified, created)
}

fn take_extra_item(items: &mut Vec<(String, String)>, key: &str) -> Option<String> {
    let index = items
        .iter()
        .position(|(item_key, _)| item_key.eq_ignore_ascii_case(key))?;
    Some(items.remove(index).1)
}

fn build_alternative_extra_metadata(
    extension: String,
    file_size: u64,
    channels: Option<u8>,
    bit_depth: Option<u8>,
    mut items: Vec<(String, String)>,
) -> AudioExtraMetadata {
    let replaygain_track_gain = take_extra_item(&mut items, "replaygain_track_gain");
    let replaygain_track_peak = take_extra_item(&mut items, "replaygain_track_peak");
    let replaygain_album_gain = take_extra_item(&mut items, "replaygain_album_gain");
    let replaygain_album_peak = take_extra_item(&mut items, "replaygain_album_peak");
    AudioExtraMetadata {
        extension,
        file_size,
        channels,
        bit_depth,
        items: items
            .into_iter()
            .map(|(key, value)| AudioExtraItem { key, value })
            .collect(),
        replaygain_track_gain,
        replaygain_track_peak,
        replaygain_album_gain,
        replaygain_album_peak,
    }
}

fn read_asf_extra_metadata(
    path: &Path,
    extension: String,
    file_size: u64,
) -> Option<AudioExtraMetadata> {
    let metadata = RatagBasic::from_file(path).ok()?;
    let mut items = Vec::new();
    let artist = join_deduped(metadata.artists.iter().map(String::as_str));
    let genre = join_deduped(metadata.genres.iter().map(String::as_str));
    for (key, value) in [
        ("artist", (!artist.is_empty()).then_some(artist)),
        ("album_artist", metadata.album_artist),
        ("genre", (!genre.is_empty()).then_some(genre)),
        ("track", metadata.track.map(|value| value.to_string())),
        ("disc", metadata.disc.map(|value| value.to_string())),
        ("year", metadata.year.map(|value| value.to_string())),
    ] {
        if let Some(value) = value {
            items.push((key.to_string(), value));
        }
    }
    Some(build_alternative_extra_metadata(
        extension, file_size, None, None, items,
    ))
}

fn read_alternative_extra_metadata(
    path: &Path,
    extension: String,
    file_size: u64,
) -> Option<AudioExtraMetadata> {
    if is_dsf_path(path) {
        return Some(read_dsf_extra_metadata(
            &path.to_string_lossy(),
            extension,
            file_size,
        ));
    }
    if is_dff_path(path) {
        let metadata = read_dff_metadata(path)?;
        return Some(build_alternative_extra_metadata(
            extension,
            file_size,
            metadata.channels,
            Some(1),
            metadata.items,
        ));
    }
    if is_asf_path(path) {
        return read_asf_extra_metadata(path, extension, file_size);
    }
    if is_midi_path(path) {
        let metadata = read_midi_metadata(path)?;
        return Some(build_alternative_extra_metadata(
            extension,
            file_size,
            None,
            None,
            metadata.items,
        ));
    }
    if is_generic_id3_path(path) {
        let tag = id3::Tag::read_from_path(path).ok()?;
        return Some(build_alternative_extra_metadata(
            extension,
            file_size,
            None,
            None,
            id3_tag_items(&tag),
        ));
    }
    if is_symphonia_path(path) {
        if let Some(metadata) = read_symphonia_metadata(path) {
            return Some(build_alternative_extra_metadata(
                extension,
                file_size,
                metadata.channels,
                None,
                metadata.items,
            ));
        }
    }
    let tag = id3::Tag::read_from_path(path).ok()?;
    Some(build_alternative_extra_metadata(
        extension,
        file_size,
        None,
        None,
        id3_tag_items(&tag),
    ))
}

fn push_dsf_item(items: &mut Vec<AudioExtraItem>, key: &str, value: Option<&str>) {
    if let Some(value) = value.filter(|value| !value.trim().is_empty()) {
        items.push(AudioExtraItem {
            key: key.to_string(),
            value: value.to_string(),
        });
    }
}

fn read_dsf_extra_metadata(path: &str, extension: String, file_size: u64) -> AudioExtraMetadata {
    let mut items = Vec::new();
    if let Ok(file) = DsfFile::open(Path::new(path)) {
        if let Some(tag) = file.id3_tag().as_ref() {
            let year = tag.year().map(|value| value.to_string());
            push_dsf_item(&mut items, "year", year.as_deref());
            push_dsf_item(&mut items, "genre", tag.genre());
            push_dsf_item(
                &mut items,
                "disc",
                tag.disc().map(|value| value.to_string()).as_deref(),
            );
            push_dsf_item(
                &mut items,
                "track",
                tag.track().map(|value| value.to_string()).as_deref(),
            );
            push_dsf_item(&mut items, "artist", tag.artist());
            push_dsf_item(&mut items, "album_artist", tag.album_artist());
        }
        let properties = read_dsf_audio_properties(&file);
        return AudioExtraMetadata {
            extension,
            file_size,
            channels: properties.channels,
            bit_depth: properties.bit_depth,
            items,
            replaygain_track_gain: None,
            replaygain_track_peak: None,
            replaygain_album_gain: None,
            replaygain_album_peak: None,
        };
    }

    AudioExtraMetadata {
        extension,
        file_size,
        channels: None,
        bit_depth: None,
        items,
        replaygain_track_gain: None,
        replaygain_track_peak: None,
        replaygain_album_gain: None,
        replaygain_album_peak: None,
    }
}

fn read_dsf_picture(path: &Path) -> Option<Vec<u8>> {
    let file = DsfFile::open(path).ok()?;
    let picture = file
        .id3_tag()
        .as_ref()?
        .pictures()
        .next()
        .map(|picture| picture.data.clone());
    picture
}

fn read_dff_picture(path: &Path) -> Option<Vec<u8>> {
    read_dff_metadata(path)?.picture
}

fn read_asf_picture(path: &Path) -> Option<Vec<u8>> {
    let pictures = RatagPicture::read_cover(path).ok()?;
    let picture = pictures.picture()?;
    (!picture.is_uri).then(|| picture.data.clone())
}

fn read_id3_picture(path: &Path) -> Option<Vec<u8>> {
    id3::Tag::read_from_path(path)
        .ok()?
        .pictures()
        .next()
        .map(|picture| picture.data.clone())
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

fn should_show_recording_date(recording_date: Option<&str>, year: Option<&str>) -> bool {
    match (recording_date, year) {
        (Some(date), Some(year)) => date.trim() != year.trim(),
        (Some(_), None) => true,
        _ => false,
    }
}

/// for Flutter
pub fn read_audio_extra_metadata(path: String) -> AudioExtraMetadata {
    let file_size = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    let extension = Path::new(&path)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string();

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

    let tagged_file = match Probe::open(&path).and_then(|p| p.options(options).read()) {
        Ok(val) => val,
        Err(err) => {
            if let Some(metadata) =
                read_alternative_extra_metadata(Path::new(&path), extension.clone(), file_size)
            {
                return metadata;
            }
            log_to_dart(format!("metadata read failed: {}", err));
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
    let channels = props.channels();
    let bit_depth = props.bit_depth();

    if let Some(tag) = tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())
    {
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
        let recording_date = tag
            .get(&ItemKey::RecordingDate)
            .and_then(|v| v.value().text());
        let year = tag
            .get(&ItemKey::Year)
            .or_else(|| tag.get(&ItemKey::RecordingDate))
            .and_then(|v| v.value().text());
        if should_show_recording_date(recording_date, year) {
            push_kv("date", recording_date);
        }
        push_kv("year", year);
        push_kv(
            "release_date",
            tag.get(&ItemKey::ReleaseDate)
                .and_then(|v| v.value().text()),
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
            tag.get(&ItemKey::EncoderSettings)
                .and_then(|v| v.value().text()),
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
            tag.get(&ItemKey::License)
                .or_else(|| tag.get(&ItemKey::Unknown("LICENSE".to_string())))
                .and_then(|v| v.value().text()),
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

static SUPPORTED_FORMATS: phf::Set<&'static str> = phf::phf_set! {
    "mp3", "mp2", "mp1", "mpa",
    "ogg", "oga", "opus", "spx",
    "wav", "wave",
    "aif", "aiff", "aifc", "afc",
    "asf", "wma",
    "aac", "adts",
    "m4a", "mp4", "m4b", "m4p", "m4r", "m4v", "3gp", "3g2",
    "mka", "mkv", "webm", "weba",
    "caf",
    "ac3", "a52",
    "amr", "3ga",
    "flac",
    "mpc", "mp+", "mpp",
    "mid", "midi", "kar", "rmi",
    "wv",
    "dsf", "dff",
    "ape",
};

const CURRENT_INDEX_VERSION: u64 = 111;
const MAX_TAG_READER_WORKERS: usize = 4;
const RESERVED_LOGICAL_CORES: usize = 2;
const INDEX_PROGRESS_MIN_BATCH: usize = 16;
const INDEX_PROGRESS_TARGET_UPDATES: usize = 200;

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
    disc: Option<u32>,
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
            disc: None,
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
            "disc": self.disc,
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
    /// 所有格式先由 Lofty 读取，再按格式使用其他解析器和 Windows API 回退。
    /// 再不能的话：title: filename 代替
    fn read_from_path(path: impl AsRef<Path>) -> Option<Self> {
        let path = path.as_ref();
        let ext_lower = path
            .extension()?
            .to_ascii_lowercase()
            .to_string_lossy()
            .to_string();
        if !SUPPORTED_FORMATS.contains(&ext_lower) {
            return None;
        }

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

        if let Some(value) = Self::read_by_lofty(path, modified, created) {
            return Some(value);
        }
        if let Some(value) = read_by_alternative(path, modified, created) {
            return Some(value);
        }
        match Self::read_by_win_music_properties(path, modified, created) {
            Ok(value) => Some(value),
            Err(err) => {
                log_to_dart(format!("metadata fallback failed: {}", err));
                let mut value = Self::new_with_path(path, None)?;
                value.modified = modified;
                value.created = created;
                Some(value)
            }
        }
    }

    /// 使用 lofty 获取音乐标签。只在文件名不正确、没有标签或包含不支持的编码时返回 None
    fn read_by_lofty(path: impl AsRef<Path>, modified: u64, created: u64) -> Option<Self> {
        let path = path.as_ref();
        let options = ParseOptions::new()
            .parsing_mode(ParsingMode::Relaxed)
            .read_tags(true)
            .read_cover_art(false)
            .read_properties(true);
        let tagged_file = match Probe::open(path).and_then(|probe| probe.options(options).read()) {
            Ok(val) => val,
            Err(err) => {
                log_to_dart(format!("metadata parse failed: {}", err));
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
                disc: tag.disk(),
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
            title: path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default(),
            artist: std::borrow::Cow::Borrowed("UNKNOWN").to_string(),
            album: std::borrow::Cow::Borrowed("UNKNOWN").to_string(),
            album_artist: None,
            track: None,
            disc: None,
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
            disc: None,
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

struct WinRtWorkerGuard;

impl WinRtWorkerGuard {
    fn initialize() -> Option<Self> {
        unsafe { RoInitialize(RO_INIT_MULTITHREADED) }
            .ok()
            .map(|_| Self)
    }
}

impl Drop for WinRtWorkerGuard {
    fn drop(&mut self) {
        unsafe { RoUninitialize() };
    }
}

fn tag_reader_worker_count_for(logical_cores: usize, job_count: usize) -> usize {
    (logical_cores.saturating_sub(RESERVED_LOGICAL_CORES) / 2)
        .max(1)
        .min(MAX_TAG_READER_WORKERS)
        .min(job_count)
}

fn tag_reader_worker_count(job_count: usize) -> usize {
    tag_reader_worker_count_for(
        std::thread::available_parallelism()
            .map(|count| count.get())
            .unwrap_or(1),
        job_count,
    )
}

fn read_audio_paths_parallel<F>(paths: &[PathBuf], mut on_progress: F) -> Vec<Option<Audio>>
where
    F: FnMut(usize),
{
    if paths.is_empty() {
        return Vec::new();
    }
    let worker_count = tag_reader_worker_count(paths.len());
    if worker_count <= 1 {
        return paths
            .iter()
            .enumerate()
            .map(|(index, path)| {
                let audio = Audio::read_from_path(path);
                on_progress(index + 1);
                audio
            })
            .collect();
    }

    let next_index = AtomicUsize::new(0);
    let (sender, receiver) = mpsc::channel();
    let mut results: Vec<Option<Audio>> =
        std::iter::repeat_with(|| None).take(paths.len()).collect();
    std::thread::scope(|scope| {
        for _ in 0..worker_count {
            let sender = sender.clone();
            let next_index = &next_index;
            scope.spawn(move || {
                let _winrt = WinRtWorkerGuard::initialize();
                loop {
                    let index = next_index.fetch_add(1, Ordering::Relaxed);
                    if index >= paths.len() {
                        break;
                    }
                    if sender
                        .send((index, Audio::read_from_path(&paths[index])))
                        .is_err()
                    {
                        break;
                    }
                }
            });
        }
        drop(sender);
        for completed in 1..=paths.len() {
            let Ok((index, audio)) = receiver.recv() else {
                break;
            };
            results[index] = audio;
            on_progress(completed);
        }
    });
    results
}

fn should_emit_index_progress(completed: usize, total: usize) -> bool {
    let batch = total
        .div_ceil(INDEX_PROGRESS_TARGET_UPDATES)
        .max(INDEX_PROGRESS_MIN_BATCH);
    completed >= total || completed.is_multiple_of(batch)
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
        let mut paths = Vec::new();
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            if entry.file_type()?.is_file() && is_supported_audio_path(&entry.path()) {
                paths.push(entry.path());
            }
        }
        let read_results = read_audio_paths_parallel(&paths, |_| {});
        if let Some(failed_index) = read_results.iter().position(Option::is_none) {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                format!("failed to read audio: {}", paths[failed_index].display()),
            ));
        }
        let audios: Vec<Audio> = read_results.into_iter().flatten().collect();
        let latest = audios.iter().map(|audio| audio.created).max().unwrap_or(0);

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

fn read_picture_by_alternative(path: &Path) -> Option<Vec<u8>> {
    if is_dsf_path(path) {
        return read_dsf_picture(path);
    }
    if is_dff_path(path) {
        return read_dff_picture(path);
    }
    if is_asf_path(path) {
        return read_asf_picture(path);
    }
    if is_generic_id3_path(path) {
        return read_id3_picture(path);
    }
    if is_symphonia_path(path) {
        if let Some(picture) = read_symphonia_metadata(path).and_then(|metadata| metadata.picture) {
            return Some(picture);
        }
    }
    read_id3_picture(path)
}

fn _get_picture_by_lofty(path: &str) -> Option<Vec<u8>> {
    let options = ParseOptions::new()
        .parsing_mode(ParsingMode::Relaxed)
        .read_tags(true)
        .read_cover_art(true)
        .read_properties(false);

    let tagged_file = match Probe::open(path).and_then(|p| p.options(options).read()) {
        Ok(f) => f,
        Err(_) => return read_picture_by_alternative(Path::new(path)),
    };

    let picture = tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())
        .and_then(|tag| tag.pictures().first())
        .map(|picture| picture.data().to_vec());

    picture.or_else(|| read_picture_by_alternative(Path::new(path)))
}

pub(crate) fn get_embedded_picture_from_path(
    path: &str,
    width: u32,
    height: u32,
) -> Option<Vec<u8>> {
    let picture = _get_picture_by_lofty(path)?;
    let loaded = image::load_from_memory(&picture).ok()?;
    let ratio = loaded.width() as f32 / loaded.height() as f32;
    let (result_width, result_height) = if ratio > 1.0 {
        (width, (width as f32 / ratio).round() as u32)
    } else {
        ((height as f32 * ratio).round() as u32, height)
    };
    let resized = imageops::resize(
        &loaded,
        result_width.max(1),
        result_height.max(1),
        imageops::FilterType::Triangle,
    );
    let mut output = Cursor::new(Vec::new());
    resized
        .write_to(&mut output, image::ImageFormat::Png)
        .ok()?;
    Some(output.into_inner())
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
    let loaded = match image::load_from_memory(&pic) {
        Ok(loaded) => loaded,
        Err(err) => {
            log_to_dart(format!("fail to decode cover: {}", err));
            return (None, vec![]);
        }
    };
    drop(pic);
    let colors = match super::color_extraction::extract_mesh_colors_from_decoded_image(
        &loaded, num_colors,
    ) {
        Ok(colors) => colors,
        Err(err) => {
            log_to_dart(format!("fail to extract colors: {}", err));
            vec![]
        }
    };
    let ratio = loaded.width() as f32 / loaded.height() as f32;
    let (rw, rh) = if ratio > 1.0 {
        (width, (width as f32 / ratio).round() as u32)
    } else {
        ((height as f32 * ratio).round() as u32, height)
    };
    let resized = image::imageops::resize(
        &loaded,
        rw.max(1),
        rh.max(1),
        image::imageops::FilterType::Triangle,
    );
    drop(loaded);
    let mut buf = std::io::Cursor::new(Vec::new());
    let resized_png = if resized.write_to(&mut buf, image::ImageFormat::Png).is_ok() {
        Some(buf.into_inner())
    } else {
        None
    };

    (resized_png, colors)
}

/// for Flutter  
/// 如果无法通过 Lofty 获取则通过 Windows 获取
pub fn get_picture_from_path(path: String, width: u32, height: u32) -> Option<Vec<u8>> {
    let cache_key = _picture_cache_key(&path, width, height);
    if let Ok(cache_lock) = PICTURE_CACHE
        .get_or_init(|| Mutex::new(VecDeque::new()))
        .lock()
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
            if resized_img
                .write_to(&mut output, image::ImageFormat::Png)
                .is_ok()
            {
                let out = output.into_inner();
                if let Ok(mut cache) = PICTURE_CACHE
                    .get_or_init(|| Mutex::new(VecDeque::new()))
                    .lock()
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

fn is_lyric_item_key(key: &ItemKey) -> bool {
    let normalized = format!("{key:?}").to_ascii_lowercase();
    normalized.contains("lyric") || normalized.contains("uslt") || normalized.contains("sylt")
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
    let tag = match tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())
    {
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

    log_to_dart("lofty: no ItemKey::Lyrics found, scanning lyric-named items".to_string());

    for item in tag.items() {
        if !is_lyric_item_key(item.key()) {
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
    log_to_dart("no lyric-like content found in any tag item".to_string());
    None
}

/// for Flutter   
/// 只读取 ID3V2、VorbisComment、Mp4Ilst 存储的内嵌歌词
pub fn get_lyric_from_path(path: String) -> Option<String> {
    _get_lyric_from_lofty(&path)
}

#[derive(Clone)]
pub struct WriteTagPayload {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub genre: Option<String>,
    pub year: Option<String>,
    pub track: Option<String>,
    pub track_total: Option<String>,
    pub disc: Option<String>,
    pub disc_total: Option<String>,
    pub composer: Option<String>,
    pub lyricist: Option<String>,
    pub label: Option<String>,
    pub comment: Option<String>,
    pub bpm: Option<String>,
    pub language: Option<String>,
    pub copyright: Option<String>,
    pub license: Option<String>,
}

/// for Flutter
/// 通用标签写入函数。only_changed=true 时只写非 None 字段
pub fn write_audio_tags(
    path: String,
    payload: WriteTagPayload,
    only_changed: bool,
) -> Result<(), String> {
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

    macro_rules! write_field {
        ($val:expr, $key:expr) => {
            if let Some(v) = &$val {
                let trimmed = v.trim().to_string();
                if trimmed.is_empty() {
                    let _ = tag.remove_key(&$key);
                } else {
                    tag.insert_text($key, trimmed);
                }
            }
        };
    }

    if !only_changed {
        let _ = tag.remove_key(&ItemKey::TrackTitle);
        let _ = tag.remove_key(&ItemKey::TrackArtist);
        let _ = tag.remove_key(&ItemKey::AlbumTitle);
        let _ = tag.remove_key(&ItemKey::AlbumArtist);
        let _ = tag.remove_key(&ItemKey::Genre);
        let _ = tag.remove_key(&ItemKey::Year);
        let _ = tag.remove_key(&ItemKey::RecordingDate);
        let _ = tag.remove_key(&ItemKey::TrackNumber);
        let _ = tag.remove_key(&ItemKey::TrackTotal);
        let _ = tag.remove_key(&ItemKey::DiscNumber);
        let _ = tag.remove_key(&ItemKey::DiscTotal);
        let _ = tag.remove_key(&ItemKey::Composer);
        let _ = tag.remove_key(&ItemKey::Lyricist);
        let _ = tag.remove_key(&ItemKey::Label);
        let _ = tag.remove_key(&ItemKey::Comment);
        let _ = tag.remove_key(&ItemKey::Bpm);
        let _ = tag.remove_key(&ItemKey::IntegerBpm);
        let _ = tag.remove_key(&ItemKey::Language);
        let _ = tag.remove_key(&ItemKey::CopyrightMessage);
        let _ = tag.remove_key(&ItemKey::License);
        let _ = tag.remove_key(&ItemKey::Unknown("LICENSE".to_string()));
    }

    write_field!(payload.title, ItemKey::TrackTitle);
    write_field!(payload.artist, ItemKey::TrackArtist);
    write_field!(payload.album, ItemKey::AlbumTitle);
    write_field!(payload.album_artist, ItemKey::AlbumArtist);
    write_field!(payload.genre, ItemKey::Genre);
    write_field!(payload.year, ItemKey::RecordingDate);
    write_field!(payload.track, ItemKey::TrackNumber);
    write_field!(payload.track_total, ItemKey::TrackTotal);
    write_field!(payload.disc, ItemKey::DiscNumber);
    write_field!(payload.disc_total, ItemKey::DiscTotal);
    write_field!(payload.composer, ItemKey::Composer);
    write_field!(payload.lyricist, ItemKey::Lyricist);
    write_field!(payload.label, ItemKey::Label);
    write_field!(payload.comment, ItemKey::Comment);
    write_field!(payload.bpm, ItemKey::IntegerBpm);
    write_field!(payload.language, ItemKey::Language);
    write_field!(payload.copyright, ItemKey::CopyrightMessage);
    if let Some(value) = &payload.license {
        let trimmed = value.trim().to_string();
        let _ = tag.remove_key(&ItemKey::License);
        let custom_key = ItemKey::Unknown("LICENSE".to_string());
        let _ = tag.remove_key(&custom_key);
        if !trimmed.is_empty() {
            if tag.tag_type() == TagType::Id3v2 {
                tag.insert_unchecked(TagItem::new(custom_key, ItemValue::Text(trimmed)));
            } else {
                tag.insert_text(ItemKey::License, trimmed);
            }
        }
    }

    tagged_file
        .save_to_path(&path, WriteOptions::default())
        .map_err(|e| format!("Error saving tags: {:?}", e.kind()))?;
    Ok(())
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

    let _ = tag.remove_key(&ItemKey::Lyrics);
    tag.insert_text(ItemKey::Lyrics, lyric.clone());
    tagged_file
        .save_to_path(&path, WriteOptions::default())
        .map_err(|e| format!("Error saving lyrics: {:?}", e.kind()))?;
    match _get_lyric_from_lofty(&path) {
        Some(saved) if saved == lyric => Ok(()),
        Some(_) => Err("written lyrics do not match the saved tag".to_string()),
        None => Err("written lyrics could not be read back".to_string()),
    }
}

fn is_supported_audio_path(path: &Path) -> bool {
    let Some(extension) = path.extension() else {
        return false;
    };
    let extension = extension.to_string_lossy().to_ascii_lowercase();
    SUPPORTED_FORMATS.contains(extension.as_str())
}

/// 递归收集所有子文件夹中的音频文件路径，按父目录分组。
/// 一次遍历同时完成「统计总数」和「收集路径」，避免二次目录遍历。
fn collect_audio_files_by_folder(
    folder: impl AsRef<Path>,
    count: &mut u64,
    by_folder: &mut HashMap<String, Vec<PathBuf>>,
    seen: &mut HashSet<String>,
) -> io::Result<()> {
    let folder_str = folder.as_ref().to_string_lossy().to_string();
    if !seen.insert(folder_str.clone()) {
        return Ok(());
    }
    for entry in fs::read_dir(folder.as_ref())? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            collect_audio_files_by_folder(entry.path(), count, by_folder, seen)?;
        } else if file_type.is_file() && is_supported_audio_path(&entry.path()) {
            *count += 1;
            by_folder
                .entry(folder_str.clone())
                .or_default()
                .push(entry.path());
        }
    }
    Ok(())
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
    let mut by_folder: HashMap<String, Vec<PathBuf>> = HashMap::new();
    for item in &folders {
        collect_audio_files_by_folder(Path::new(item), &mut total, &mut by_folder, &mut seen)?;
    }

    for (dir_path, file_paths) in &by_folder {
        let _ = sink.add(IndexActionState {
            progress: if total == 0 {
                0.0
            } else {
                scanned as f64 / total as f64
            },
            message: String::from("正在扫描 ") + dir_path,
        });

        let scanned_before = scanned;
        let read_results = read_audio_paths_parallel(file_paths, |completed| {
            let completed = scanned_before + completed as u64;
            if should_emit_index_progress(completed as usize, total as usize) {
                let _ = sink.add(IndexActionState {
                    progress: if total == 0 {
                        1.0
                    } else {
                        completed as f64 / total as f64
                    },
                    message: String::new(),
                });
            }
        });
        if let Some(failed_index) = read_results.iter().position(Option::is_none) {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                format!(
                    "failed to read audio while building index: {}",
                    file_paths[failed_index].display()
                ),
            ));
        }
        let audios: Vec<Audio> = read_results.into_iter().flatten().collect();
        scanned += file_paths.len() as u64;
        let latest = audios.iter().map(|audio| audio.created).max().unwrap_or(0);

        if !audios.is_empty() {
            let modified = fs::metadata(dir_path)?
                .modified()?
                .duration_since(UNIX_EPOCH)
                .unwrap_or(Duration::ZERO)
                .as_secs();
            audio_folders.push(AudioFolder {
                path: dir_path.clone(),
                modified,
                latest,
                audios,
            });
        }
    }

    let mut audio_folders_json: Vec<serde_json::Value> = vec![];
    for item in &audio_folders {
        audio_folders_json.push(item.to_json_value());
    }
    let json_value = serde_json::json!({
        "version": CURRENT_INDEX_VERSION,
        "folders": audio_folders_json,
    });

    library_db::write_index_snapshot(&index_dir, &json_value).map_err(io::Error::other)?;

    Ok(())
}

fn _update_index_below_1_1_0(
    index: &serde_json::Value,
    index_path: &PathBuf,
    sink: &StreamSink<IndexActionState>,
) -> Result<(), io::Error> {
    let mut audio_folders_json: Vec<serde_json::Value> = vec![];
    let folders = index
        .as_array()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "index is not an array"))?;
    for item in folders {
        let path = item["path"]
            .as_str()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing 'path' field"))?;
        let _ = sink.add(IndexActionState {
            progress: audio_folders_json.len() as f64 / folders.len() as f64,
            message: String::from("正在扫描 ") + path,
        });
        let folder_path = Path::new(path);
        match AudioFolder::read_from_folder(folder_path) {
            Ok(audio_folder) => audio_folders_json.push(audio_folder.to_json_value()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        }
        let _ = sink.add(IndexActionState {
            progress: audio_folders_json.len() as f64 / folders.len() as f64,
            message: String::new(),
        });
    }
    let index_dir = index_path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "index path has no parent"))?;
    let migrated = serde_json::json!({
        "version": CURRENT_INDEX_VERSION,
        "folders": audio_folders_json,
    });
    library_db::write_index_snapshot(index_dir, &migrated).map_err(io::Error::other)?;

    Ok(())
}

fn discover_new_audio_folders(
    root: &Path,
    existing_paths: &HashSet<String>,
    new_entries: &mut Vec<serde_json::Value>,
    scanned: &mut HashSet<String>,
) -> io::Result<()> {
    let dir_str = root.to_string_lossy().to_string();
    if !scanned.insert(dir_str.clone()) {
        return Ok(());
    }

    if !existing_paths.contains(&dir_str) {
        match AudioFolder::read_from_folder(root) {
            Ok(audio_folder) => {
                new_entries.push(audio_folder.to_json_value());
                return Ok(());
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }

    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    for entry in entries {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            discover_new_audio_folders(&entry.path(), existing_paths, new_entries, scanned)?;
        }
    }
    Ok(())
}

fn add_missing_audio_files(
    folder_path: &str,
    audios: &mut Vec<serde_json::Value>,
    latest: u64,
) -> io::Result<(u64, bool)> {
    let existing_audio_paths: HashSet<String> = audios
        .iter()
        .filter_map(|item| item["path"].as_str().map(|path| path.to_string()))
        .collect();
    let mut new_latest = latest;
    let dir = match fs::read_dir(folder_path) {
        Ok(value) => value,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok((new_latest, false));
        }
        Err(error) => return Err(error),
    };
    let mut paths = Vec::new();
    for entry in dir {
        let entry = entry?;
        if entry.file_type()?.is_file()
            && is_supported_audio_path(&entry.path())
            && !existing_audio_paths.contains(&entry.path().to_string_lossy().to_string())
        {
            paths.push(entry.path());
        }
    }
    let read_results = read_audio_paths_parallel(&paths, |_| {});
    if let Some(failed_index) = read_results.iter().position(Option::is_none) {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!(
                "failed to read new audio while updating index: {}",
                paths[failed_index].display()
            ),
        ));
    }
    let mut added = false;
    for new_audio in read_results.into_iter().flatten() {
        if new_audio.created > new_latest {
            new_latest = new_audio.created;
        }
        audios.push(new_audio.to_json_value());
        added = true;
    }
    Ok((new_latest, added))
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
/// 显式刷新时检查每个已索引文件的修改时间，只重新读取实际变化的音乐标签。
/// 1. 遍历该文件夹索引，判断文件是否存在，不存在则删除记录
/// 2. 遍历该文件夹索引，如果文件修改时间变化，重新读取标签；没有则跳过它
/// 3. 遍历该文件夹，添加索引中不存在的音乐文件
fn should_scan_indexed_audio_files(
    old_folder_modified: u64,
    new_folder_modified: u64,
    explicit_refresh: bool,
) -> bool {
    explicit_refresh || new_folder_modified != old_folder_modified
}

fn indexed_audio_needs_update(audio_item: &serde_json::Value, metadata: &fs::Metadata) -> bool {
    if !audio_item
        .as_object()
        .is_some_and(|item| item.contains_key("disc"))
    {
        return true;
    }
    let old_audio_modified = audio_item["modified"].as_u64().unwrap_or(0);
    let Ok(modified) = metadata.modified() else {
        return false;
    };
    let new_audio_modified = modified
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_secs();
    new_audio_modified != old_audio_modified
}

fn probe_indexed_path<T>(result: io::Result<T>) -> io::Result<Option<T>> {
    match result {
        Ok(value) => Ok(Some(value)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tag_reader_tests {
    use lofty::file::FileType;
    use lofty::prelude::ItemKey;

    use super::{
        is_lyric_item_key, parse_midi_metadata, probe_indexed_path, should_emit_index_progress,
        should_scan_indexed_audio_files, should_show_recording_date, tag_reader_worker_count_for,
        SUPPORTED_FORMATS,
    };

    #[test]
    fn reserves_two_logical_cores_for_playback_and_ui() {
        assert_eq!(tag_reader_worker_count_for(16, 100), 4);
        assert_eq!(tag_reader_worker_count_for(8, 100), 3);
        assert_eq!(tag_reader_worker_count_for(6, 100), 2);
        assert_eq!(tag_reader_worker_count_for(4, 100), 1);
        assert_eq!(tag_reader_worker_count_for(2, 100), 1);
        assert_eq!(tag_reader_worker_count_for(16, 1), 1);
    }

    #[test]
    fn scans_audio_files_when_folder_timestamp_is_unchanged() {
        assert!(should_scan_indexed_audio_files(100, 100, true));
    }

    #[test]
    fn scans_folder_when_timestamp_moves_backwards() {
        assert!(should_scan_indexed_audio_files(101, 100, false));
    }

    #[test]
    fn only_not_found_marks_an_indexed_path_missing() {
        assert!(
            probe_indexed_path::<()>(Err(std::io::Error::from(std::io::ErrorKind::NotFound)))
                .unwrap()
                .is_none()
        );
        let error = probe_indexed_path::<()>(Err(std::io::Error::from(
            std::io::ErrorKind::PermissionDenied,
        )))
        .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
    }

    #[test]
    fn caps_progress_updates_for_large_indexes() {
        let update_count = (1..=50_000)
            .filter(|completed| should_emit_index_progress(*completed, 50_000))
            .count();
        assert_eq!(update_count, 200);
        assert!(should_emit_index_progress(16, 100));
        assert!(should_emit_index_progress(100, 100));
    }

    #[test]
    fn hides_duplicate_recording_date_when_used_as_year() {
        assert!(!should_show_recording_date(
            Some("2026-06-11"),
            Some("2026-06-11")
        ));
    }

    #[test]
    fn only_scans_lyric_named_fallback_fields() {
        assert!(!is_lyric_item_key(&ItemKey::TrackArtist));
        assert!(is_lyric_item_key(&ItemKey::Unknown(
            "UNSYNCEDLYRICS".to_string()
        )));
    }

    #[test]
    fn includes_every_lofty_extension_and_excludes_wavpack_correction_files() {
        let lofty_extensions = [
            "aac", "ape", "aiff", "aif", "afc", "aifc", "mp3", "mp2", "mp1", "wav", "wave", "wv",
            "opus", "flac", "ogg", "mp4", "m4a", "m4b", "m4p", "m4r", "m4v", "3gp", "mpc", "mp+",
            "mpp", "spx",
        ];
        for extension in lofty_extensions {
            assert!(FileType::from_ext(extension).is_some(), "{extension}");
            assert!(SUPPORTED_FORMATS.contains(extension), "{extension}");
        }
        for extension in [
            "mpa", "oga", "asf", "wma", "adts", "3g2", "mka", "mkv", "webm", "weba", "caf", "ac3",
            "a52", "amr", "3ga", "mid", "midi", "kar", "rmi", "dsf", "dff",
        ] {
            assert!(SUPPORTED_FORMATS.contains(extension), "{extension}");
        }
        assert!(!SUPPORTED_FORMATS.contains("wvc"));
    }

    #[test]
    fn reads_sequential_midi_title_and_accumulates_fractional_tracks() {
        let bytes = [
            0x4d, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06, 0x00, 0x02, 0x00, 0x02, 0x01, 0xe0,
            0x4d, 0x54, 0x72, 0x6b, 0x00, 0x00, 0x00, 0x0c, 0x00, 0xff, 0x03, 0x03, 0x4f, 0x6e,
            0x65, 0x83, 0x60, 0xff, 0x2f, 0x00, 0x4d, 0x54, 0x72, 0x6b, 0x00, 0x00, 0x00, 0x0c,
            0x00, 0xff, 0x03, 0x03, 0x54, 0x77, 0x6f, 0x83, 0x60, 0xff, 0x2f, 0x00,
        ];
        let metadata = parse_midi_metadata(&bytes).expect("valid MIDI metadata");
        assert_eq!(metadata.title.as_deref(), Some("One"));
        assert_eq!(metadata.duration, 1);
        assert_eq!(
            metadata
                .items
                .iter()
                .filter(|(key, _)| key == "track_name")
                .count(),
            2
        );

        let mut rmi = b"RIFF".to_vec();
        let riff_size = 4 + 8 + bytes.len() + (bytes.len() & 1);
        rmi.extend_from_slice(&(riff_size as u32).to_le_bytes());
        rmi.extend_from_slice(b"RMIDdata");
        rmi.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        rmi.extend_from_slice(&bytes);
        if bytes.len() & 1 == 1 {
            rmi.push(0);
        }
        let rmi_metadata = parse_midi_metadata(&rmi).expect("valid RIFF MIDI metadata");
        assert_eq!(rmi_metadata.title.as_deref(), Some("One"));
        assert_eq!(rmi_metadata.duration, 1);
    }
}

fn index_folder_snapshots_unchanged(folders: &[library_db::IndexFolderSnapshot]) -> bool {
    folders.iter().all(|folder| {
        fs::metadata(&folder.path)
            .and_then(|metadata| metadata.modified())
            .map(|modified| {
                modified
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or(Duration::ZERO)
                    .as_secs()
                    == folder.modified
            })
            .unwrap_or(false)
    })
}

pub fn update_index(
    index_path: String,
    force_metadata_check: bool,
    sink: StreamSink<IndexActionState>,
) -> anyhow::Result<()> {
    let index_dir = PathBuf::from(&index_path);
    let sqlite_snapshot = library_db::read_current_index_snapshot(&index_dir)?;
    let sqlite_snapshot_current = sqlite_snapshot.is_some();
    if !force_metadata_check {
        if let Some(snapshot) = sqlite_snapshot.as_ref() {
            if snapshot.version == CURRENT_INDEX_VERSION
                && index_folder_snapshots_unchanged(&snapshot.folders)
            {
                log_to_dart("index update fast path: unchanged".to_string());
                let _ = sink.add(IndexActionState {
                    progress: 1.0,
                    message: String::from("音乐库更新完成"),
                });
                return Ok(());
            }
        }
    }
    let mut index_path = PathBuf::from(index_path);
    index_path.push("index.json");
    let index = fs::read(&index_path)?;
    let mut index: serde_json::Value = serde_json::from_slice(&index)?;

    let version = index["version"].as_u64();
    if version.is_none() {
        return Ok(_update_index_below_1_1_0(&index, &index_path, &sink)?);
    }
    let refresh_all_metadata = version.is_some_and(|value| value < CURRENT_INDEX_VERSION);
    let mut index_changed = refresh_all_metadata;
    index["version"] = serde_json::json!(CURRENT_INDEX_VERSION);

    let folders = index["folders"]
        .as_array_mut()
        .ok_or_else(|| anyhow::anyhow!("missing 'folders' field"))?;
    let previous_folder_count = folders.len();
    let mut folder_probe_error = None;
    folders.retain(|item| {
        let Some(path) = item["path"].as_str() else {
            folder_probe_error = Some(io::Error::new(
                io::ErrorKind::InvalidData,
                "indexed folder is missing path",
            ));
            return true;
        };
        match probe_indexed_path(fs::metadata(path)) {
            Ok(Some(_)) => true,
            Ok(None) => false,
            Err(error) => {
                folder_probe_error = Some(error);
                true
            }
        }
    });
    if let Some(error) = folder_probe_error {
        return Err(error.into());
    }
    index_changed |= folders.len() != previous_folder_count;
    let total = folders
        .iter()
        .filter_map(|folder| folder["audios"].as_array())
        .map(|audios| audios.len() as u64)
        .sum::<u64>();
    let mut checked = 0_u64;
    let mut discovery_roots = Vec::new();

    for folder_item in folders.iter_mut() {
        let folder_path = match folder_item["path"].as_str() {
            Some(p) => p.to_string(),
            None => continue,
        };
        let latest = folder_item["latest"].as_u64().unwrap_or(0);
        let old_folder_modified = folder_item["modified"].as_u64().unwrap_or(0);

        let new_folder_modified = fs::metadata(&folder_path)?
            .modified()?
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_secs();

        let folder_audio_count = folder_item["audios"]
            .as_array()
            .map(|audios| audios.len() as u64)
            .unwrap_or(0);
        if !should_scan_indexed_audio_files(
            old_folder_modified,
            new_folder_modified,
            force_metadata_check || refresh_all_metadata,
        ) {
            checked += folder_audio_count;
            continue;
        }
        discovery_roots.push(PathBuf::from(&folder_path));

        let _ = sink.add(IndexActionState {
            progress: if total == 0 {
                0.0
            } else {
                checked as f64 / total as f64
            },
            message: String::from("正在更新 ") + &folder_path,
        });

        if new_folder_modified != old_folder_modified {
            folder_item["modified"] = serde_json::json!(new_folder_modified);
            index_changed = true;
        }

        let audios = match folder_item["audios"].as_array_mut() {
            Some(a) => a,
            None => continue,
        };
        let previous_audio_count = audios.len();
        let mut refresh_jobs: Vec<(usize, PathBuf)> = Vec::new();
        let mut retained_index = 0_usize;
        let mut audio_probe_error = None;
        audios.retain(|audio_item| {
            let Some(path) = audio_item["path"].as_str() else {
                audio_probe_error = Some(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "indexed audio is missing path",
                ));
                return true;
            };
            match probe_indexed_path(fs::metadata(path)) {
                Ok(Some(metadata)) => {
                    if refresh_all_metadata || indexed_audio_needs_update(audio_item, &metadata) {
                        refresh_jobs.push((retained_index, PathBuf::from(path)));
                    }
                    retained_index += 1;
                    true
                }
                Ok(None) => false,
                Err(error) => {
                    audio_probe_error = Some(error);
                    retained_index += 1;
                    true
                }
            }
        });
        if let Some(error) = audio_probe_error {
            return Err(error.into());
        }
        let removed_count = previous_audio_count - audios.len();
        if removed_count > 0 {
            checked += removed_count as u64;
            index_changed = true;
        }

        checked += (audios.len() - refresh_jobs.len()) as u64;
        let refresh_paths: Vec<PathBuf> =
            refresh_jobs.iter().map(|(_, path)| path.clone()).collect();
        let checked_before_refresh = checked;
        let refreshed = read_audio_paths_parallel(&refresh_paths, |completed| {
            let completed = checked_before_refresh + completed as u64;
            if should_emit_index_progress(completed as usize, total as usize) {
                let _ = sink.add(IndexActionState {
                    progress: if total == 0 {
                        1.0
                    } else {
                        completed as f64 / total as f64
                    },
                    message: String::new(),
                });
            }
        });
        if let Some(failed_index) = refreshed.iter().position(Option::is_none) {
            return Err(anyhow::anyhow!(
                "failed to refresh audio while updating index: {}",
                refresh_paths[failed_index].display()
            ));
        }
        checked += refresh_jobs.len() as u64;
        for ((audio_index, _), modified_audio) in refresh_jobs.into_iter().zip(refreshed) {
            if let Some(modified_audio) = modified_audio {
                audios[audio_index] = modified_audio.to_json_value();
                index_changed = true;
            }
        }
        if refresh_paths.is_empty() {
            let _ = sink.add(IndexActionState {
                progress: if total == 0 {
                    1.0
                } else {
                    checked as f64 / total as f64
                },
                message: String::new(),
            });
        }

        let (new_latest, added) = add_missing_audio_files(&folder_path, audios, latest)?;
        if added || new_latest != latest {
            folder_item["latest"] = serde_json::json!(new_latest);
            index_changed = true;
        }
    }

    {
        let existing_paths: HashSet<String> = folders
            .iter()
            .filter_map(|f| f.get("path").and_then(|v| v.as_str()).map(String::from))
            .collect();
        let mut new_entries: Vec<serde_json::Value> = Vec::new();
        let mut scanned_dirs: HashSet<String> = HashSet::new();
        for root_path in discovery_roots {
            let _ = sink.add(IndexActionState {
                progress: if total == 0 {
                    0.0
                } else {
                    checked as f64 / total as f64
                },
                message: format!("正在检查新增文件夹 {}", root_path.to_string_lossy()),
            });
            discover_new_audio_folders(
                &root_path,
                &existing_paths,
                &mut new_entries,
                &mut scanned_dirs,
            )?;
        }
        if !new_entries.is_empty() {
            index_changed = true;
            folders.extend(new_entries);
        }
    }

    if index_changed || !sqlite_snapshot_current {
        library_db::write_index_snapshot(&index_dir, &index)?;
    }

    let _ = sink.add(IndexActionState {
        progress: 1.0,
        message: String::from("音乐库更新完成"),
    });

    Ok(())
}
