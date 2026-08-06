// show a file in explorer,
// select a directory path,
// open a link in browser, ...

use windows::{
    core::{h, Interface, HSTRING},
    Foundation::Uri,
    Storage::{Pickers::FolderPicker, StorageFile},
    System::{FolderLauncherOptions, Launcher},
    Win32::UI::{Shell::IInitializeWithWindow, WindowsAndMessaging::GetForegroundWindow},
};

use super::logger::log_to_dart;

/// path: 文件或文件夹的绝对路径。
/// 会打开父级目录并选择路径指向的项。
pub fn show_in_explorer(path: String) -> bool {
    match _show_in_explorer(path) {
        Ok(val) => val,
        Err(err) => {
            log_to_dart(format!("fail to show in explorer: {}", err));
            false
        }
    }
}

fn _show_in_explorer(path: String) -> Result<bool, windows::core::Error> {
    let file = StorageFile::GetFileFromPathAsync(&HSTRING::from(path))?.get()?;

    let options: FolderLauncherOptions = FolderLauncherOptions::new()?;
    let select_items = options.ItemsToSelect()?;
    select_items.Append(&file)?;

    Launcher::LaunchFolderPathWithOptionsAsync(&file.GetParentAsync()?.get()?.Path()?, &options)?
        .get()
}

pub fn pick_single_folder() -> Option<String> {
    _pick_single_folder().ok()
}

fn _pick_single_folder() -> Result<String, windows::core::Error> {
    let folder_picker = FolderPicker::new()?;

    unsafe {
        let hwnd = GetForegroundWindow();
        // 文件夹选择器创建后必须绑定当前前台窗口。
        let initialize_with_window = folder_picker.cast::<IInitializeWithWindow>()?;
        initialize_with_window.Initialize(hwnd)?;
    }

    folder_picker.FileTypeFilter()?.Append(h!("*"))?;
    let folder = folder_picker.PickSingleFolderAsync()?.get()?;

    Ok(folder.Path()?.to_string())
}

pub fn launch_in_browser(uri: String) -> bool {
    match _launch_in_browser(uri) {
        Ok(val) => val,
        Err(err) => {
            log_to_dart(format!("fail to launch in browser: {}", err));
            false
        }
    }
}

fn _launch_in_browser(uri: String) -> Result<bool, windows::core::Error> {
    let uri = uri.trim();
    let lower = uri.to_ascii_lowercase();
    if !lower.starts_with("https://") && !lower.starts_with("http://") {
        log_to_dart("blocked unsupported browser uri".to_string());
        return Ok(false);
    }

    Launcher::LaunchUriAsync(&Uri::CreateUri(&HSTRING::from(uri))?)?.get()
}
