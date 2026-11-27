import "package:drift/drift.dart" hide isNull;
import "package:drift/native.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/platform/widget_service.dart";
import "package:tapitask/state/app_state.dart";

/// Spec lot S (S2+S3) : l'écriture du widget respecte hide_done —
/// ON (défaut) : uniquement les items non-cochés ; OFF : tous les items,
/// les cochés préfixés « ✓  » et sans id de ligne (non cliquables).
/// Plus de plafond maxItems : toutes les clés list_<li>_item_* sont écrites.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const listId = "11111111-2222-3333-4444-555555555555";
  const aId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
  const bId = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff";
  const cId = "cccccccc-dddd-eeee-ffff-aaaaaaaaaaaa";
  final now = DateTime(2026, 11, 18, 12);
  final Map<String, String> store = {};
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
          // Les compteurs sont écrits en int (le plugin stocke du dynamique).
          final data = args["data"];
          store[args["id"] as String] = data?.toString() ?? "";
          return true;
      }
      return null;
    });
  }

  Future<(AppDb, AppState)> make(bool? hideDone) async {
    store.clear();
    mockChannel();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    state.api = await ApiClient.load();
    if (hideDone != null) state.settings["hide_done"] = hideDone;
    await db.upsertList(LocalListsCompanion(
      id: const Value(listId),
      title: const Value("Achats"),
      ownerId: const Value(""),
      updatedAt: Value(now),
      dirty: const Value(false),
      localOnly: const Value(true),
    ));
    // Lait (pos 1) coché ; le reste non.
    await db.addItem(aId, listId, "Pain", 0, now);
    await db.addItem(bId, listId, "Lait", 1, now);
    await db.setDone(bId, true, now);
    await db.addItem(cId, listId, "Beurre", 2, now);
    return (db, state);
  }

  Future<LocalList> listOf(AppDb db) =>
      (db.select(db.localLists)..where((l) => l.id.equals(listId))).getSingle();

  test("S2 : ON (défaut) — seuls les items non-cochés sont écrits", () async {
    final (db, state) = await make(null);
    await WidgetService.update(state, db, [await listOf(db)]);
    expect(store["list_count_lists"], "1");
    expect(store["list_0_count"], "2",
        reason: "réglage ON : le compteur = items non-cochés");
    expect(store["list_0_item_0"], "☐  Pain");
    expect(store["list_0_item_1"], "☐  Beurre");
    expect(store["list_0_item_2"] ?? "", isEmpty,
        reason: "réglage ON : aucun item coché n'est écrit");
    expect(store["list_0_item_0_id"], aId);
    expect(store["list_0_item_1_id"], cId);
    await db.close();
  });

  test("S2 : OFF — tous les items écrits, cochés préfixés ✓ et non cliquables",
      () async {
    final (db, state) = await make(false);
    await WidgetService.update(state, db, [await listOf(db)]);
    expect(store["list_0_count"], "3");
    expect(store["list_0_item_0"], "☐  Pain");
    expect(store["list_0_item_1"], "☐  Beurre");
    expect(store["list_0_item_2"], "✓  Lait",
        reason: "réglage OFF : l'item coché est écrit avec préfixe ✓");
    expect(store["list_0_item_2_id"], "",
        reason: "réglage OFF : la ligne cochée est non-cliquable (pas d'id)");
    await db.close();
  });

  test("R-C1 : badge d'échéance dans la clé _due, plus dans le label",
      () async {
    store.clear();
    mockChannel();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
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
    ));
    final today = DateTime.now();
    await db.addItem("d0000000-0000-0000-0000-000000000001", listId, "Facture",
        0, now, dueDate: today.subtract(const Duration(days: 2)));
    await db.addItem("d0000000-0000-0000-0000-000000000002", listId,
        "Renouveler", 1, now, dueDate: today.add(const Duration(days: 1)));
    await db.addItem("d0000000-0000-0000-0000-000000000003", listId, "Simple",
        2, now);
    await WidgetService.update(state, db, [await listOf(db)]);
    // Le label ne contient plus ni puce ni badge.
    expect(store["list_0_item_0"], "☐  Facture",
        reason: "R-C1 : le label est écrit sans badge");
    expect(store["list_0_item_0"], isNot(contains("•")));
    expect(store["list_0_item_0"], isNot(contains("en retard")));
    // Retard : le suffix exact, puce incluse une seule fois.
    expect(store["list_0_item_0_due"], S.t("overdueSuffix").trim());
    expect(store["list_0_item_0_due"], "•  en retard");
    // Échéance future : sans puce.
    expect(store["list_0_item_1_due"], "demain");
    expect(store["list_0_item_1_due"], isNot(contains("•")));
    // Pas d'échéance → clé _due vide.
    expect(store["list_0_item_2_due"], "");
    await db.close();
  });

  test("S3 : plus de plafond maxItems — les 7 items sont écrits", () async {
    final (db, state) = await make(null);
    for (var i = 3; i < 8; i++) {
      await db.addItem("dddddddd-eeee-ffff-aaaa-00000000000$i", listId,
          "x$i", i, now);
    }
    await WidgetService.update(state, db, [await listOf(db)]);
    expect(store["list_0_count"], "7",
        reason: "S3 : le plafond maxItems=5 est supprimé");
    expect(store["list_0_item_6"], isNotEmpty,
        reason: "S3 : la 7e ligne est écrite (au-delà de l'ancien plafond)");
    await db.close();
  });
}
