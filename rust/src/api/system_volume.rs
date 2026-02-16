use crate::frb_generated::StreamSink;
use anyhow::Result;
use flutter_rust_bridge::frb;

#[cfg(all(not(frb_expand), target_os = "windows"))]
mod imp {
    use std::sync::{Arc, Mutex};

    use crate::frb_generated::StreamSink;
    use anyhow::Result;
    use windows::{
        core::{implement, GUID, PCWSTR},
        Win32::{
            Media::Audio::{
                eMultimedia, eRender,
                Endpoints::{
                    IAudioEndpointVolume, IAudioEndpointVolumeCallback, IAudioEndpointVolumeCallback_Impl,
                },
                IMMDeviceEnumerator, IMMNotificationClient, IMMNotificationClient_Impl, MMDeviceEnumerator,
                AUDIO_VOLUME_NOTIFICATION_DATA, DEVICE_STATE, EDataFlow, ERole,
            },
            System::Com::{
                CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED,
            },
        },
    };

    struct ComGuard;

    impl ComGuard {
        fn new() -> Result<Self> {
            unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).ok() }?;
            Ok(ComGuard)
        }
    }

    impl Drop for ComGuard {
        fn drop(&mut self) {
            unsafe { CoUninitialize() };
        }
    }

    #[implement(IAudioEndpointVolumeCallback)]
    struct VolumeChangeCallback {
        sink: Arc<Mutex<Option<StreamSink<f64>>>>,
    }

    impl IAudioEndpointVolumeCallback_Impl for VolumeChangeCallback {
        fn OnNotify(
            &self,
            pnotify: *mut AUDIO_VOLUME_NOTIFICATION_DATA,
        ) -> windows::core::Result<()> {
            if let Some(data) = unsafe { pnotify.as_ref() } {
                let volume = data.fMasterVolume;
                if let Ok(guard) = self.sink.lock() {
                    if let Some(sink) = guard.as_ref() {
                        let _ = sink.add(volume as f64);
                    }
                }
            }
            Ok(())
        }
    }

    #[implement(IMMNotificationClient)]
    struct DeviceChangeCallback {
        manager: Arc<Mutex<Option<VolumeManager>>>,
    }

    impl IMMNotificationClient_Impl for DeviceChangeCallback {
        fn OnDeviceStateChanged(
            &self,
            _pwstrdeviceid: &PCWSTR,
            _dwnewstate: DEVICE_STATE,
        ) -> windows::core::Result<()> {
            Ok(())
        }

        fn OnDeviceAdded(&self, _pwstrdeviceid: &PCWSTR) -> windows::core::Result<()> {
            Ok(())
        }

        fn OnDeviceRemoved(&self, _pwstrdeviceid: &PCWSTR) -> windows::core::Result<()> {
            Ok(())
        }

        fn OnDefaultDeviceChanged(
            &self,
            flow: EDataFlow,
            role: ERole,
            _pwstrdefaultdeviceid: &PCWSTR,
        ) -> windows::core::Result<()> {
            if flow == eRender && role == eMultimedia {
                if let Ok(mut guard) = self.manager.lock() {
                    if let Some(manager) = guard.as_mut() {
                        let _ = manager.rebind_volume_interface();
                    }
                }
            }
            Ok(())
        }

        fn OnPropertyValueChanged(
            &self,
            _pwstrdeviceid: &PCWSTR,
            _key: &windows::Win32::UI::Shell::PropertiesSystem::PROPERTYKEY,
        ) -> windows::core::Result<()> {
            Ok(())
        }
    }

    struct VolumeManager {
        enumerator: IMMDeviceEnumerator,
        endpoint_volume: Option<IAudioEndpointVolume>,
        volume_callback: Option<IAudioEndpointVolumeCallback>,
        device_notification_client: Option<IMMNotificationClient>,
        sink: Arc<Mutex<Option<StreamSink<f64>>>>,
    }

    unsafe impl Send for VolumeManager {}
    unsafe impl Sync for VolumeManager {}

    impl VolumeManager {
        fn new(sink: Arc<Mutex<Option<StreamSink<f64>>>>) -> Result<Self> {
            let enumerator: IMMDeviceEnumerator =
                unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)? };

            let mut manager = Self {
                enumerator,
                endpoint_volume: None,
                volume_callback: None,
                device_notification_client: None,
                sink,
            };

            manager.init_volume_interface()?;
            Ok(manager)
        }

        fn init_volume_interface(&mut self) -> Result<()> {
            unsafe {
                let device = self.enumerator.GetDefaultAudioEndpoint(eRender, eMultimedia)?;
                let endpoint_volume: IAudioEndpointVolume = device.Activate(CLSCTX_ALL, None)?;

                let callback = VolumeChangeCallback {
                    sink: self.sink.clone(),
                };
                let i_callback: IAudioEndpointVolumeCallback = callback.into();
                endpoint_volume.RegisterControlChangeNotify(&i_callback)?;

                self.endpoint_volume = Some(endpoint_volume);
                self.volume_callback = Some(i_callback);
            }
            Ok(())
        }

        fn rebind_volume_interface(&mut self) -> Result<()> {
            unsafe {
                if let Some(ref endpoint) = self.endpoint_volume {
                    if let Some(ref callback) = self.volume_callback {
                        let _ = endpoint.UnregisterControlChangeNotify(callback);
                    }
                }
            }

            self.endpoint_volume = None;
            self.volume_callback = None;

            if let Err(e) = self.init_volume_interface() {
                if let Ok(guard) = self.sink.lock() {
                    if let Some(sink) = guard.as_ref() {
                        let _ = sink.add(0.0);
                    }
                }
                return Err(e);
            }

            if let Some(vol) = self.get_volume() {
                if let Ok(guard) = self.sink.lock() {
                    if let Some(sink) = guard.as_ref() {
                        let _ = sink.add(vol as f64);
                    }
                }
            }

            Ok(())
        }

        fn register_device_notification(
            &mut self,
            self_arc: Arc<Mutex<Option<VolumeManager>>>,
        ) -> Result<()> {
            let client = DeviceChangeCallback { manager: self_arc };
            let i_client: IMMNotificationClient = client.into();
            unsafe {
                self.enumerator.RegisterEndpointNotificationCallback(&i_client)?;
            }
            self.device_notification_client = Some(i_client);
            Ok(())
        }

        fn get_volume(&self) -> Option<f32> {
            unsafe {
                self.endpoint_volume
                    .as_ref()
                    .and_then(|v| v.GetMasterVolumeLevelScalar().ok())
            }
        }

        fn set_volume(&self, val: f32) -> Result<()> {
            unsafe {
                if let Some(ref v) = self.endpoint_volume {
                    v.SetMasterVolumeLevelScalar(val, &GUID::zeroed())?;
                }
            }
            Ok(())
        }
    }

    impl Drop for VolumeManager {
        fn drop(&mut self) {
            unsafe {
                if let Some(ref endpoint) = self.endpoint_volume {
                    if let Some(ref callback) = self.volume_callback {
                        let _ = endpoint.UnregisterControlChangeNotify(callback);
                    }
                }
                if let Some(ref client) = self.device_notification_client {
                    let _ = self
                        .enumerator
                        .UnregisterEndpointNotificationCallback(client);
                }
            }
        }
    }

    static GLOBAL_MANAGER: Mutex<Option<Arc<Mutex<Option<VolumeManager>>>>> = Mutex::new(None);

    pub(super) fn system_volume_init(sink: StreamSink<f64>) -> Result<f64> {
        let _ = ComGuard::new();

        let sink_arc = Arc::new(Mutex::new(Some(sink)));
        let manager = VolumeManager::new(sink_arc.clone())?;
        let current_vol = manager.get_volume().unwrap_or(0.0) as f64;

        let manager_arc = Arc::new(Mutex::new(Some(manager)));

        if let Ok(mut guard) = manager_arc.lock() {
            if let Some(m) = guard.as_mut() {
                m.register_device_notification(manager_arc.clone())?;
            }
        }

        *GLOBAL_MANAGER.lock().unwrap() = Some(manager_arc);
        Ok(current_vol)
    }

    pub(super) fn system_volume_set(val: f64) -> Result<()> {
        let _ = ComGuard::new();
        if let Some(manager_arc) = GLOBAL_MANAGER.lock().unwrap().as_ref() {
            if let Ok(guard) = manager_arc.lock() {
                if let Some(manager) = guard.as_ref() {
                    manager.set_volume(val as f32)?;
                }
            }
        }
        Ok(())
    }

    pub(super) fn system_volume_get() -> Result<f64> {
        let _ = ComGuard::new();
        if let Some(manager_arc) = GLOBAL_MANAGER.lock().unwrap().as_ref() {
            if let Ok(guard) = manager_arc.lock() {
                if let Some(manager) = guard.as_ref() {
                    return Ok(manager.get_volume().unwrap_or(0.0) as f64);
                }
            }
        }
        Ok(0.0)
    }

    pub(super) fn system_volume_dispose() {
        *GLOBAL_MANAGER.lock().unwrap() = None;
    }
}

#[cfg(any(frb_expand, not(target_os = "windows")))]
mod imp {
    use crate::frb_generated::StreamSink;
    use anyhow::Result;

    pub(super) fn system_volume_init(_sink: StreamSink<f64>) -> Result<f64> {
        Ok(0.0)
    }

    pub(super) fn system_volume_set(_val: f64) -> Result<()> {
        Ok(())
    }

    pub(super) fn system_volume_get() -> Result<f64> {
        Ok(0.0)
    }

    pub(super) fn system_volume_dispose() {}
}

#[frb(sync)]
pub fn system_volume_init(sink: StreamSink<f64>) -> Result<f64> {
    imp::system_volume_init(sink)
}

#[frb(sync)]
pub fn system_volume_set(val: f64) -> Result<()> {
    imp::system_volume_set(val)
}

#[frb(sync)]
pub fn system_volume_get() -> Result<f64> {
    imp::system_volume_get()
}

#[frb(sync)]
pub fn system_volume_dispose() {
    imp::system_volume_dispose()
}
