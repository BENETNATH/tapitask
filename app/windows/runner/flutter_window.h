#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include <memory>

#include "flyout_window.h"
#include "win32_window.h"

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

 public:
  // C2.4 : posé par le Dart (TrayController, avant la 1re frame) — la
  // fenêtre principale ne doit pas être réaffichée par la 1re frame si
  // l'app démarre dans la tray.
  void SetStartHidden(bool hidden) { start_hidden_ = hidden; }

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Native tray flyout (volet rapide), created hidden at startup.
  std::unique_ptr<FlyoutWindow> flyout_;

  // C2.4 : "Démarrer dans la barre des tâches" — Show() de la 1re frame
  // conditionnelle sur ce flag (source de vérité : le réglage Dart).
  bool start_hidden_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
