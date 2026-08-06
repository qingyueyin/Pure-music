use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc, Condvar, Mutex,
};
use std::time::Duration;

use flutter_rust_bridge::frb;
use windows::{
    core::{factory, HSTRING, PCWSTR},
    Foundation::{EventRegistrationToken, TimeSpan, TypedEventHandler},
    Media::{
        MediaPlaybackStatus, MediaPlaybackType, PlaybackPositionChangeRequestedEventArgs,
        SystemMediaTransportControls, SystemMediaTransportControlsButton,
        SystemMediaTransportControlsButtonPressedEventArgs,
        SystemMediaTransportControlsTimelineProperties,
    },
    Storage::Streams::{DataWriter, InMemoryRandomAccessStream, RandomAccessStreamReference},
    Win32::{
        Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM},
        System::{
            LibraryLoader::GetModuleHandleW,
            WinRT::{
                ISystemMediaTransportControlsInterop, RoInitialize, RoUninitialize,
                RO_INIT_MULTITHREADED,
            },
        },
        UI::WindowsAndMessaging::{
            CreateWindowExW, DefWindowProcW, RegisterClassW, WINDOW_EX_STYLE, WNDCLASSW, WS_POPUP,
        },
    },
};

struct WinRtThreadGuard;

impl Drop for WinRtThreadGuard {
    fn drop(&mut self) {
        unsafe { RoUninitialize() };
    }
}

use crate::frb_generated::StreamSink;

use super::{logger::log_to_dart, tag_reader};

/// 创建一个永不显示的隐藏窗口，SMTC 绑定到它而不是主窗口，
/// 这样窗口最小化后系统端媒体会话不会冻结
unsafe extern "system" fn hidden_window_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    DefWindowProcW(hwnd, msg, wparam, lparam)
}

pub struct SMTCFlutter {
    _smtc: SystemMediaTransportControls,
    duration_ms: Mutex<u32>,
    progress_ms: AtomicU64,
    button_pressed_token: Mutex<Option<EventRegistrationToken>>,
    position_change_token: Mutex<Option<EventRegistrationToken>>,
    display_revision: Arc<AtomicU64>,
    display_lock: Arc<Mutex<()>>,
    thumbnail_pending: Arc<Mutex<Option<(String, u64)>>>,
    thumbnail_wake: Arc<Condvar>,
    thumbnail_closed: Arc<AtomicBool>,
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

pub struct SMTCDebugSnapshot {
    pub enabled: bool,
    pub play_enabled: bool,
    pub pause_enabled: bool,
    pub previous_enabled: bool,
    pub next_enabled: bool,
    pub stop_enabled: bool,
    pub playback_status: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: u32,
    pub progress_ms: u64,
}

/// Apis for Flutter
impl SMTCFlutter {
    #[frb(sync)]
    pub fn new() -> Result<Self, String> {
        Self::_new().map_err(|error| error.to_string())
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
        log_to_dart(format!(
            "SMTC: Play={}, Pause={}, Next={}, Previous={}",
            is_playing_enabled, is_pause_enabled, is_next_enabled, is_previous_enabled
        ));

        if let Ok(mut token_slot) = self.button_pressed_token.lock() {
            if let Some(token) = token_slot.take() {
                let _ = self._smtc.RemoveButtonPressed(token);
            }
            let token = self._smtc.ButtonPressed(&TypedEventHandler::<
                SystemMediaTransportControls,
                SystemMediaTransportControlsButtonPressedEventArgs,
            >::new(move |_, event| {
                if let Some(e) = event {
                    if let Ok(button) = e.Button() {
                        let event = match button {
                            SystemMediaTransportControlsButton::Play => SMTCControlEvent::Play,
                            SystemMediaTransportControlsButton::Pause => SMTCControlEvent::Pause,
                            SystemMediaTransportControlsButton::Stop => SMTCControlEvent::Stop,
                            SystemMediaTransportControlsButton::Next => SMTCControlEvent::Next,
                            SystemMediaTransportControlsButton::Previous => {
                                SMTCControlEvent::Previous
                            }
                            _ => SMTCControlEvent::Unknown,
                        };
                        log_to_dart(format!("SMTC: Button pressed - {:?}", event));
                        let _ = sink.add(event);
                    }
                }
                Ok(())
            }));
            match token {
                Ok(token) => *token_slot = Some(token),
                Err(error) => log_to_dart(format!(
                    "SMTC: ButtonPressed subscription failed: {}",
                    error
                )),
            }
        }

        log_to_dart("SMTC: Subscription complete".to_string());
    }

    pub fn subscribe_to_position_change_events(&self, sink: StreamSink<u64>) {
        if let Ok(mut token_slot) = self.position_change_token.lock() {
            if let Some(token) = token_slot.take() {
                let _ = self._smtc.RemovePlaybackPositionChangeRequested(token);
            }
            let token = self
                ._smtc
                .PlaybackPositionChangeRequested(&TypedEventHandler::<
                    SystemMediaTransportControls,
                    PlaybackPositionChangeRequestedEventArgs,
                >::new(move |_, event| {
                    if let Some(event) = event {
                        if let Ok(position) = event.RequestedPlaybackPosition() {
                            let ticks = position.Duration.max(0) as u64;
                            let _ = sink.add(ticks / 10_000);
                        }
                    }
                    Ok(())
                }));
            match token {
                Ok(token) => *token_slot = Some(token),
                Err(error) => log_to_dart(format!("SMTC: position subscription failed: {}", error)),
            }
        }
    }

    pub fn update_state(&self, state: SMTCState) -> Result<(), String> {
        self._update_state(state).map_err(|error| error.to_string())
    }

    /// progress, duration: ms
    pub fn update_time_properties(&self, progress: u32) -> Result<(), String> {
        self._update_time_properties(progress)
            .map_err(|error| error.to_string())
    }

    pub fn update_display(
        &self,
        title: String,
        artist: String,
        album: String,
        duration: u32,
        path: String,
    ) -> Result<(), String> {
        self._update_display(
            HSTRING::from(title),
            HSTRING::from(artist),
            HSTRING::from(album),
            duration,
            HSTRING::from(path),
        )
        .map_err(|error| error.to_string())
    }

    pub fn clear_display(&self) -> Result<(), String> {
        self._clear_display().map_err(|error| error.to_string())
    }

    pub fn debug_snapshot(&self) -> Result<SMTCDebugSnapshot, String> {
        self._debug_snapshot().map_err(|error| error.to_string())
    }

    pub fn close(self) -> Result<(), String> {
        if let Ok(mut token_slot) = self.button_pressed_token.lock() {
            if let Some(token) = token_slot.take() {
                let _ = self._smtc.RemoveButtonPressed(token);
            }
        }
        if let Ok(mut token_slot) = self.position_change_token.lock() {
            if let Some(token) = token_slot.take() {
                let _ = self._smtc.RemovePlaybackPositionChangeRequested(token);
            }
        }
        self.thumbnail_closed.store(true, Ordering::Release);
        if let Ok(mut pending) = self.thumbnail_pending.lock() {
            *pending = None;
            self.thumbnail_wake.notify_one();
        }
        self._clear_display().map_err(|error| error.to_string())
    }
}

impl SMTCFlutter {
    /// 创建隐藏窗口，SMTC 绑定到它而不是可见主窗口：
    /// 主窗口最小化后系统端不会冻结媒体会话显示
    fn _create_hidden_smtc_window() -> Result<HWND, windows::core::Error> {
        const CLASS_NAME: &str = "PureMusicSmtcHiddenWindow";
        unsafe {
            let instance = GetModuleHandleW(PCWSTR::null())?;
            let class_name: HSTRING = HSTRING::from(CLASS_NAME);
            let wnd_class = WNDCLASSW {
                lpfnWndProc: Some(hidden_window_proc),
                hInstance: HINSTANCE(instance.0),
                lpszClassName: PCWSTR(class_name.as_ptr()),
                ..Default::default()
            };
            RegisterClassW(&wnd_class);
            let hwnd = CreateWindowExW(
                WINDOW_EX_STYLE(0),
                &class_name,
                None,
                WS_POPUP,
                0,
                0,
                0,
                0,
                None,
                None,
                HINSTANCE(instance.0),
                None,
            );
            if hwnd.0 == 0 {
                return Err(windows::core::Error::from_win32());
            }
            Ok(hwnd)
        }
    }

    fn _init_controls(smtc: &SystemMediaTransportControls) -> Result<(), windows::core::Error> {
        smtc.SetIsEnabled(false)?;
        smtc.SetIsNextEnabled(true)?;
        smtc.SetIsPauseEnabled(true)?;
        smtc.SetIsPlayEnabled(true)?;
        smtc.SetIsPreviousEnabled(true)?;
        smtc.SetIsStopEnabled(true)?;
        Ok(())
    }

    fn _new() -> Result<Self, windows::core::Error> {
        let hwnd = Self::_create_hidden_smtc_window()?;
        let interop =
            factory::<SystemMediaTransportControls, ISystemMediaTransportControlsInterop>()?;
        let _smtc: SystemMediaTransportControls = unsafe { interop.GetForWindow(hwnd) }?;
        Self::_init_controls(&_smtc)?;
        log_to_dart(format!("SMTC: bound to hidden HWND={}", hwnd.0));

        let display_revision = Arc::new(AtomicU64::new(0));
        let display_lock = Arc::new(Mutex::new(()));
        let (thumbnail_pending, thumbnail_wake, thumbnail_closed) = Self::_start_thumbnail_worker(
            _smtc.clone(),
            Arc::clone(&display_revision),
            Arc::clone(&display_lock),
        );

        Ok(Self {
            _smtc,
            duration_ms: Mutex::new(0),
            progress_ms: AtomicU64::new(0),
            button_pressed_token: Mutex::new(None),
            position_change_token: Mutex::new(None),
            display_revision,
            display_lock,
            thumbnail_pending,
            thumbnail_wake,
            thumbnail_closed,
        })
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
        let dur = match self.duration_ms.lock() {
            Ok(duration) => *duration,
            Err(poisoned) => *poisoned.into_inner(),
        };
        let progress = progress.min(dur);
        let time_properties = SystemMediaTransportControlsTimelineProperties::new()?;
        time_properties.SetPosition(TimeSpan::from(Duration::from_millis(progress.into())))?;
        time_properties.SetEndTime(TimeSpan::from(Duration::from_millis(dur.into())))?;
        time_properties.SetMinSeekTime(TimeSpan { Duration: 0 })?;
        time_properties.SetMaxSeekTime(TimeSpan::from(Duration::from_millis(dur.into())))?;
        self._smtc.UpdateTimelineProperties(&time_properties)?;
        self.progress_ms.store(progress.into(), Ordering::Release);

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
        let display_guard = match self.display_lock.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        let revision = self.display_revision.fetch_add(1, Ordering::SeqCst) + 1;
        let updater = self._smtc.DisplayUpdater()?;
        updater.SetType(MediaPlaybackType::Music)?;

        // 手动设置 MusicProperties（比 CopyFromFileAsync 更快更可靠）
        if let Ok(music_properties) = updater.MusicProperties() {
            let _ = music_properties.SetTitle(&title);
            let _ = music_properties.SetArtist(&artist);
            let _ = music_properties.SetAlbumTitle(&album);
        }

        // 更新时间线（非致命：失败了也继续提交，不丢元数据）
        match self.duration_ms.lock() {
            Ok(mut value) => *value = duration,
            Err(poisoned) => *poisoned.into_inner() = duration,
        }
        self.progress_ms.store(0, Ordering::Release);
        if let Ok(time_properties) = SystemMediaTransportControlsTimelineProperties::new() {
            let _ = time_properties.SetStartTime(TimeSpan { Duration: 0 });
            let _ =
                time_properties.SetEndTime(TimeSpan::from(Duration::from_millis(duration.into())));
            let _ = time_properties.SetMinSeekTime(TimeSpan { Duration: 0 });
            let _ = time_properties
                .SetMaxSeekTime(TimeSpan::from(Duration::from_millis(duration.into())));
            if let Err(e) = self._smtc.UpdateTimelineProperties(&time_properties) {
                log_to_dart(format!(
                    "SMTC: UpdateTimelineProperties err (non-fatal): {}",
                    e
                ));
            }
        }

        if !(self._smtc.IsEnabled()?) {
            self._smtc.SetIsEnabled(true)?;
        }
        updater.Update()?;

        log_to_dart(format!("SMTC: Display updated - {}", title));
        drop(display_guard);
        self._queue_thumbnail_update(path, revision);

        Ok(())
    }

    fn _clear_display(&self) -> Result<(), windows::core::Error> {
        let _display_guard = match self.display_lock.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        self.display_revision.fetch_add(1, Ordering::SeqCst);
        let updater = self._smtc.DisplayUpdater()?;
        updater.ClearAll()?;
        updater.Update()?;
        match self.duration_ms.lock() {
            Ok(mut value) => *value = 0,
            Err(poisoned) => *poisoned.into_inner() = 0,
        }
        self.progress_ms.store(0, Ordering::Release);
        self._smtc.SetPlaybackStatus(MediaPlaybackStatus::Stopped)?;
        self._smtc.SetIsEnabled(false)?;
        Ok(())
    }

    fn _queue_thumbnail_update(&self, path: HSTRING, revision: u64) {
        if let Ok(mut pending) = self.thumbnail_pending.lock() {
            if self.thumbnail_closed.load(Ordering::Acquire) {
                return;
            }
            *pending = Some((path.to_string(), revision));
            self.thumbnail_wake.notify_one();
        }
    }

    fn _start_thumbnail_worker(
        smtc: SystemMediaTransportControls,
        display_revision: Arc<AtomicU64>,
        display_lock: Arc<Mutex<()>>,
    ) -> (
        Arc<Mutex<Option<(String, u64)>>>,
        Arc<Condvar>,
        Arc<AtomicBool>,
    ) {
        let pending = Arc::new(Mutex::new(None::<(String, u64)>));
        let wake = Arc::new(Condvar::new());
        let closed = Arc::new(AtomicBool::new(false));
        let worker_pending = Arc::clone(&pending);
        let worker_wake = Arc::clone(&wake);
        let worker_closed = Arc::clone(&closed);
        let spawn_result = std::thread::Builder::new()
            .name("smtc-thumbnail".to_string())
            .spawn(move || {
                if let Err(error) = unsafe { RoInitialize(RO_INIT_MULTITHREADED) } {
                    log_to_dart(format!("SMTC: thumbnail worker init failed: {}", error));
                    worker_closed.store(true, Ordering::Release);
                    return;
                }
                let _winrt_guard = WinRtThreadGuard;
                loop {
                    let job = {
                        let mut pending = match worker_pending.lock() {
                            Ok(pending) => pending,
                            Err(poisoned) => poisoned.into_inner(),
                        };
                        while pending.is_none() && !worker_closed.load(Ordering::Acquire) {
                            pending = match worker_wake.wait(pending) {
                                Ok(pending) => pending,
                                Err(poisoned) => poisoned.into_inner(),
                            };
                        }
                        if worker_closed.load(Ordering::Acquire) {
                            return;
                        }
                        match pending.take() {
                            Some(job) => job,
                            None => continue,
                        }
                    };
                    let thumbnail = match Self::_try_get_thumbnail(&HSTRING::from(job.0)) {
                        Ok(thumbnail) => thumbnail,
                        Err(error) => {
                            log_to_dart(format!("SMTC: thumbnail err: {}", error));
                            None
                        }
                    };
                    let _display_guard = match display_lock.lock() {
                        Ok(guard) => guard,
                        Err(poisoned) => poisoned.into_inner(),
                    };
                    if display_revision.load(Ordering::Acquire) != job.1 {
                        continue;
                    }
                    let result = (|| -> Result<(), windows::core::Error> {
                        let updater = smtc.DisplayUpdater()?;
                        match thumbnail {
                            Some(thumbnail) => updater.SetThumbnail(&thumbnail)?,
                            None => updater.SetThumbnail(None::<&RandomAccessStreamReference>)?,
                        }
                        updater.Update()?;
                        Ok(())
                    })();
                    if let Err(error) = result {
                        log_to_dart(format!("SMTC: thumbnail update err: {}", error));
                    }
                }
            });
        if let Err(error) = spawn_result {
            log_to_dart(format!("SMTC: thumbnail worker failed: {}", error));
            closed.store(true, Ordering::Release);
        }
        (pending, wake, closed)
    }

    fn _debug_snapshot(&self) -> Result<SMTCDebugSnapshot, windows::core::Error> {
        let updater = self._smtc.DisplayUpdater()?;
        let (title, artist, album) = match updater.MusicProperties() {
            Ok(properties) => (
                properties
                    .Title()
                    .map(|value| value.to_string())
                    .unwrap_or_default(),
                properties
                    .Artist()
                    .map(|value| value.to_string())
                    .unwrap_or_default(),
                properties
                    .AlbumTitle()
                    .map(|value| value.to_string())
                    .unwrap_or_default(),
            ),
            Err(_) => (String::new(), String::new(), String::new()),
        };
        let status = match self._smtc.PlaybackStatus()? {
            MediaPlaybackStatus::Playing => "playing",
            MediaPlaybackStatus::Paused => "paused",
            MediaPlaybackStatus::Stopped => "stopped",
            MediaPlaybackStatus::Changing => "changing",
            MediaPlaybackStatus::Closed => "closed",
            _ => "unknown",
        }
        .to_string();
        let duration_ms = match self.duration_ms.lock() {
            Ok(duration) => *duration,
            Err(poisoned) => *poisoned.into_inner(),
        };
        Ok(SMTCDebugSnapshot {
            enabled: self._smtc.IsEnabled()?,
            play_enabled: self._smtc.IsPlayEnabled()?,
            pause_enabled: self._smtc.IsPauseEnabled()?,
            previous_enabled: self._smtc.IsPreviousEnabled()?,
            next_enabled: self._smtc.IsNextEnabled()?,
            stop_enabled: self._smtc.IsStopEnabled()?,
            playback_status: status,
            title,
            artist,
            album,
            duration_ms,
            progress_ms: self.progress_ms.load(Ordering::Acquire),
        })
    }

    /// 尝试获取缩略图引用，返回 None 表示无缩略图（非错误）
    fn _try_get_thumbnail(
        path: &HSTRING,
    ) -> Result<Option<RandomAccessStreamReference>, windows::core::Error> {
        if let Some(pic_data) =
            tag_reader::get_embedded_picture_from_path(&path.to_string(), 256, 256)
        {
            return Ok(Some(Self::_ras_ref_from_pic_data(&pic_data)?));
        }
        log_to_dart(format!(
            "SMTC: no embedded picture for {}",
            path.to_string()
        ));
        Ok(None)
    }
}
