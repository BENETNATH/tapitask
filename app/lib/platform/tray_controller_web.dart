import "../state/app_state.dart";

/// Web no-op: no FFI, no tray icon, no flyout — the app lives in the
/// browser tab. Same public surface as the native [TrayController].
class TrayController {
  final AppState state;

  TrayController(this.state);

  Future<void> init() async {}

  bool get isInitialized => false;

  Future<void> showMainWindow() async {}

  Future<bool> isMainWindowVisible() async => true;

  Future<void> restoreMainWindow() async {}

  Future<void> quit() async {}
}
