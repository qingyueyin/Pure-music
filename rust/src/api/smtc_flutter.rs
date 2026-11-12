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
            CreateWindowExW, DefWindowProcW, DestroyWindow, FindWindowExW,
            GetWindowThreadProcessId, RegisterClassW, WINDOW_EX_STYLE, WNDCLASSW, WS_POPUP,
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

use super::tag_reader;

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

/// 缩略图任务：本地曲目从文件路径抠内嵌封面；远程曲目没有真实文件，
/// 由 Dart 侧取到封面字节后直接喂进来。
enum ThumbnailJob {
    Path(String),
    Bytes { path: String, data: Vec<u8> },
}

pub struct SMTCFlutter {
    _smtc: SystemMediaTransportControls,
    /// 时间轴属性每秒更新一次，复用同一个对象，避免每秒新建 WinRT 实例。
    timeline_properties: SystemMediaTransportControlsTimelineProperties,
    hidden_window: Option<HWND>,
    duration_ms: Mutex<u32>,
    progress_ms: AtomicU64,
    last_path: Arc<Mutex<Option<String>>>,
    last_title: Mutex<Option<String>>,
    last_artist: Mutex<Option<String>>,
    last_album: Mutex<Option<String>>,
    button_pressed_token: Mutex<Option<EventRegistrationToken>>,
    position_change_token: Mutex<Option<EventRegistrationToken>>,
    display_revision: Arc<AtomicU64>,
    display_lock: Arc<Mutex<()>>,
    thumbnail_pending: Arc<Mutex<Option<(ThumbnailJob, u64)>>>,
    thumbnail_wake: Arc<Condvar>,
    thumbnail_closed: Arc<AtomicBool>,
    thumbnail_applied_path: Arc<Mutex<Option<String>>>,
}

/// 同一首歌的封面已经交过就不要再解码。
pub(crate) fn should_queue_smtc_thumbnail(applied_path: Option<&str>, path: &str) -> bool {
    applied_path != Some(path)
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
        log::debug!(target: "smtc", "SMTC: Subscribing to control events...");

        let smtc_clone = self._smtc.clone();
        let is_enabled = smtc_clone.IsEnabled().unwrap_or(false);
        log::debug!(target: "smtc", "SMTC: IsEnabled={}", is_enabled);

        let is_playing_enabled = smtc_clone.IsPlayEnabled().unwrap_or(false);
        let is_pause_enabled = smtc_clone.IsPauseEnabled().unwrap_or(false);
        let is_next_enabled = smtc_clone.IsNextEnabled().unwrap_or(false);
        let is_previous_enabled = smtc_clone.IsPreviousEnabled().unwrap_or(false);
        log::debug!(
            target: "smtc",
            "SMTC: Play={}, Pause={}, Next={}, Previous={}",
            is_playing_enabled,
            is_pause_enabled,
            is_next_enabled,
            is_previous_enabled
        );

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
                        log::info!(target: "smtc", "SMTC: Button pressed - {:?}", event);
                        let _ = sink.add(event);
                    }
                }
                Ok(())
            }));
            match token {
                Ok(token) => *token_slot = Some(token),
                Err(error) => log::warn!(
                    target: "smtc",
                    "SMTC: ButtonPressed subscription failed: {}",
                    error
                ),
            }
        }

        log::debug!(target: "smtc", "SMTC: Subscription complete");
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
                Err(error) => log::warn!(
                    target: "smtc",
                    "SMTC: position subscription failed: {}",
                    error
                ),
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

    /// 直接以图片字节更新缩略图。远程曲目没有本地文件可抠内嵌封面，
    /// 由 Dart 侧取到封面字节后调用这里；晚到的字节按曲目路径判废。
    pub fn queue_thumbnail_bytes(&self, path: String, bytes: Vec<u8>) {
        let revision = self.display_revision.load(Ordering::SeqCst);
        self._queue_thumbnail_job(ThumbnailJob::Bytes { path, data: bytes }, revision);
    }

    /// 系统在会话挂起（最小化/后台）时会静默丢弃 DisplayUpdater 更新。
    /// 通过往返切换 PlaybackStatus 强制系统端重新评估会话并重绘显示。
    pub fn refresh_display(&self) -> Result<(), String> {
        self._refresh_display().map_err(|error| error.to_string())
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

impl Drop for SMTCFlutter {
    fn drop(&mut self) {
        self.thumbnail_closed.store(true, Ordering::Release);
        if let Ok(mut pending) = self.thumbnail_pending.lock() {
            *pending = None;
            self.thumbnail_wake.notify_one();
        }
        self.destroy_hidden_window();
    }
}

impl SMTCFlutter {
    fn destroy_hidden_window(&mut self) {
        let Some(hwnd) = self.hidden_window.take() else {
            return;
        };
        if let Err(error) = unsafe { DestroyWindow(hwnd) } {
            log::warn!(
                target: "smtc",
                "SMTC: hidden window destroy failed: {}",
                error
            );
        }
    }

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

    /// 获取 SMTC 绑定的窗口：优先本进程的主窗口（系统媒体控件会显示在
    /// 主窗口的任务栏缩略图上），主窗口尚未创建时回退到隐藏窗口。
    fn _get_smtc_window() -> Result<(HWND, bool), windows::core::Error> {
        const MAIN_CLASS_NAME: &str = "FLUTTER_RUNNER_WIN32_WINDOW";
        unsafe {
            let class_name: HSTRING = HSTRING::from(MAIN_CLASS_NAME);
            let current_process_id = std::process::id();
            let mut previous = HWND::default();
            loop {
                let hwnd = FindWindowExW(
                    HWND::default(),
                    previous,
                    PCWSTR(class_name.as_ptr()),
                    PCWSTR::null(),
                );
                if hwnd.0 == 0 {
                    break;
                }
                let mut process_id = 0u32;
                GetWindowThreadProcessId(hwnd, Some(&mut process_id));
                if process_id == current_process_id {
                    log::debug!(target: "smtc", "SMTC: bound to main window HWND={}", hwnd.0);
                    return Ok((hwnd, false));
                }
                previous = hwnd;
            }
        }
        let hidden = Self::_create_hidden_smtc_window()?;
        log::warn!(
            target: "smtc",
            "SMTC: main window not found, bound to hidden HWND={}",
            hidden.0
        );
        Ok((hidden, true))
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
        let (hwnd, created_hidden) = Self::_get_smtc_window()?;
        let interop =
            factory::<SystemMediaTransportControls, ISystemMediaTransportControlsInterop>()?;
        let _smtc: SystemMediaTransportControls = unsafe { interop.GetForWindow(hwnd) }?;
        Self::_init_controls(&_smtc)?;

        let display_revision = Arc::new(AtomicU64::new(0));
        let display_lock = Arc::new(Mutex::new(()));
        let last_path = Arc::new(Mutex::new(None));
        // 已解析的缩略图字节（路径 → 图片）只活在工人线程里：
        // 刷新显示时按路径命中复用，远程曲目不必等 Dart 再喂一次。
        let thumbnail_picture = Arc::new(Mutex::new(None));
        let thumbnail_applied_path = Arc::new(Mutex::new(None));
        let (thumbnail_pending, thumbnail_wake, thumbnail_closed) = Self::_start_thumbnail_worker(
            _smtc.clone(),
            Arc::clone(&display_revision),
            Arc::clone(&display_lock),
            Arc::clone(&last_path),
            Arc::clone(&thumbnail_picture),
            Arc::clone(&thumbnail_applied_path),
        );

        Ok(Self {
            _smtc,
            timeline_properties: SystemMediaTransportControlsTimelineProperties::new()?,
            hidden_window: created_hidden.then_some(hwnd),
            duration_ms: Mutex::new(0),
            progress_ms: AtomicU64::new(0),
            last_path,
            last_title: Mutex::new(None),
            last_artist: Mutex::new(None),
            last_album: Mutex::new(None),
            button_pressed_token: Mutex::new(None),
            position_change_token: Mutex::new(None),
            display_revision,
            display_lock,
            thumbnail_pending,
            thumbnail_wake,
            thumbnail_closed,
            thumbnail_applied_path,
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
        let time_properties = &self.timeline_properties;
        time_properties.SetPosition(TimeSpan::from(Duration::from_millis(progress.into())))?;
        time_properties.SetEndTime(TimeSpan::from(Duration::from_millis(dur.into())))?;
        time_properties.SetMinSeekTime(TimeSpan { Duration: 0 })?;
        time_properties.SetMaxSeekTime(TimeSpan::from(Duration::from_millis(dur.into())))?;
        self._smtc.UpdateTimelineProperties(time_properties)?;
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
                log::warn!(
                    target: "smtc",
                    "SMTC: UpdateTimelineProperties err (non-fatal): {}",
                    e
                );
            }
        }

        if !(self._smtc.IsEnabled()?) {
            self._smtc.SetIsEnabled(true)?;
        }
        updater.Update()?;

        log::info!(target: "smtc", "SMTC: Display updated - {}", title);
        drop(display_guard);
        if let Ok(mut slot) = self.last_path.lock() {
            *slot = Some(path.to_string());
        }
        if let Ok(mut slot) = self.last_title.lock() {
            *slot = Some(title.to_string());
        }
        if let Ok(mut slot) = self.last_artist.lock() {
            *slot = Some(artist.to_string());
        }
        if let Ok(mut slot) = self.last_album.lock() {
            *slot = Some(album.to_string());
        }
        self._queue_thumbnail_update(path, revision);

        Ok(())
    }

    /// 强制系统端重绘媒体会话显示：往返切换 IsEnabled + PlaybackStatus，
    /// 再重放当前元数据、时间线与缩略图。用于会话被系统挂起后解冻显示。
    fn _refresh_display(&self) -> Result<(), windows::core::Error> {
        let _display_guard = match self.display_lock.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        let revision = self.display_revision.fetch_add(1, Ordering::SeqCst) + 1;
        let current_status = self._smtc.PlaybackStatus()?;

        // 往返禁用再启用，强制系统重新注册并重绘会话
        self._smtc.SetIsEnabled(false)?;
        self._smtc.SetPlaybackStatus(MediaPlaybackStatus::Stopped)?;
        self._smtc.SetIsEnabled(true)?;
        self._smtc.SetPlaybackStatus(current_status)?;

        // 重放时间线
        let dur = match self.duration_ms.lock() {
            Ok(value) => *value,
            Err(poisoned) => *poisoned.into_inner(),
        };
        let progress = self.progress_ms.load(Ordering::Acquire).min(dur as u64) as u32;
        if let Ok(time_properties) = SystemMediaTransportControlsTimelineProperties::new() {
            let _ = time_properties.SetStartTime(TimeSpan { Duration: 0 });
            let _ = time_properties.SetEndTime(TimeSpan::from(Duration::from_millis(dur.into())));
            let _ = time_properties.SetMinSeekTime(TimeSpan { Duration: 0 });
            let _ =
                time_properties.SetMaxSeekTime(TimeSpan::from(Duration::from_millis(dur.into())));
            let _ =
                time_properties.SetPosition(TimeSpan::from(Duration::from_millis(progress.into())));
            let _ = self._smtc.UpdateTimelineProperties(&time_properties);
        }

        // 重放当前元数据
        let title = self
            .last_title
            .lock()
            .ok()
            .and_then(|guard| guard.clone())
            .unwrap_or_default();
        let artist = self
            .last_artist
            .lock()
            .ok()
            .and_then(|guard| guard.clone())
            .unwrap_or_default();
        let album = self
            .last_album
            .lock()
            .ok()
            .and_then(|guard| guard.clone())
            .unwrap_or_default();
        let updater = self._smtc.DisplayUpdater()?;
        updater.SetType(MediaPlaybackType::Music)?;
        if let Ok(music_properties) = updater.MusicProperties() {
            let _ = music_properties.SetTitle(&HSTRING::from(&title));
            let _ = music_properties.SetArtist(&HSTRING::from(&artist));
            let _ = music_properties.SetAlbumTitle(&HSTRING::from(&album));
        }
        updater.Update()?;
        log::debug!(target: "smtc", "SMTC: Display refreshed - {}", title);

        let path = self.last_path.lock().ok().and_then(|guard| guard.clone());
        if let Some(path) = path {
            self._queue_thumbnail_update(HSTRING::from(path), revision);
        }

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
        if let Ok(mut applied) = self.thumbnail_applied_path.lock() {
            *applied = None;
        }
        self._smtc.SetPlaybackStatus(MediaPlaybackStatus::Stopped)?;
        self._smtc.SetIsEnabled(false)?;
        Ok(())
    }

    fn _queue_thumbnail_update(&self, path: HSTRING, revision: u64) {
        let path_string = path.to_string();
        // 同一首歌的封面已经提交过就不再解码（main 的防重复提交）。
        if let Ok(applied) = self.thumbnail_applied_path.lock() {
            if !should_queue_smtc_thumbnail(applied.as_deref(), &path_string) {
                return;
            }
        }
        self._queue_thumbnail_job(ThumbnailJob::Path(path_string), revision);
    }

    fn _queue_thumbnail_job(&self, job: ThumbnailJob, revision: u64) {
        if let Ok(mut pending) = self.thumbnail_pending.lock() {
            if self.thumbnail_closed.load(Ordering::Acquire) {
                return;
            }
            *pending = Some((job, revision));
            self.thumbnail_wake.notify_one();
        }
    }

    /// 等待并取出下一个待处理的缩略图任务，worker 已关闭时返回 None
    fn _wait_for_job(
        pending: &Mutex<Option<(ThumbnailJob, u64)>>,
        wake: &Condvar,
        closed: &AtomicBool,
    ) -> Option<(ThumbnailJob, u64)> {
        loop {
            let mut guard = match pending.lock() {
                Ok(guard) => guard,
                Err(poisoned) => poisoned.into_inner(),
            };
            while guard.is_none() && !closed.load(Ordering::Acquire) {
                guard = match wake.wait(guard) {
                    Ok(guard) => guard,
                    Err(poisoned) => poisoned.into_inner(),
                };
            }
            if closed.load(Ordering::Acquire) {
                return None;
            }
            if let Some(job) = guard.take() {
                return Some(job);
            }
        }
    }

    /// 将缩略图（或清空）应用到 SMTC DisplayUpdater 并提交更新
    fn _apply_thumbnail(
        smtc: &SystemMediaTransportControls,
        thumbnail: Option<RandomAccessStreamReference>,
    ) -> Result<(), windows::core::Error> {
        let updater = smtc.DisplayUpdater()?;
        match thumbnail {
            Some(thumbnail) => updater.SetThumbnail(&thumbnail)?,
            None => updater.SetThumbnail(None::<&RandomAccessStreamReference>)?,
        }
        updater.Update()?;
        Ok(())
    }

    /// 解析缩略图图片字节：字节任务直接用；路径任务先查缓存，
    /// 未命中再从文件抠内嵌封面（远程假路径会抠空，返回 None）。
    fn _resolve_thumbnail(
        job: &ThumbnailJob,
        picture_cache: &Mutex<Option<(String, Vec<u8>)>>,
    ) -> Option<Vec<u8>> {
        match job {
            ThumbnailJob::Bytes { data, .. } => Some(data.clone()),
            ThumbnailJob::Path(path) => {
                let cached = match picture_cache.lock() {
                    Ok(guard) => guard.as_ref().and_then(|(cached_path, data)| {
                        (cached_path == path).then(|| data.clone())
                    }),
                    Err(_) => None,
                };
                cached.or_else(|| {
                    tag_reader::get_embedded_picture_from_path(path, 256, 256)
                })
            }
        }
    }

    fn _start_thumbnail_worker(
        smtc: SystemMediaTransportControls,
        display_revision: Arc<AtomicU64>,
        display_lock: Arc<Mutex<()>>,
        last_path: Arc<Mutex<Option<String>>>,
        picture_cache: Arc<Mutex<Option<(String, Vec<u8>)>>>,
        thumbnail_applied_path: Arc<Mutex<Option<String>>>,
    ) -> (
        Arc<Mutex<Option<(ThumbnailJob, u64)>>>,
        Arc<Condvar>,
        Arc<AtomicBool>,
    ) {
        let pending = Arc::new(Mutex::new(None::<(ThumbnailJob, u64)>));
        let wake = Arc::new(Condvar::new());
        let closed = Arc::new(AtomicBool::new(false));
        let worker_pending = Arc::clone(&pending);
        let worker_wake = Arc::clone(&wake);
        let worker_closed = Arc::clone(&closed);
        let worker_applied_path = Arc::clone(&thumbnail_applied_path);
        let spawn_result = std::thread::Builder::new()
            .name("smtc-thumbnail".to_string())
            .spawn(move || {
                if let Err(error) = unsafe { RoInitialize(RO_INIT_MULTITHREADED) } {
                    log::warn!(
                        target: "smtc",
                        "SMTC: thumbnail worker init failed: {}",
                        error
                    );
                    worker_closed.store(true, Ordering::Release);
                    return;
                }
                let _winrt_guard = WinRtThreadGuard;
                loop {
                    let job =
                        match Self::_wait_for_job(&worker_pending, &worker_wake, &worker_closed) {
                            Some(job) => job,
                            None => return,
                        };
                    let (job_path, picture) = match &job.0 {
                        ThumbnailJob::Path(path) => {
                            (path.clone(), Self::_resolve_thumbnail(&job.0, &picture_cache))
                        }
                        ThumbnailJob::Bytes { path, .. } => {
                            (path.clone(), Self::_resolve_thumbnail(&job.0, &picture_cache))
                        }
                    };
                    let _display_guard = match display_lock.lock() {
                        Ok(guard) => guard,
                        Err(poisoned) => poisoned.into_inner(),
                    };
                    if display_revision.load(Ordering::Acquire) != job.1 {
                        continue;
                    }
                    // 封面抓取是异步的：曲目已经切走的字节直接丢弃。
                    let current = match last_path.lock() {
                        Ok(guard) => guard.clone(),
                        Err(poisoned) => poisoned.into_inner().clone(),
                    };
                    if current.as_deref() != Some(job_path.as_str()) {
                        continue;
                    }
                    if let Some(data) = &picture {
                        if let Ok(mut cache) = picture_cache.lock() {
                            *cache = Some((job_path.clone(), data.clone()));
                        }
                    }
                    let thumbnail = match &picture {
                        Some(data) => match Self::_ras_ref_from_pic_data(data) {
                            Ok(reference) => Some(reference),
                            Err(error) => {
                                log::warn!(
                                    target: "smtc",
                                    "SMTC: thumbnail decode err: {}",
                                    error
                                );
                                None
                            }
                        },
                        None => None,
                    };
                    if let Err(error) = Self::_apply_thumbnail(&smtc, thumbnail) {
                        log::warn!(target: "smtc", "SMTC: thumbnail update err: {}", error);
                        continue;
                    }
                    if let Ok(mut applied) = worker_applied_path.lock() {
                        *applied = Some(job_path);
                    }
                }
            });
        if let Err(error) = spawn_result {
            log::warn!(target: "smtc", "SMTC: thumbnail worker failed: {}", error);
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
}

#[cfg(test)]
mod tests {
    use super::should_queue_smtc_thumbnail;

    #[test]
    fn same_track_does_not_decode_artwork_again() {
        assert!(!should_queue_smtc_thumbnail(Some("a.flac"), "a.flac"));
        assert!(should_queue_smtc_thumbnail(None, "a.flac"));
        assert!(should_queue_smtc_thumbnail(Some("a.flac"), "b.flac"));
    }
}
