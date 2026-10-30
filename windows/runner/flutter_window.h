#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

class TaskbarThumbnail;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;
  // 第二个实例唤醒时：恢复窗口并通知 Dart 侧显示。
  void HandleShowRequest();

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<TaskbarThumbnail> taskbar_thumbnail_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      single_instance_channel_;
  UINT show_request_message_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
