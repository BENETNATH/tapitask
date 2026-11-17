import "package:drift/drift.dart" hide isNull;
import "package:flutter_test/flutter_test.dart";
import "package:drift/native.dart";
import "package:material_ui/material_ui.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/list_screen.dart";

void main() {
  const longTitle =
      "Entretien extérieur, abords, gouttières et volets de la maison";

  Future<String> addList(AppDb db, String id, String title) async {
    await db.upsertList(LocalListsCompanion(
      id: Value(id),
      title: Value(title),
      ownerId: const Value(""),
      updatedAt: Value(DateTime.now().toUtc()),
      dirty: const Value(false),
      localOnly: const Value(true),
    ));
    return id;
  }

  testWidgets("2 listes : titre long ne provoque pas d'overflow RenderFlex",
      (tester) async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    final id1 = await addList(db, "list1", longTitle);
    await addList(db, "list2", "Autre");

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: id1)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(PopupMenuButton<String>), findsWidgets);
    await db.close();
  });

  testWidgets("1 liste : titre long reste visible sans overflow",
      (tester) async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    final id1 = await addList(db, "list1", longTitle);

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: id1)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final appBar = find.byType(AppBar);
    expect(appBar, findsOneWidget);
    final title =
        tester.widget<Text>(find.descendant(of: appBar, matching: find.byType(Text)));
    expect(title.data, longTitle);
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    await db.close();
  });
}
