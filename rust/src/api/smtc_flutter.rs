use std::sync::Mutex;
use std::time::Duration;

use flutter_rust_bridge::frb;
use windows::{
    core::HSTRING,
    Foundation::{TimeSpan, TypedEventHandler},
    Media::{
        Core::MediaSource,
        MediaPlaybackStatus, MediaPlaybackType,
        Playback::MediaPlayer,
        SystemMediaTransportControls, SystemMediaTransportControlsButton,
        SystemMediaTransportControlsButtonPressedEventArgs,
        SystemMediaTransportControlsTimelineProperties,
    },
    Storage::{
        FileProperties::ThumbnailMode,
        StorageFile,
        Streams::{DataWriter, InMemoryRandomAccessStream, RandomAccessStreamReference},
    },
};

use crate::frb_generated::StreamSink;

use super::{logger::log_to_dart, tag_reader};

// 一个最小的静音WAV文件（44100Hz，单声道，16bit，PCM）
const SILENT_WAV: &[u8] = &[
    // RIFF header
    b'R', b'I', b'F', b'F',
    0x24, 0x00, 0x00, 0x00,
    b'W', b'A', b'V', b'E',
    b'f', b'm', b't', b' ',
    0x10, 0x00, 0x00, 0x00,
    0x01, 0x00,
    0x01, 0x00,
    0x44, 0xAC, 0x00, 0x00,
    0x88, 0x58, 0x01, 0x00,
    0x02, 0x00,
    0x10, 0x00,
    b'd', b'a', b't', b'a',
    0x00, 0x00, 0x00, 0x00,
];

pub struct SMTCFlutter {
    _smtc: SystemMediaTransportControls,
    _player: MediaPlayer,
    duration_ms: Mutex<u32>,
}

#[derive(Debug)]
pub enum SMTCControlEvent {
    Play,
    Pause,
    Previous,
    Next,
    Unknown,
    Stop,
}

pub enum SMTCState {
    Paused,
    Playing,
}

/// Apis for Flutter
impl SMTCFlutter {
    #[frb(sync)]
    pub fn new() -> Self {
        Self::_new().unwrap()
    }

    pub fn subscribe_to_control_events(&self, sink: StreamSink<SMTCControlEvent>) {
        log_to_dart("SMTC: Subscribing to control events...".to_string());

        let smtc_clone = self._smtc.clone();
        let is_enabled = smtc_clone.IsEnabled().unwrap_or(false);
        log_to_dart(format!("SMTC: IsEnabled={}", is_enabled));

        let is_playing_enabled = smtc_clone.IsPlayEnabled().unwrap_or(false);
        let is_pause_enabled = smtc_clone.IsPauseEnabled().unwrap_or(false);
        let is_next_enabled = smtc_clone.IsNextEnabled().unwrap_or(false);
        let is_previous_enabled = smtc_clone.IsPreviousEnabled().unwrap_or(false);
        log_to_dart(format!("SMTC: Play={}, Pause={}, Next={}, Previous={}",
            is_playing_enabled, is_pause_enabled, is_next_enabled, is_previous_enabled));

        self._smtc
            .ButtonPressed(&TypedEventHandler::<
                SystemMediaTransportControls,
                SystemMediaTransportControlsButtonPressedEventArgs,
            >::new(move |_, event| {
                if let Some(e) = event {
                    if let Ok(button) = e.Button() {
                        let event = match button {
                            SystemMediaTransportControlsButton::Play => SMTCControlEvent::Play,
                            SystemMediaTransportControlsButton::Pause => SMTCControlEvent::Pause,
                            SystemMediaTransportControlsButton::Next => SMTCControlEvent::Next,
                            SystemMediaTransportControlsButton::Previous => SMTCControlEvent::Previous,
                            _ => SMTCControlEvent::Unknown,
                        };
                        log_to_dart(format!("SMTC: Button pressed - {:?}", event));
                        let _ = sink.add(event);
                    }
                }
                Ok(())
            }))
            .unwrap();

        log_to_dart("SMTC: Subscription complete".to_string());
    }

    pub fn update_state(&self, state: SMTCState) {
        if let Err(err) = self._update_state(state) {
            log_to_dart(format!("fail to update state: {}", err));
        }
    }

    /// progress, duration: ms
    pub fn update_time_properties(&self, progress: u32) {
        if let Err(err) = self._update_time_properties(progress) {
            log_to_dart(format!("fail to update state: {}", err));
        }
    }

    pub fn update_display(
        &self,
        title: String,
        artist: String,
        album: String,
        duration: u32,
        path: String,
    ) {
        if let Err(err) = self._update_display(
            HSTRING::from(title),
            HSTRING::from(artist),
            HSTRING::from(album),
            duration,
            HSTRING::from(path),
        ) {
            log_to_dart(format!("fail to update display: {}", err));
        }
    }

    pub fn close(self) {
        let _ = self._player.Close();
    }
}

impl SMTCFlutter {
    fn _create_silent_media_source() -> Result<MediaSource, windows::core::Error> {
        use windows::core::Interface;
        
        let stream = InMemoryRandomAccessStream::new()?;
        let writer = DataWriter::CreateDataWriter(&stream)?;
        writer.WriteBytes(SILENT_WAV)?;
        writer.StoreAsync()?.get()?;
        writer.DetachStream()?;
        stream.Seek(0)?;
        
        // Use cast to convert InMemoryRandomAccessStream to IRandomAccessStream
        let ras = stream.cast::<windows::Storage::Streams::IRandomAccessStream>()?;
        MediaSource::CreateFromStream(&ras, &HSTRING::from("audio/wav"))
    }

    fn _init_controls(smtc: &SystemMediaTransportControls) -> Result<(), windows::core::Error> {
        smtc.SetIsEnabled(true)?;
        smtc.SetIsNextEnabled(true)?;
        smtc.SetIsPauseEnabled(true)?;
        smtc.SetIsPlayEnabled(true)?;
        smtc.SetIsPreviousEnabled(true)?;
        Ok(())
    }

    fn _new() -> Result<Self, windows::core::Error> {
        let _player = MediaPlayer::new()?;
        _player.CommandManager()?.SetIsEnabled(false)?;
        _player.SetIsMuted(true)?;
        _player.SetVolume(0.0)?;
        
        // Set a silent MediaSource to activate PlaybackSession so SMTC buttons work
        if let Ok(source) = Self::_create_silent_media_source() {
            _player.SetSource(&source)?;
        }

        let _smtc = _player.SystemMediaTransportControls()?;
        Self::_init_controls(&_smtc)?;

        // 关键：初始化时调用DisplayUpdater.Update()，确保SMTC注册到系统
        // 只有Update()被调用后，SMTC的按钮事件才会被系统分发
        let updater = _smtc.DisplayUpdater()?;
        updater.SetType(MediaPlaybackType::Music)?;
        updater.Update()?;
        log_to_dart("SMTC: DisplayUpdater.Update() called during init".to_string());

        Ok(Self { _smtc, _player, duration_ms: Mutex::new(0) })
    }

    fn _update_state(&self, state: SMTCState) -> Result<(), windows::core::Error> {
        let state = match state {
            SMTCState::Playing => MediaPlaybackStatus::Playing,
            SMTCState::Paused => MediaPlaybackStatus::Paused,
        };
        self._smtc.SetPlaybackStatus(state)?;

        Ok(())
    }

    /// progress, duration: ms
    fn _update_time_properties(&self, progress: u32) -> Result<(), windows::core::Error> {
        let dur = *self.duration_ms.lock().unwrap();
        let time_properties = SystemMediaTransportControlsTimelineProperties::new()?;
        time_properties.SetPosition(TimeSpan::from(Duration::from_millis(progress.into())))?;
        time_properties.SetEndTime(TimeSpan::from(Duration::from_millis(dur.into())))?;
        time_properties.SetMinSeekTime(TimeSpan { Duration: 0 })?;
        time_properties.SetMaxSeekTime(TimeSpan::from(Duration::from_millis(dur.into())))?;
        self._smtc.UpdateTimelineProperties(&time_properties)?;

        Ok(())
    }

    fn _ras_ref_from_pic_data(
        picture_data: &[u8],
    ) -> Result<RandomAccessStreamReference, windows::core::Error> {
        let stream = InMemoryRandomAccessStream::new()?;

        let writer = DataWriter::CreateDataWriter(&stream)?;
        writer.WriteBytes(picture_data)?;
        writer.StoreAsync()?.get()?;

        // 调用 DetachStream() 的意义在于"把流从 DataWriter 脱附"，
        // 这样可以安全地释放/关闭 DataWriter 而不影响流的生命周期。
        // stream 不会因为 writer drop 而被销毁
        writer.DetachStream()?;

        stream.Seek(0)?;

        Ok(RandomAccessStreamReference::CreateFromStream(&stream)?)
    }

    fn _update_display(
        &self,
        title: HSTRING,
        artist: HSTRING,
        album: HSTRING,
        duration: u32,
        path: HSTRING,
    ) -> Result<(), windows::core::Error> {
        let updater = self._smtc.DisplayUpdater()?;
        updater.SetType(MediaPlaybackType::Music)?;

        // 优先使用 CopyFromFileAsync（微软推荐方式，自动提取标题/艺术家/专辑/缩略图）
        let copy_ok = match StorageFile::GetFileFromPathAsync(&path) {
            Ok(op) => match op.get() {
                Ok(file) => match updater.CopyFromFileAsync(MediaPlaybackType::Music, &file) {
                    Ok(async_op) => match async_op.get() {
                        Ok(_) => {
                            log_to_dart("SMTC: CopyFromFileAsync succeeded".to_string());
                            true
                        }
                        Err(e) => {
                            log_to_dart(format!("SMTC: CopyFromFileAsync get err: {}", e));
                            false
                        }
                    },
                    Err(e) => {
                        log_to_dart(format!("SMTC: CopyFromFileAsync call err: {}", e));
                        false
                    }
                },
                Err(e) => {
                    log_to_dart(format!("SMTC: GetFileFromPathAsync get err: {}", e));
                    false
                }
            },
            Err(e) => {
                log_to_dart(format!("SMTC: GetFileFromPathAsync err: {}", e));
                false
            }
        };

        if !copy_ok {
            // 回退：手动设置 MusicProperties
            log_to_dart("SMTC: falling back to manual MusicProperties".to_string());
            if let Ok(music_properties) = updater.MusicProperties() {
                let _ = music_properties.SetTitle(&title);
                let _ = music_properties.SetArtist(&artist);
                let _ = music_properties.SetAlbumTitle(&album);
            }

            // 缩略图：失败不阻塞，仅打日志
            match Self::_try_get_thumbnail(&path) {
                Ok(Some(pic_ref)) => {
                    let _ = updater.SetThumbnail(&pic_ref);
                }
                Ok(None) => {}
                Err(e) => {
                    log_to_dart(format!("SMTC: thumbnail err: {}", e));
                }
            }
        }

        // 更新时间线
        *self.duration_ms.lock().unwrap() = duration;
        let time_properties = SystemMediaTransportControlsTimelineProperties::new()?;
        time_properties.SetStartTime(TimeSpan { Duration: 0 })?;
        time_properties.SetEndTime(TimeSpan::from(Duration::from_millis(duration.into())))?;
        time_properties.SetMinSeekTime(TimeSpan { Duration: 0 })?;
        time_properties.SetMaxSeekTime(TimeSpan::from(Duration::from_millis(duration.into())))?;
        self._smtc.UpdateTimelineProperties(&time_properties)?;

        // 关键：无论如何都要调用 Update() 提交更改
        updater.Update()?;

        if !(self._smtc.IsEnabled()?) {
            self._smtc.SetIsEnabled(true)?;
        }

        log_to_dart(format!("SMTC: Display updated - {}", title));

        Ok(())
    }

    /// 尝试获取缩略图引用，返回 None 表示无缩略图（非错误）
    fn _try_get_thumbnail(
        path: &HSTRING,
    ) -> Result<Option<RandomAccessStreamReference>, windows::core::Error> {
        if let Some(pic_data) = tag_reader::get_picture_from_path(path.to_string(), 256, 256) {
            return Ok(Some(Self::_ras_ref_from_pic_data(&pic_data)?));
        }
        log_to_dart(format!(
            "SMTC: no embedded picture for {}",
            path.to_string()
        ));
        let file = StorageFile::GetFileFromPathAsync(path)?.get()?;
        let thumbnail = file
            .GetThumbnailAsyncOverloadDefaultSizeDefaultOptions(ThumbnailMode::MusicView)?
            .get()?;
        Ok(Some(RandomAccessStreamReference::CreateFromStream(&thumbnail)?))
    }
}