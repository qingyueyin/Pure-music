use std::sync::RwLock;
use std::time::Duration;

use flutter_rust_bridge::frb;
use windows::{
    core::HSTRING,
    Foundation::{TimeSpan, TypedEventHandler},
    Media::{
        Core::MediaSource,
        MediaPlaybackStatus, MediaPlaybackType, Playback::MediaPlayer,
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

static SMTC_SINK: RwLock<Option<StreamSink<SMTCControlEvent>>> = RwLock::new(None);

const SILENT_WAV: &[u8] = &[
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
    _button_pressed_token: windows::Foundation::EventRegistrationToken,
}

#[derive(Debug, Clone)]
pub enum SMTCControlEvent {
    Play,
    Pause,
    Previous,
    Next,
    Unknown,
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
        log_to_dart("SMTC: Setting up control event sink...".to_string());
        
        let mut sink_guard = SMTC_SINK.write().unwrap();
        *sink_guard = Some(sink);
        drop(sink_guard);
        
        log_to_dart("SMTC: Control event sink stored".to_string());
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
        self._player.Close().unwrap();
    }
}

impl SMTCFlutter {
    fn _init_controls(smtc: &SystemMediaTransportControls) -> Result<(), windows::core::Error> {
        smtc.SetIsEnabled(true)?;
        smtc.SetIsNextEnabled(true)?;
        smtc.SetIsPauseEnabled(true)?;
        smtc.SetIsPlayEnabled(true)?;
        smtc.SetIsPreviousEnabled(true)?;
        Ok(())
    }

    fn _create_silent_media_source() -> Result<MediaSource, windows::core::Error> {
        use windows::core::Interface;
        
        let stream = InMemoryRandomAccessStream::new()?;
        let writer = DataWriter::CreateDataWriter(&stream)?;
        writer.WriteBytes(SILENT_WAV)?;
        writer.StoreAsync()?.get()?;
        writer.DetachStream()?;
        stream.Seek(0)?;
        
        let ras = stream.cast::<windows::Storage::Streams::IRandomAccessStream>()?;
        MediaSource::CreateFromStream(&ras, &HSTRING::from("audio/wav"))
    }

    fn _new() -> Result<Self, windows::core::Error> {
        let _player = MediaPlayer::new()?;
        _player.CommandManager()?.SetIsEnabled(false)?;
        _player.SetIsMuted(true)?;
        _player.SetVolume(0.0)?;
        
        if let Ok(source) = Self::_create_silent_media_source() {
            _player.SetSource(&source)?;
        }

        let _smtc = _player.SystemMediaTransportControls()?;
        Self::_init_controls(&_smtc)?;

        let handler = TypedEventHandler::<
            SystemMediaTransportControls,
            SystemMediaTransportControlsButtonPressedEventArgs,
        >::new(move |_, event| {
            if let Some(e) = event {
                if let Ok(button) = e.Button() {
                    let control_event = match button {
                        SystemMediaTransportControlsButton::Play => SMTCControlEvent::Play,
                        SystemMediaTransportControlsButton::Pause => SMTCControlEvent::Pause,
                        SystemMediaTransportControlsButton::Next => SMTCControlEvent::Next,
                        SystemMediaTransportControlsButton::Previous => SMTCControlEvent::Previous,
                        _ => SMTCControlEvent::Unknown,
                    };
                    
                    log_to_dart(format!("SMTC: Button pressed - {:?}", control_event));
                    
                    let sink_guard = SMTC_SINK.read().unwrap();
                    if let Some(sink) = sink_guard.as_ref() {
                        if let Err(e) = sink.add(control_event.clone()) {
                            log_to_dart(format!("SMTC: Failed to send event: {}", e));
                        } else {
                            log_to_dart("SMTC: Event sent successfully".to_string());
                        }
                    } else {
                        log_to_dart("SMTC: No sink registered for events".to_string());
                    }
                } else {
                    log_to_dart("SMTC: Failed to get button from event".to_string());
                }
            } else {
                log_to_dart("SMTC: Event is None".to_string());
            }

            Ok(())
        });

        let _button_pressed_token = _smtc.ButtonPressed(&handler)?;
        log_to_dart("SMTC: ButtonPressed handler registered during init".to_string());

        let updater = _smtc.DisplayUpdater()?;
        updater.SetType(MediaPlaybackType::Music)?;
        updater.Update()?;
        log_to_dart("SMTC: DisplayUpdater.Update() called during init".to_string());

        Ok(Self { _smtc, _player, _button_pressed_token })
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
        let time_properties = SystemMediaTransportControlsTimelineProperties::new()?;
        time_properties.SetPosition(TimeSpan::from(Duration::from_millis(progress.into())))?;
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

        let time_properties = SystemMediaTransportControlsTimelineProperties::new()?;
        time_properties.SetStartTime(TimeSpan { Duration: 0 })?;
        time_properties.SetEndTime(TimeSpan::from(Duration::from_millis(duration.into())))?;
        time_properties.SetMinSeekTime(TimeSpan { Duration: 0 })?;
        time_properties.SetMaxSeekTime(TimeSpan::from(Duration::from_millis(duration.into())))?;
        self._smtc.UpdateTimelineProperties(&time_properties)?;

        let music_properties = updater.MusicProperties()?;
        music_properties.SetTitle(&title)?;
        music_properties.SetArtist(&artist)?;
        music_properties.SetAlbumTitle(&album)?;

        let pic_stream_ref =
            if let Some(pic_data) = tag_reader::get_picture_from_path(path.to_string(), 256, 256) {
                Self::_ras_ref_from_pic_data(&pic_data)?
            } else {
                log_to_dart(format!(
                    "no embedded picture found for file: {}",
                    path.to_string()
                ));
                let file = StorageFile::GetFileFromPathAsync(&path)?.get()?;
                let thumbnail = file
                    .GetThumbnailAsyncOverloadDefaultSizeDefaultOptions(ThumbnailMode::MusicView)?
                    .get()?;
                RandomAccessStreamReference::CreateFromStream(&thumbnail)?
            };

        updater.SetThumbnail(&pic_stream_ref)?;

        updater.Update()?;

        if !(self._smtc.IsEnabled()?) {
            self._smtc.SetIsEnabled(true)?;
        }

        Ok(())
    }
}
