#include "taskbar_thumbnail.h"

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <string>
#include <utility>

namespace {

constexpr char kChannelName[] = "pure_music/taskbar_thumbnail";
constexpr UINT kPreviousButtonId = 1;
constexpr UINT kPlayPauseButtonId = 2;
constexpr UINT kNextButtonId = 3;
constexpr UINT_PTR kTitleScrollTimerId = 0x5054;
constexpr UINT kTitleScrollIntervalMs = 500;
constexpr UINT_PTR kButtonsRetryTimerId = 0x5055;
constexpr UINT kButtonsRetryIntervalMs = 200;
constexpr int kIconSize = 32;
constexpr int kFallbackCoverSize = 64;

const flutter::EncodableValue* ValueForKey(
    const flutter::EncodableMap& map, const char* key) {
  const auto found = map.find(flutter::EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}

std::optional<int> ReadInt(const flutter::EncodableValue* value) {
  if (value == nullptr) {
    return std::nullopt;
  }
  if (const auto number = std::get_if<int32_t>(value)) {
    return *number;
  }
  if (const auto number = std::get_if<int64_t>(value);
      number != nullptr && *number >= std::numeric_limits<int>::min() &&
      *number <= std::numeric_limits<int>::max()) {
    return static_cast<int>(*number);
  }
  return std::nullopt;
}

const bool* ReadBool(const flutter::EncodableMap& map, const char* key) {
  return std::get_if<bool>(ValueForKey(map, key));
}

const std::string* ReadString(const flutter::EncodableMap& map,
                              const char* key) {
  return std::get_if<std::string>(ValueForKey(map, key));
}

std::optional<std::wstring> Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (length <= 0) {
    return std::nullopt;
  }
  std::wstring result(static_cast<size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    return std::nullopt;
  }
  return result;
}

std::wstring ReadWindowTitle(HWND window) {
  const int length = GetWindowTextLengthW(window);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring result(static_cast<size_t>(length) + 1, L'\0');
  const int copied =
      GetWindowTextW(window, result.data(), static_cast<int>(result.size()));
  result.resize(static_cast<size_t>(std::max(0, copied)));
  return result;
}

void FillRect(std::vector<uint8_t>& pixels, int left, int top, int right,
              int bottom) {
  for (int y = std::max(0, top); y < std::min(kIconSize, bottom); ++y) {
    for (int x = std::max(0, left); x < std::min(kIconSize, right); ++x) {
      const size_t offset =
          (static_cast<size_t>(y) * kIconSize + static_cast<size_t>(x)) * 4;
      pixels[offset] = 0xFF;
      pixels[offset + 1] = 0xFF;
      pixels[offset + 2] = 0xFF;
      pixels[offset + 3] = 0xFF;
    }
  }
}

void FillTriangle(std::vector<uint8_t>& pixels, int ax, int ay, int bx, int by,
                  int cx, int cy) {
  const int min_y = std::max(0, std::min({ay, by, cy}));
  const int max_y = std::min(kIconSize, std::max({ay, by, cy}));
  for (int y = min_y; y < max_y; ++y) {
    const float scan_y = static_cast<float>(y) + 0.5F;
    float left = static_cast<float>(kIconSize);
    float right = 0.0F;
    const std::array<std::array<int, 4>, 3> edges = {
        std::array<int, 4>{ax, ay, bx, by},
        std::array<int, 4>{bx, by, cx, cy},
        std::array<int, 4>{cx, cy, ax, ay}};
    for (const auto& edge : edges) {
      const float y1 = static_cast<float>(edge[1]);
      const float y2 = static_cast<float>(edge[3]);
      if (!((y1 < scan_y && y2 >= scan_y) ||
            (y2 < scan_y && y1 >= scan_y))) {
        continue;
      }
      const float ratio = (scan_y - y1) / (y2 - y1);
      const float x = static_cast<float>(edge[0]) +
                      ratio * static_cast<float>(edge[2] - edge[0]);
      left = std::min(left, x);
      right = std::max(right, x);
    }
    if (right > left) {
      FillRect(pixels, static_cast<int>(std::floor(left)), y,
               static_cast<int>(std::ceil(right)), y + 1);
    }
  }
}

HICON CreateIconFromBgra(const std::vector<uint8_t>& bgra) {
  BITMAPINFO bitmap_info{};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = kIconSize;
  bitmap_info.bmiHeader.biHeight = -kIconSize;
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP color =
      CreateDIBSection(nullptr, &bitmap_info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (color == nullptr || bits == nullptr) {
    if (color != nullptr) {
      DeleteObject(color);
    }
    return nullptr;
  }
  std::memcpy(bits, bgra.data(), bgra.size());
  HBITMAP mask = CreateBitmap(kIconSize, kIconSize, 1, 1, nullptr);
  if (mask == nullptr) {
    DeleteObject(color);
    return nullptr;
  }

  ICONINFO icon_info{};
  icon_info.fIcon = TRUE;
  icon_info.hbmMask = mask;
  icon_info.hbmColor = color;
  HICON icon = CreateIconIndirect(&icon_info);
  DeleteObject(mask);
  DeleteObject(color);
  return icon;
}

std::array<HICON, 4> CreatePlaybackIcons() {
  std::array<HICON, 4> icons{};
  for (size_t index = 0; index < icons.size(); ++index) {
    std::vector<uint8_t> pixels(
        static_cast<size_t>(kIconSize * kIconSize * 4));
    switch (index) {
      case 0:
        FillRect(pixels, 6, 7, 10, 25);
        FillTriangle(pixels, 10, 16, 24, 7, 24, 25);
        break;
      case 1:
        FillTriangle(pixels, 10, 7, 10, 25, 26, 16);
        break;
      case 2:
        FillRect(pixels, 9, 7, 14, 25);
        FillRect(pixels, 18, 7, 23, 25);
        break;
      case 3:
        FillTriangle(pixels, 8, 7, 8, 25, 22, 16);
        FillRect(pixels, 22, 7, 26, 25);
        break;
      default:
        break;
    }
    icons[index] = CreateIconFromBgra(pixels);
  }
  return icons;
}

THUMBBUTTON MakeButton(UINT id, HICON icon, const wchar_t* tooltip,
                       THUMBBUTTONFLAGS flags) {
  THUMBBUTTON button{};
  button.dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
  button.iId = id;
  button.hIcon = icon;
  button.dwFlags = flags;
  wcsncpy_s(button.szTip, tooltip, _TRUNCATE);
  return button;
}

std::array<THUMBBUTTON, 3> MakeButtons(const std::array<HICON, 4>& icons,
                                      bool playing, bool visible,
                                      bool has_track, bool can_skip) {
  const THUMBBUTTONFLAGS skip_flags =
      !visible ? THBF_HIDDEN : (can_skip ? THBF_ENABLED : THBF_DISABLED);
  const THUMBBUTTONFLAGS play_flags =
      !visible ? THBF_HIDDEN : (has_track ? THBF_ENABLED : THBF_DISABLED);
  return {
      MakeButton(kPreviousButtonId, icons[0], L"上一首", skip_flags),
      MakeButton(kPlayPauseButtonId, playing ? icons[2] : icons[1],
                 playing ? L"暂停" : L"播放", play_flags),
      MakeButton(kNextButtonId, icons[3], L"下一首", skip_flags),
  };
}

std::pair<int, int> FitSize(int source_width, int source_height, int max_width,
                            int max_height) {
  if (source_width <= max_width && source_height <= max_height) {
    return {source_width, source_height};
  }
  const double scale = std::min(
      static_cast<double>(max_width) / source_width,
      static_cast<double>(max_height) / source_height);
  return {std::max(1, static_cast<int>(std::round(source_width * scale))),
          std::max(1, static_cast<int>(std::round(source_height * scale)))};
}

std::vector<uint8_t> ScaleBgra(const std::vector<uint8_t>& source,
                               int source_width, int source_height,
                               int target_width, int target_height) {
  std::vector<uint8_t> result(
      static_cast<size_t>(target_width) * target_height * 4);
  for (int y = 0; y < target_height; ++y) {
    const double source_y = target_height > 1
                                ? static_cast<double>(y) * (source_height - 1) /
                                      (target_height - 1)
                                : 0.0;
    const int y0 = static_cast<int>(std::floor(source_y));
    const int y1 = std::min(y0 + 1, source_height - 1);
    const double y_weight = source_y - y0;
    for (int x = 0; x < target_width; ++x) {
      const double source_x = target_width > 1
                                  ? static_cast<double>(x) *
                                        (source_width - 1) / (target_width - 1)
                                  : 0.0;
      const int x0 = static_cast<int>(std::floor(source_x));
      const int x1 = std::min(x0 + 1, source_width - 1);
      const double x_weight = source_x - x0;
      const size_t destination_offset =
          (static_cast<size_t>(y) * target_width + x) * 4;
      for (size_t channel = 0; channel < 4; ++channel) {
        const auto pixel = [&](int px, int py) {
          return source[(static_cast<size_t>(py) * source_width + px) * 4 +
                        channel];
        };
        const double top = pixel(x0, y0) +
                           (pixel(x1, y0) - pixel(x0, y0)) * x_weight;
        const double bottom = pixel(x0, y1) +
                              (pixel(x1, y1) - pixel(x0, y1)) * x_weight;
        result[destination_offset + channel] = static_cast<uint8_t>(
            std::round(top + (bottom - top) * y_weight));
      }
    }
  }
  return result;
}

HBITMAP CreateBitmapFromBgra(const std::vector<uint8_t>& bgra, int width,
                             int height) {
  BITMAPINFO bitmap_info{};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = width;
  bitmap_info.bmiHeader.biHeight = -height;
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP bitmap =
      CreateDIBSection(nullptr, &bitmap_info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bitmap == nullptr || bits == nullptr) {
    if (bitmap != nullptr) {
      DeleteObject(bitmap);
    }
    return nullptr;
  }
  std::memcpy(bits, bgra.data(), bgra.size());
  return bitmap;
}

const std::vector<uint8_t>& FallbackCover() {
  static const std::vector<uint8_t> pixels = [] {
    std::vector<uint8_t> result(
        static_cast<size_t>(kFallbackCoverSize * kFallbackCoverSize * 4));
    for (size_t index = 0; index < result.size(); index += 4) {
      result[index] = 0x48;
      result[index + 1] = 0x48;
      result[index + 2] = 0x48;
      result[index + 3] = 0xFF;
    }
    return result;
  }();
  return pixels;
}

}  // namespace

TaskbarThumbnail::TaskbarThumbnail(flutter::BinaryMessenger* messenger,
                                   HWND window)
    : window_(window),
      taskbar_button_created_message_(
          RegisterWindowMessage(L"TaskbarButtonCreated")),
      original_title_(ReadWindowTitle(window)),
      icons_(CreatePlaybackIcons()),
      channel_(std::make_unique<
               flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName,
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

TaskbarThumbnail::~TaskbarThumbnail() {
  Disable();
  for (HICON icon : icons_) {
    if (icon != nullptr) {
      DestroyIcon(icon);
    }
  }
}

void TaskbarThumbnail::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() == "enable") {
    result->Success(flutter::EncodableValue(Enable()));
  } else if (method_call.method_name() == "disable") {
    Disable();
    result->Success();
  } else if (method_call.method_name() == "setCover") {
    if (SetCover(method_call.arguments())) {
      result->Success();
    } else {
      result->Error("invalid_cover", "Invalid taskbar cover data");
    }
  } else if (method_call.method_name() == "setPlaying") {
    if (SetPlaying(method_call.arguments())) {
      result->Success();
    } else {
      result->Error("invalid_state", "Invalid playback state");
    }
  } else if (method_call.method_name() == "setControls") {
    if (SetControls(method_call.arguments())) {
      result->Success();
    } else {
      result->Error("invalid_controls", "Invalid control state");
    }
  } else if (method_call.method_name() == "setTitle") {
    if (SetTitle(method_call.arguments())) {
      result->Success();
    } else {
      result->Error("invalid_title", "Invalid taskbar title");
    }
  } else {
    result->NotImplemented();
  }
}

bool TaskbarThumbnail::Enable() {
  if (enabled_) {
    return true;
  }
  if (std::any_of(icons_.begin(), icons_.end(),
                  [](HICON icon) { return icon == nullptr; }) ||
      !EnsureTaskbar()) {
    return false;
  }
  // 不启用 iconic：任务栏缩略图与 Peek 保持系统默认的窗口实时预览，
  // 通过 ThumbBar 提供播放控制按钮（普通权限运行下点击正常）。
  enabled_ = true;
  ApplyWindowTitle();
  // 任务栏按钮可能在窗口显示后才创建（TaskbarButtonCreated 消息
  // 可能早于本服务构造而丢失），延迟重试绑定 ThumbBar 按钮。
  SetTimer(window_, kButtonsRetryTimerId, kButtonsRetryIntervalMs, nullptr);
  return true;
}

void TaskbarThumbnail::Disable() {
  if (window_ == nullptr) {
    return;
  }
  KillTimer(window_, kTitleScrollTimerId);
  KillTimer(window_, kButtonsRetryTimerId);
  HideButtons();
  if (enabled_) {
    StopTitleScrolling();
    SetWindowTextW(window_, original_title_.c_str());
    enabled_ = false;
  }
  cover_bgra_.clear();
  cover_width_ = 0;
  cover_height_ = 0;
}

bool TaskbarThumbnail::SetCover(
    const flutter::EncodableValue* arguments) {
  const auto map = arguments == nullptr
                       ? nullptr
                       : std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return false;
  }
  const auto pixels = std::get_if<std::vector<uint8_t>>(
      ValueForKey(*map, "bgra"));
  const auto width = ReadInt(ValueForKey(*map, "width"));
  const auto height = ReadInt(ValueForKey(*map, "height"));
  if (pixels == nullptr || !width.has_value() || !height.has_value() ||
      *width <= 0 || *height <= 0) {
    return false;
  }
  const size_t width_size = static_cast<size_t>(*width);
  const size_t height_size = static_cast<size_t>(*height);
  if (width_size > std::numeric_limits<size_t>::max() / height_size / 4) {
    return false;
  }
  const size_t expected_size = width_size * height_size * 4;
  if (pixels->size() != expected_size) {
    return false;
  }
  cover_bgra_ = *pixels;
  cover_width_ = *width;
  cover_height_ = *height;
  InvalidateThumbnail();
  return true;
}

bool TaskbarThumbnail::SetPlaying(
    const flutter::EncodableValue* arguments) {
  const auto map = arguments == nullptr
                       ? nullptr
                       : std::get_if<flutter::EncodableMap>(arguments);
  const auto value = map == nullptr
                         ? nullptr
                         : std::get_if<bool>(ValueForKey(*map, "playing"));
  if (value == nullptr) {
    return false;
  }
  playing_ = *value;
  if (buttons_added_) {
    auto buttons =
        MakeButtons(icons_, playing_, true, has_track_, can_skip_);
    taskbar_->ThumbBarUpdateButtons(window_, static_cast<UINT>(buttons.size()),
                                    buttons.data());
  }
  return true;
}

bool TaskbarThumbnail::SetControls(
    const flutter::EncodableValue* arguments) {
  const auto map = arguments == nullptr
                       ? nullptr
                       : std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return false;
  }
  const bool* has_track = ReadBool(*map, "hasTrack");
  const bool* can_skip = ReadBool(*map, "canSkip");
  if (has_track == nullptr || can_skip == nullptr) {
    return false;
  }
  has_track_ = *has_track;
  can_skip_ = *can_skip;
  if (buttons_added_) {
    auto buttons =
        MakeButtons(icons_, playing_, true, has_track_, can_skip_);
    taskbar_->ThumbBarUpdateButtons(window_, static_cast<UINT>(buttons.size()),
                                    buttons.data());
  }
  return true;
}

bool TaskbarThumbnail::SetTitle(
    const flutter::EncodableValue* arguments) {
  const auto map = arguments == nullptr
                       ? nullptr
                       : std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return false;
  }
  const std::string* title = ReadString(*map, "title");
  if (title == nullptr || title->size() > 2048) {
    return false;
  }
  const auto wide_title = Utf8ToWide(*title);
  if (!wide_title.has_value()) {
    return false;
  }
  StopTitleScrolling();
  song_title_ = *wide_title;
  title_scroll_units_.clear();
  for (size_t index = 0; index < song_title_.size();) {
    size_t length = 1;
    const wchar_t first = song_title_[index];
    if (first >= 0xD800 && first <= 0xDBFF &&
        index + 1 < song_title_.size()) {
      const wchar_t second = song_title_[index + 1];
      if (second >= 0xDC00 && second <= 0xDFFF) {
        length = 2;
      }
    }
    title_scroll_units_.push_back(song_title_.substr(index, length));
    index += length;
  }
  title_scroll_units_.push_back(L" ");
  title_scroll_units_.push_back(L" ");
  title_scroll_units_.push_back(L" ");
  ApplyWindowTitle();
  return true;
}

bool TaskbarThumbnail::EnsureTaskbar() {
  if (taskbar_) {
    return true;
  }
  if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(taskbar_.ReleaseAndGetAddressOf())))) {
    return false;
  }
  if (FAILED(taskbar_->HrInit())) {
    taskbar_.Reset();
    return false;
  }
  return true;
}

bool TaskbarThumbnail::ShowButtons() {
  if (!enabled_ || !EnsureTaskbar()) {
    return false;
  }
  auto buttons = MakeButtons(icons_, playing_, true, has_track_, can_skip_);
  const HRESULT result =
      buttons_added_
          ? taskbar_->ThumbBarUpdateButtons(
                window_, static_cast<UINT>(buttons.size()), buttons.data())
          : taskbar_->ThumbBarAddButtons(
                window_, static_cast<UINT>(buttons.size()), buttons.data());
  if (SUCCEEDED(result)) {
    buttons_added_ = true;
    return true;
  }
  return false;
}

void TaskbarThumbnail::HideButtons() {
  if (!buttons_added_ || !taskbar_) {
    return;
  }
  auto buttons = MakeButtons(icons_, playing_, false, has_track_, can_skip_);
  taskbar_->ThumbBarUpdateButtons(window_, static_cast<UINT>(buttons.size()),
                                  buttons.data());
}

void TaskbarThumbnail::InvalidateThumbnail() {
  if (enabled_ && window_ != nullptr) {
    DwmInvalidateIconicBitmaps(window_);
  }
}

void TaskbarThumbnail::ProvideThumbnail(int max_width, int max_height) {
  if (!enabled_ || max_width <= 0 || max_height <= 0) {
    return;
  }
  const bool use_fallback = cover_bgra_.empty();
  const std::vector<uint8_t>& cover =
      use_fallback ? FallbackCover() : cover_bgra_;
  const int cover_width = use_fallback ? kFallbackCoverSize : cover_width_;
  const int cover_height = use_fallback ? kFallbackCoverSize : cover_height_;
  const auto [width, height] =
      FitSize(cover_width, cover_height, max_width, max_height);
  std::vector<uint8_t> scaled;
  const std::vector<uint8_t>* pixels = &cover;
  if (width != cover_width || height != cover_height) {
    scaled = ScaleBgra(cover, cover_width, cover_height, width, height);
    pixels = &scaled;
  }
  HBITMAP bitmap = CreateBitmapFromBgra(*pixels, width, height);
  if (bitmap == nullptr) {
    return;
  }
  DwmSetIconicThumbnail(window_, bitmap, 0);
  DeleteObject(bitmap);
}

void TaskbarThumbnail::SendControlEvent(const char* event) {
  if (channel_) {
    channel_->InvokeMethod(
        "control", std::make_unique<flutter::EncodableValue>(event));
  }
}

void TaskbarThumbnail::UpdateTitleScrolling(int available_width) {
  if (song_title_.empty() || title_scroll_units_.size() <= 3 ||
      available_width <= 0) {
    const bool was_scrolling = title_scrolling_;
    StopTitleScrolling();
    if (was_scrolling) ApplyWindowTitle();
    return;
  }
  HDC dc = GetDC(window_);
  SIZE extent{};
  bool overflows = true;
  if (dc != nullptr) {
    const HGDIOBJ font = GetStockObject(DEFAULT_GUI_FONT);
    const HGDIOBJ old_font =
        font == nullptr ? nullptr : SelectObject(dc, font);
    const int length = static_cast<int>(std::min<size_t>(
        song_title_.size(),
        static_cast<size_t>(std::numeric_limits<int>::max())));
    if (GetTextExtentPoint32W(dc, song_title_.c_str(), length, &extent)) {
      overflows = extent.cx > std::max(40, available_width - 32);
    }
    if (old_font != nullptr) SelectObject(dc, old_font);
    ReleaseDC(window_, dc);
  }
  if (!overflows) {
    const bool was_scrolling = title_scrolling_;
    StopTitleScrolling();
    if (was_scrolling) ApplyWindowTitle();
    return;
  }
  if (!title_scrolling_ &&
      SetTimer(window_, kTitleScrollTimerId, kTitleScrollIntervalMs, nullptr) !=
          0) {
    title_scrolling_ = true;
    title_scroll_index_ = 0;
  }
}

void TaskbarThumbnail::StopTitleScrolling() {
  if (title_scrolling_) {
    KillTimer(window_, kTitleScrollTimerId);
  }
  title_scrolling_ = false;
  title_scroll_index_ = 0;
}

void TaskbarThumbnail::AdvanceTitleScroll() {
  if (!enabled_ || !title_scrolling_ || title_scroll_units_.empty()) {
    return;
  }
  title_scroll_index_ =
      (title_scroll_index_ + 1) % title_scroll_units_.size();
  std::wstring title;
  title.reserve(song_title_.size() + 3);
  for (size_t offset = 0; offset < title_scroll_units_.size(); ++offset) {
    const size_t index =
        (title_scroll_index_ + offset) % title_scroll_units_.size();
    title.append(title_scroll_units_[index]);
  }
  SetWindowTextW(window_, title.c_str());
}

void TaskbarThumbnail::ApplyWindowTitle() {
  if (window_ == nullptr) {
    return;
  }
  const std::wstring& title =
      enabled_ && !song_title_.empty() ? song_title_ : original_title_;
  SetWindowTextW(window_, title.c_str());
}

std::optional<LRESULT> TaskbarThumbnail::HandleMessage(UINT message,
                                                       WPARAM wparam,
                                                       LPARAM lparam) {
  if (message == taskbar_button_created_message_) {
    buttons_added_ = false;
    taskbar_.Reset();
    ShowButtons();
    return LRESULT(0);
  }
  if (!enabled_) {
    return std::nullopt;
  }
  switch (message) {
    case WM_DWMSENDICONICTHUMBNAIL: {
      const int width = HIWORD(lparam);
      UpdateTitleScrolling(width);
      ProvideThumbnail(width, LOWORD(lparam));
      return LRESULT(0);
    }
    case WM_COMMAND:
      if (HIWORD(wparam) == THBN_CLICKED) {
        switch (LOWORD(wparam)) {
          case kPreviousButtonId:
            if (!can_skip_) return LRESULT(0);
            SendControlEvent("previous");
            break;
          case kPlayPauseButtonId:
            if (!has_track_) return LRESULT(0);
            SendControlEvent("playPause");
            break;
          case kNextButtonId:
            if (!can_skip_) return LRESULT(0);
            SendControlEvent("next");
            break;
          default:
            return std::nullopt;
        }
        return LRESULT(0);
      }
      break;
    case WM_TIMER:
      if (wparam == kTitleScrollTimerId) {
        AdvanceTitleScroll();
        return LRESULT(0);
      }
      if (wparam == kButtonsRetryTimerId) {
        // 任务栏按钮就绪后绑定 ThumbBar 按钮；成功后停止重试。
        if (ShowButtons()) {
          KillTimer(window_, kButtonsRetryTimerId);
        }
        return LRESULT(0);
      }
      break;
    default:
      break;
  }
  return std::nullopt;
}
