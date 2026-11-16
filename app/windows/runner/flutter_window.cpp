#include "flutter_window.h"

#include <optional>
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Tapitask: NATIVE tray flyout (volet rapide). Created hidden at startup:
  // a tray click is a plain ShowWindow — instant, no second Flutter engine.
  // Data flows Dart -> native via "updateFlyoutData", user actions native ->
  // Dart via "flyoutEvent" (same channel, both directions).
  {
    flyout_ = std::make_unique<FlyoutWindow>();
    auto messenger = flutter_controller_->engine()->messenger();
    FlyoutWindow* flyout = flyout_.get();
    flyout_->Create(
        [messenger](const std::string& action, const std::string& a,
                    const std::string& b) {
          flutter::MethodChannel<flutter::EncodableValue>(
              messenger, "tapitask/win32",
              &flutter::StandardMethodCodec::GetInstance())
              .InvokeMethod(
                  "flyoutEvent",
                  std::make_unique<flutter::EncodableValue>(
                      flutter::EncodableMap{
                          {flutter::EncodableValue("action"),
                           flutter::EncodableValue(action)},
                          {flutter::EncodableValue("a"),
                           flutter::EncodableValue(a)},
                          {flutter::EncodableValue("b"),
                           flutter::EncodableValue(b)},
                      }));
        });

    flutter::MethodChannel<flutter::EncodableValue> channel(
        messenger, "tapitask/win32",
        &flutter::StandardMethodCodec::GetInstance());
    channel.SetMethodCallHandler(
        [flyout](const flutter::MethodCall<flutter::EncodableValue>& call,
                 std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                     result) {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          auto str_arg = [&](const char* key) -> std::string {
            if (!args) return "";
            auto it = args->find(flutter::EncodableValue(key));
            if (it == args->end()) return "";
            if (const auto* s = std::get_if<std::string>(&it->second)) {
              return *s;
            }
            return "";
          };
          auto bool_arg = [&](const char* key) -> bool {
            if (!args) return false;
            auto it = args->find(flutter::EncodableValue(key));
            if (it == args->end()) return false;
            if (const auto* b = std::get_if<bool>(&it->second)) return *b;
            return false;
          };

          if (call.method_name().compare("toggleFlyout") == 0) {
            bool pinned = bool_arg("pinned");
            if (flyout->visible()) {
              flyout->Hide();
            } else {
              flyout->Show(pinned);
            }
            result->Success(flutter::EncodableValue(flyout->visible()));
            return;
          }
          if (call.method_name().compare("updateFlyoutData") == 0) {
            flyout->UpdateData(str_arg("data"));
            result->Success();
            return;
          }
          result->NotImplemented();
        });
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
