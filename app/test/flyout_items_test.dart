import "package:drift/drift.dart" hide isNull;
import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/platform/flyout_bridge.dart";
import "package:tapitask/state/app_state.dart";

/// Spec lot W (W3) : le flyout respecte le réglage hide_done (volet/widget) —
/// ON (défaut) : uniquement les items non-cochés ; OFF : tous les items,
/// les cochés passent le flag done de la ligne (`I <id> 1 <label>`).
void main() {
  const listId = "11111111-2222-3333-4444-555555555555";
  const openId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
  const doneId = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff";
  final now = DateTime(2026, 11, 18, 12);

  Future<(AppDb, AppState, FlyoutBridge)> make(bool? hideDone) async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    if (hideDone != null) state.settings["hide_done"] = hideDone;
    await db.upsertList(LocalListsCompanion(
      id: const Value(listId),
      title: const Value("Achats"),
      ownerId: const Value(""),
      updatedAt: Value(now),
      dirty: const Value(false),
      localOnly: const Value(true),
    ));
    await db.addItem(openId, listId, "Pain", 0, now);
    await db.addItem(doneId, listId, "Lait", 1, now);
    await db.setDone(doneId, true, now);
    return (db, state, FlyoutBridge(state));
  }

  test("W3 : hide_done ON (défaut) — le flyout n'a que les items non-cochés",
      () async {
    final (db, _, bridge) = await make(null);
    final items = await bridge.itemsFor(listId);
    expect(items.map((i) => i.id), [openId],
        reason: "W3 : réglage ON → l'item coché est absent du volet");
    await db.close();
  });

  test("W3 : hide_done OFF — tous les items, cochés inclus (flag done)",
      () async {
    final (db, _, bridge) = await make(false);
    final items = await bridge.itemsFor(listId);
    expect(items.length, 2,
        reason: "W3 : réglage OFF → l'item coché apparaît dans le volet");
    expect(items.map((i) => i.id), [openId, doneId]);
    expect(items.firstWhere((i) => i.id == doneId).done, true,
        reason: "W3 : la ligne cochée arrive avec done=1 (cochée côté natif)");
    await db.close();
  });
}
