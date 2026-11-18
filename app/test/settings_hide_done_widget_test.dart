import "package:drift/drift.dart" hide isNull, Column;
import "package:drift/native.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/settings_screen.dart";

/// Spec lot W (W0/W1) : un changement de réglage (seul point de passage :
/// AppState.saveSettings) réécrit IMMÉDIATEMENT les prefs du widget et
/// déclenche updateWidget — avant le fix : le toggle « Cacher les items
/// cochés » ne rafraîchissait jamais le widget (aucun appel home_widget
/// après le tap ; le bug W0 confirmé device).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const listId = "11111111-2222-3333-4444-555555555555";
  const openId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
  const doneId = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff";
  final now = DateTime(2026, 11, 18, 12);
  final Map<String, String> store = {};
  var updateWidgetCalls = 0;
  const channel = MethodChannel("home_widget");

  void mockChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case "getWidgetData":
          final args = call.arguments as Map<Object?, Object?>;
          return store[args["id"] as String? ?? ""];
        case "saveWidgetData":
          final args = call.arguments as Map<Object?, Object?>;
          final data = args["data"];
          store[args["id"] as String] = data?.toString() ?? "";
          return true;
        case "updateWidget":
          updateWidgetCalls++;
          return true;
      }
      return null;
    });
  }

  /// Le switch « Cacher les items cochés » de la section « Volet & widget ».
  /// Ancrage sur S.compactDue (unique) : la ligne hide_done est la 1re ligne
  /// de cette section (1er Switch de la colonne) — les deux labels
  /// hideDone/hideDoneApp sont identiques en FR.
  Finder hideDoneSwitch(WidgetTester tester) {
    final row = find
        .ancestor(of: find.text(S.compactDue), matching: find.byType(Row))
        .first;
    final column =
        find.ancestor(of: row, matching: find.byType(Column)).first;
    return find.descendant(of: column, matching: find.byType(Switch)).first;
  }

  Future<(AppDb, AppState)> make(WidgetTester tester) async {
    store.clear();
    updateWidgetCalls = 0;
    mockChannel();
    SharedPreferences.setMockInitialValues({});
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    state.api = await ApiClient.load();
    await db.upsertList(LocalListsCompanion(
      id: const Value(listId),
      title: const Value("Achats"),
      ownerId: const Value(""),
      updatedAt: Value(now),
      dirty: const Value(false),
      localOnly: const Value(true),
      pinned: const Value(true),
    ));
    await db.addItem(openId, listId, "Pain", 0, now);
    await db.addItem(doneId, listId, "Lait", 1, now);
    await db.setDone(doneId, true, now);

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: SettingsScreen(state: state)));
    await tester.pumpAndSettle();
    return (db, state);
  }

  testWidgets("W0 : toggle OFF → le widget reçoit les items cochés (✓) + updateWidget",
      (tester) async {
    final (db, state) = await make(tester);

    await tester.tap(hideDoneSwitch(tester));
    await tester.pumpAndSettle();

    expect(state.settings["hide_done"], false);
    expect(store["list_0_count"], "2",
        reason: "W0 : le toggle doit RÉÉCRIRE les prefs du widget "
            "(avant fix : aucun appel après le toggle)");
    expect(store["list_0_item_1"], "✓  Lait",
        reason: "W0 : réglage OFF → l'item coché est écrit avec préfixe ✓");
    expect(updateWidgetCalls, greaterThan(0),
        reason: "W0 : updateWidget est déclenché après le toggle");
    await db.close();
  });

  testWidgets("W0 : retour ON → le widget ne reçoit plus les items cochés",
      (tester) async {
    final (db, state) = await make(tester);

    await tester.tap(hideDoneSwitch(tester)); // → OFF
    await tester.pumpAndSettle();
    await tester.tap(hideDoneSwitch(tester)); // → ON
    await tester.pumpAndSettle();

    expect(state.settings["hide_done"], true);
    expect(store["list_0_count"], "1",
        reason: "W0 : ON → seul l'item non-coché est écrit");
    expect(store["list_0_item_0"], "☐  Pain");
    expect(updateWidgetCalls, greaterThanOrEqualTo(2),
        reason: "W0 : chaque toggle déclenche un updateWidget");
    await db.close();
  });
}
