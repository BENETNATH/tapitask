import "package:drift/drift.dart" hide isNull;
import "package:drift/native.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/database.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:tapitask/state/app_state.dart";

/// Spec lot H (2026-11-17) : le cochage fait dans le widget doit être
/// appliqué à chaque retour dans l'app (resume), pas seulement au cold
/// start — d'où `applyWidgetToggles` public, appelé aussi au resume.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const itemId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
  const listId = "11111111-2222-3333-4444-555555555555";

  /// Prefs partagées du plugin home_widget (store du mock de canal).
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
          store[args["id"] as String] = args["data"] as String;
          return true;
      }
      return null;
    });
  }

  Future<(AppDb, AppState)> makeState(
      Map<String, String> prefs, String toggled) async {
    store
      ..clear()
      ..addAll(prefs);
    if (toggled.isNotEmpty) store["widget_toggled"] = toggled;
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
      updatedAt: Value(DateTime.now().toUtc()),
      dirty: const Value(false),
      localOnly: const Value(true),
    ));
    await db.addItem(itemId, listId, "Pain", 0, DateTime.now().toUtc());
    return (db, state);
  }

  test("toggle appliqué à la base puis effacé (idempotent ensuite)",
      () async {
    final (db, state) =
        await makeState({"widget_done_ids": itemId}, itemId);
    await state.applyWidgetToggles();
    expect((await db.itemsOf(listId)).single.done, isTrue,
        reason: "l'item coché dans le widget doit être coché en base");
    expect(store["widget_toggled"], "",
        reason: "widget_toggled doit être vidé après application");
    expect(store["widget_done_ids"], "",
        reason: "widget_done_ids doit être vidé après application");
    // Deuxième passage : plus rien en attente, aucun effet, pas d'exception.
    await state.applyWidgetToggles();
    expect((await db.itemsOf(listId)).single.done, isTrue);
    await db.close();
  });

  test("les listeners sont notifiés quand un toggle en attente est appliqué",
      () async {
    final (db, state) =
        await makeState({"widget_done_ids": itemId}, itemId);
    var count = 0;
    state.addListener(() => count++);
    await state.applyWidgetToggles();
    expect(count, greaterThan(0),
        reason: "le home doit rebâtir son aperçu après application");
    await db.close();
  });

  test("rien en attente : aucun notify", () async {
    final (db, state) = await makeState({}, "");
    var count = 0;
    state.addListener(() => count++);
    await state.applyWidgetToggles();
    expect(count, 0);
    await db.close();
  });

  test("rien en attente : aucun effet, aucune exception", () async {
    final (db, state) = await makeState({}, "");
    await expectLater(state.applyWidgetToggles(), completes);
    expect((await db.itemsOf(listId)).single.done, isFalse);
    await db.close();
  });

  test("setDone en échec sur un id : il n'est PAS effacé, les autres le sont",
      () async {
    const okId = "22222222-3333-4444-5555-666666666666";
    final store2 = <String, String>{
      "widget_toggled": "$itemId,$okId",
      "widget_completed_at_$itemId": "1700000000000",
      "widget_completed_at_$okId": "1700000000000",
    };
    final savedKeys = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case "getWidgetData":
          final args = call.arguments as Map<Object?, Object?>;
          return store2[args["id"] as String? ?? ""];
        case "saveWidgetData":
          final args = call.arguments as Map<Object?, Object?>;
          final key = args["id"] as String;
          savedKeys.add(key);
          if (args["data"] == null) {
            store2.remove(key);
          } else {
            store2[key] = args["data"] as String;
          }
          return true;
      }
      return null;
    });
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final db = _FailingDb(NativeDatabase.memory(), okId);
    final state = AppState(db: db);
    state.api = await ApiClient.load();
    final now = DateTime.now().toUtc();
    await db.upsertList(LocalListsCompanion(
      id: const Value(listId),
      title: const Value("Achats"),
      ownerId: const Value(""),
      updatedAt: Value(now),
      dirty: const Value(false),
      localOnly: const Value(true),
    ));
    await db.addItem(itemId, listId, "Pain", 0, now);
    await db.addItem(okId, listId, "Beurre", 1, now);
    await state.applyWidgetToggles();
    expect(
        (await db.itemsOf(listId))
            .firstWhere((i) => i.id == itemId)
            .done,
        isTrue,
        reason: "l'id appliqué avec succès est coché en base");
    expect(savedKeys, contains("widget_completed_at_$itemId"),
        reason: "l'id réussi passe dans clearToggles");
    expect(savedKeys, isNot(contains("widget_completed_at_$okId")),
        reason: "l'id dont setDone a échoué doit rester en attente "
            "(pas d'effacement définitif)");
    await db.close();
  });
}

/// AppDb dont setDone échoue pour un id précis (panne DB simulée).
class _FailingDb extends AppDb {
  _FailingDb(super.e, this.failId) : super.forTesting();
  final String failId;

  @override
  Future<void> setDone(String id, bool done, DateTime now,
      {Value<DateTime?> completedAt = const Value.absent()}) async {
    if (id == failId) {
      throw StateError("panne DB simulée");
    }
    return super.setDone(id, done, now, completedAt: completedAt);
  }
}
