import "../data/database.dart";
import "../state/app_state.dart";

/// Web no-op: Android home-screen widgets don't exist in the browser.
/// Same public surface as the native [WidgetService].
class WidgetService {
  static const maxLists = 5;

  static Future<void> update(AppState state, AppDb db,
      List<LocalList> pinnedLists) async {}

  static Future<List<String>> pendingToggles() async => [];

  static Future<void> clearToggles() async {}

  static Future<Uri?> initiallyLaunched() async => null;

  static Stream<Uri?> get clicks => const Stream.empty();
}
