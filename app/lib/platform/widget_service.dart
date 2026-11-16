import "dart:ui" show PlatformDispatcher, Brightness;

import "package:home_widget/home_widget.dart";

import "../data/database.dart";
import "../l10n/s.dart";
import "../state/app_state.dart";

/// Android home-screen widgets.
/// - ListWidget (resizable): pinned lists; tap title to cycle, tap item to check.
/// - QuickAddWidget (1x1): opens the app straight into quick-add.
/// Data is written to the shared store read by the Kotlin providers; the list
/// widget refreshes after every sync. Items checked from the widget are
/// recorded in `widget_toggled` and applied by the app on next open.
class WidgetService {
  static const maxLists = 5;
  static const maxItems = 5;

  static Future<void> update(AppState state, AppDb db,
                            List<LocalList> pinnedLists) async {
    // Localized labels (per-user synced language) read by the Kotlin provider.
    // Universal icon-only add button (same as the Windows flyout).
    await HomeWidget.saveWidgetData("label_add", "＋");
    await HomeWidget.saveWidgetData("label_open", S.openAction);
    await HomeWidget.saveWidgetData("label_no_list", S.pinListsHelp);
    await HomeWidget.saveWidgetData("label_all_done", S.allDone);
    // Theme: the synced user setting ("system" resolved against the OS).
    final setting = state.settings["theme"] as String? ?? "system";
    final theme = setting == "system"
        ? (PlatformDispatcher.instance.platformBrightness == Brightness.dark
            ? "dark"
            : "light")
        : setting;
    await HomeWidget.saveWidgetData("theme", theme);
    await HomeWidget.saveWidgetData(
        "list_count_lists", pinnedLists.length.clamp(0, maxLists).toInt());
    for (var li = 0; li < maxLists; li++) {
      if (li < pinnedLists.length) {
        final list = pinnedLists[li];
        final items = await db.uncheckedItemsOf(list.id);
        await HomeWidget.saveWidgetData("list_${li}_id", list.id);
        await HomeWidget.saveWidgetData("list_${li}_title", list.title);
        await HomeWidget.saveWidgetData("list_${li}_color", list.color ?? "");
        await HomeWidget.saveWidgetData(
            "list_${li}_count", items.length.clamp(0, maxItems).toInt());
        for (var i = 0; i < maxItems; i++) {
          // Due-date badge appended to the label (per-user setting), same as
          // the Windows flyout — homogeneous ecosystem.
          final badge = i < items.length ? state.dueSuffix(items[i]) : null;
          await HomeWidget.saveWidgetData("list_${li}_item_$i",
              i < items.length
                  ? (badge == null || badge.isEmpty
                      ? items[i].label
                      : "${items[i].label}  •  $badge")
                  : "");
          await HomeWidget.saveWidgetData("list_${li}_item_${i}_id",
              i < items.length ? items[i].id : "");
        }
      } else {
        await HomeWidget.saveWidgetData("list_${li}_count", 0);
      }
    }
    // widget_done_ids is NOT cleared here: the Kotlin provider adds an id
    // when the user checks an item on the widget, and a concurrent refresh
    // must never wipe that check before the app applies it (race). The app
    // clears both done_ids and widget_toggled in clearToggles(), once the
    // checks are applied to the local DB — from then on the items are done
    // in the data itself.
    await HomeWidget.updateWidget(androidName: "ListWidgetProvider");
    await HomeWidget.updateWidget(androidName: "QuickAddWidgetProvider");
  }

  /// Items checked from the widget, waiting to be applied to the local DB.
  static Future<List<String>> pendingToggles() async {
    final raw = await HomeWidget.getWidgetData<String>("widget_toggled");
    if (raw == null || raw.trim().isEmpty) return [];
    return raw.split(",").where((id) => id.trim().isNotEmpty).toList();
  }

  static Future<void> clearToggles() async {
    await HomeWidget.saveWidgetData("widget_toggled", "");
    // home_widget 0.10 no longer accepts List<String>: store a joined string
    // (the Kotlin provider reads/splits it the same way).
    await HomeWidget.saveWidgetData("widget_done_ids", "");
  }
}
