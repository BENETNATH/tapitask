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

  testWidgets("2 listes : le titre occupe toute la place entre les chevrons",
      (tester) async {
    // Titre court : avec MainAxisSize.min + Flexible, la Row se taille au
    // contenu au lieu de remplir la zone du titre (~136 < 184) — le fix
    // spec lot P (Row max + Expanded) impose toute la place restante.
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    final id1 = await addList(db, "list1", "a");
    await addList(db, "list2", "machine e");

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: id1)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final title = find.text("a ▾");
    expect(title, findsOneWidget);
    final row = find.ancestor(of: title, matching: find.byType(Row)).first;
    expect(tester.getSize(row).width, greaterThanOrEqualTo(180),
        reason: "Row max + Expanded : le titre prend toute la place "
            "restante entre les chevrons ◀ ▶");
    await db.close();
  });

  testWidgets(
      "P2b : back button + 3 icônes d'action — titre sans place, pas d'overflow",
      (tester) async {
    // Géométrie device : view 640x1280 @ dpr 2.0 = 320 logique, ListScreen
    // POUSSÉ via Navigator (back button 56 px), 2 listes → Row du titre
    // (2 chevrons 48 px) + 3 icônes d'action (144 px) + padding toolbar
    // (32 px) : la zone titre n'a plus que 88 px — les 96 px des chevrons
    // débordent (RenderFlex overflow 8 px) et le titre tombe à 0 px.
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    final id1 = await addList(db, "list1", "machine e");
    await addList(db, "list2", "Autre");

    tester.view.physicalSize = const Size(640, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ListScreen(state: state, listId: id1),
                ),
              ),
              child: const Text("go"),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text("go"));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: "aucun RenderFlex overflow dans l'AppBar");
    final title = find.text("machine e ▾");
    expect(title, findsOneWidget);
    expect(tester.getSize(title).width, greaterThanOrEqualTo(80),
        reason: "P2b : actions réduites à 1 icône → zone titre 184 px, "
            "chevrons 96 → titre 88 px ; « machine e ▾ » tient entier");
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
