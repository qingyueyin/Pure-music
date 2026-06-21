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

/// 生成 1 秒静默 PCM WAV（44100Hz，单声道，16bit）
/// 用于给 MediaPlayer 提供一个持续活动的播放会话，使 SMTC 能注册到 Windows。
fn create_silent_wav_1s() -> Vec<u8> {
    let sample_rate = 44100u32;
    let num_channels = 1u16;
    let bits_per_sample = 16u16;
    let duration_samples = sample_rate; // 1秒
    let data_size = duration_samples * num_channels as u32 * (bits_per_sample / 8) as u32;
    // = 44100 * 1 * 2 = 88200

    let total_size = 44 + data_size as usize;
    let mut wav = Vec::with_capacity(total_size);

    // RIFF header
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36u32 + data_size).to_le_bytes());
    wav.extend_from_slice(b"WAVE");

    // fmt subchunk
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes()); // Subchunk1Size (PCM)
    wav.extend_from_slice(&1u16.to_le_bytes());  // AudioFormat (PCM)
    wav.extend_from_slice(&num_channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    let byte_rate = sample_rate * num_channels as u32 * (bits_per_sample / 8) as u32;
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    let block_align = num_channels * (bits_per_sample / 8);
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&bits_per_sample.to_le_bytes());

    // data subchunk
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_size.to_le_bytes());

    // 静默数据（全零）
    wav.resize(total_size, 0u8);

    wav
}

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
            log_to_dart(format!("fail to update time properties: {}", err));
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
        // 先禁用 SMTC 控件，避免残留的 SMTC 会话干扰下次启动
        let _ = self._smtc.SetIsEnabled(false);
        // 更新一次状态让 Windows 知道播放已停止
        let _ = self._smtc.SetPlaybackStatus(MediaPlaybackStatus::Stopped);
        // 最后关闭 MediaPlayer，释放 COM 资源
        let _ = self._player.Close();
    }
}

impl SMTCFlutter {
    fn _create_silent_media_source() -> Result<MediaSource, windows::core::Error> {
        use windows::core::Interface;
        
        let wav_bytes = create_silent_wav_1s();
        let stream = InMemoryRandomAccessStream::new()?;
        let writer = DataWriter::CreateDataWriter(&stream)?;
        writer.WriteBytes(&wav_bytes)?;
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
        
        // 设置静默音源并循环播放，使 PlaybackSession 保持活动状态
        // SMTC 只有在 MediaPlayer 处于播放状态时才会出现在 Windows 系统中
        if let Ok(source) = Self::_create_silent_media_source() {
            _player.SetSource(&source)?;
            _player.SetIsLoopingEnabled(true)?;
            _player.Play()?;
        }

        let _smtc = _player.SystemMediaTransportControls()?;
        Self::_init_controls(&_smtc)?;

        // 关键：初始化时调用DisplayUpdater.Update()，确保SMTC注册到系统
        // 只有Update()被调用后，SMTC的按钮事件才会被系统分发
        // 同时立即设置占位信息，覆盖上一个异常退出残留的 SMTC 显示
        let updater = _smtc.DisplayUpdater()?;
        updater.SetType(MediaPlaybackType::Music)?;
        if let Ok(music_properties) = updater.MusicProperties() {
            let _ = music_properties.SetTitle(&HSTRING::from("Pure Music"));
            let _ = music_properties.SetArtist(&HSTRING::from(""));
        }
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

        // 手动设置 MusicProperties（比 CopyFromFileAsync 更快更可靠）
        if let Ok(music_properties) = updater.MusicProperties() {
            let _ = music_properties.SetTitle(&title);
            let _ = music_properties.SetArtist(&artist);
            let _ = music_properties.SetAlbumTitle(&album);
        }

        // 缩略图：优先从 tag_reader 读内嵌封面，失败则用 Windows 缩略图
        match Self::_try_get_thumbnail(&path) {
            Ok(Some(pic_ref)) => {
                let _ = updater.SetThumbnail(&pic_ref);
            }
            Ok(None) => {}
            Err(e) => {
                log_to_dart(format!("SMTC: thumbnail err: {}", e));
            }
        }

        // 更新时间线（非致命：失败了也继续提交，不丢元数据）
        *self.duration_ms.lock().unwrap() = duration;
        if let Ok(time_properties) = SystemMediaTransportControlsTimelineProperties::new() {
            let _ = time_properties.SetStartTime(TimeSpan { Duration: 0 });
            let _ = time_properties.SetEndTime(TimeSpan::from(Duration::from_millis(duration.into())));
            let _ = time_properties.SetMinSeekTime(TimeSpan { Duration: 0 });
            let _ = time_properties.SetMaxSeekTime(TimeSpan::from(Duration::from_millis(duration.into())));
            if let Err(e) = self._smtc.UpdateTimelineProperties(&time_properties) {
                log_to_dart(format!("SMTC: UpdateTimelineProperties err (non-fatal): {}", e));
            }
        }

        // 提交更改 — 这是最关键的调用，绝不能跳过
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