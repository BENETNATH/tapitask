import "package:drift/drift.dart" hide isNull;
import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/list_screen.dart";

/// Spec lot S (S2) : réglage « Cacher les items cochés » (hide_done,
/// défaut true) — les items cochés ne s'affichent plus dans le volet ;
/// réglage OFF → comportement actuel (cochés affichés, barrés).
void main() {
  const listId = "11111111-2222-3333-4444-555555555555";
  const openId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
  const doneId = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff";
  final now = DateTime(2026, 11, 18, 12);

  Future<AppDb> makeDb() async {
    final db = AppDb.forTesting(NativeDatabase.memory());
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
    return db;
  }

  testWidgets("S2 : hide_done ON (défaut) — l'item coché est masqué du volet",
      (tester) async {
    final db = await makeDb();
    final state = AppState(db: db);
    // hide_done absent des réglages → défaut true.

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: listId)));
    await tester.pumpAndSettle();

    expect(find.text("Lait"), findsNothing,
        reason: "S2 : réglage ON (défaut) → l'item coché doit disparaître "
            "du volet (avant fix : il est affiché)");
    expect(find.text("Pain"), findsOneWidget);
    await db.close();
  });

  testWidgets("S2 : hide_done OFF — l'item coché est visible (barré)",
      (tester) async {
    final db = await makeDb();
    final state = AppState(db: db);
    state.settings["hide_done"] = false;

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: listId)));
    await tester.pumpAndSettle();

    expect(find.text("Lait"), findsOneWidget);
    final label = tester.widget<Text>(find.text("Lait"));
    expect(label.style?.decoration, TextDecoration.lineThrough,
        reason: "S2 : réglage OFF → l'item coché reste affiché, barré");
    expect(find.text("Pain"), findsOneWidget);
    await db.close();
  });
}
