import "package:drift/drift.dart" hide isNull;
import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/list_screen.dart";

/// Spec lot W (W2) : le « Cacher les items cochés » de l'app est le réglage
/// hide_done_app (défaut false), SÉPARÉ de hide_done — qui ne gouverne plus
/// que le volet (Windows) et le widget (Android).
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

  testWidgets("W2 : hide_done_app ON — l'item coché est masqué de l'app",
      (tester) async {
    final db = await makeDb();
    final state = AppState(db: db);
    state.settings["hide_done_app"] = true;

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: listId)));
    await tester.pumpAndSettle();

    expect(find.text("Lait"), findsNothing,
        reason: "W2 : réglage app ON (défaut) → l'item coché doit disparaître "
            "de la liste de l'app (avant fix : il est affiché)");
    expect(find.text("Pain"), findsOneWidget);
    await db.close();
  });

  testWidgets(
      "completed tasks and subtasks are crossed out below active tasks by default",
      (tester) async {
    final db = await makeDb();
    final state = AppState(db: db);
    await db.addItem("done-child", listId, "Miel", 2, now,
        parentId: openId, done: true);
    await db.addItem("open-child", listId, "Thé", 3, now, parentId: doneId);

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: listId)));
    await tester.pumpAndSettle();

    expect(find.text("Lait"), findsOneWidget,
        reason: "W2 : réglage app OFF → l'item coché reste affiché dans l'app");
    final label = tester.widget<Text>(find.text("Lait"));
    expect(label.style?.decoration, TextDecoration.lineThrough,
        reason: "W2 : réglage OFF → l'item coché reste affiché, barré");
    expect(find.text("Pain"), findsOneWidget);
    expect(tester.getTopLeft(find.text("Thé")).dy,
        lessThan(tester.getTopLeft(find.text("Lait")).dy));
    expect(tester.getTopLeft(find.text("Pain")).dy,
        lessThan(tester.getTopLeft(find.text("Miel")).dy));
    expect(tester.widget<Text>(find.text("Miel")).style?.decoration,
        TextDecoration.lineThrough);
    await db.close();
  });

  testWidgets(
      "W2 : séparation — hide_done OFF n'a plus d'effet sur l'app (coché masqué)",
      (tester) async {
    final db = await makeDb();
    final state = AppState(db: db);
    state.settings["hide_done"] = false; // volet/widget : tous les items
    state.settings["hide_done_app"] = true;

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: listId)));
    await tester.pumpAndSettle();

    expect(find.text("Lait"), findsNothing,
        reason:
            "W2 : le réglage volet/widget ne pilote plus la liste de l'app");
    expect(find.text("Pain"), findsOneWidget);
    await db.close();
  });

  testWidgets(
      "W2 : séparation — hide_done_app OFF montre les cochés même si hide_done ON",
      (tester) async {
    final db = await makeDb();
    final state = AppState(db: db);
    state.settings["hide_done"] = true; // volet/widget : cochés masqués
    state.settings["hide_done_app"] = false;

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: listId)));
    await tester.pumpAndSettle();

    expect(find.text("Lait"), findsOneWidget,
        reason:
            "W2 : le réglage app fait foi pour l'app — les cochés sont visibles");
    expect(find.text("Pain"), findsOneWidget);
    await db.close();
  });
}
