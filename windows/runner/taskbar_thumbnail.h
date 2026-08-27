#ifndef RUNNER_TASKBAR_THUMBNAIL_H_
#define RUNNER_TASKBAR_THUMBNAIL_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

class TaskbarThumbnail {
 public:
  TaskbarThumbnail(flutter::BinaryMessenger* messenger, HWND window);
  ~TaskbarThumbnail();

  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool Enable();
  void Disable();
  bool SetPlaybackControlsEnabled(
      const flutter::EncodableValue* arguments);
  bool SetCoverScale(const flutter::EncodableValue* arguments);
  bool SetCoverPreview(const flutter::EncodableValue* arguments);
  bool EnableCoverPreview();
  void DisableCoverPreview();
  bool SetCover(const flutter::EncodableValue* arguments);
  bool SetPlaying(const flutter::EncodableValue* arguments);
  bool SetControls(const flutter::EncodableValue* arguments);
  bool SetTitle(const flutter::EncodableValue* arguments);
  bool EnsureTaskbar();
  bool ShowButtons();
  void HideButtons();
  void InvalidateThumbnail();
  void PublishLivePreview();
  void ProvideThumbnail(int max_width, int max_height);
  bool GetRestoredClientSize(int* width, int* height);
  bool GetPreviewSize(int* width, int* height);
  bool RebuildLivePreview();
  void ProvideLivePreview();
  void ClearLivePreview();
  void SendControlEvent(const char* event);
  void UpdateTitleScrolling(int available_width);
  void StopTitleScrolling();
  void AdvanceTitleScroll();
  void ApplyWindowTitle();

  HWND window_ = nullptr;
  UINT taskbar_button_created_message_ = 0;
  bool enabled_ = false;
  bool playback_controls_enabled_ = false;
  bool cover_preview_enabled_ = false;
  double cover_scale_ = 1.0;
  bool buttons_added_ = false;
  bool playing_ = false;
  bool has_track_ = false;
  bool can_skip_ = false;
  bool title_scrolling_ = false;
  size_t title_scroll_index_ = 0;
  int cover_width_ = 0;
  int cover_height_ = 0;
  int live_preview_width_ = 0;
  int live_preview_height_ = 0;
  int last_client_width_ = 0;
  int last_client_height_ = 0;
  HBITMAP live_preview_bitmap_ = nullptr;
  std::vector<uint8_t> cover_bgra_;
  std::wstring original_title_;
  std::wstring song_title_;
  std::vector<std::wstring> title_scroll_units_;
  std::array<HICON, 4> icons_{};
  Microsoft::WRL::ComPtr<ITaskbarList3> taskbar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_TASKBAR_THUMBNAIL_H_
