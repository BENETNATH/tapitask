import "package:drift/drift.dart" hide isNull;
import "package:drift/native.dart";
import "package:material_ui/material_ui.dart";
import "package:flutter_test/flutter_test.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/home_screen.dart";
import "package:tapitask/ui/list_screen.dart";

/// Spec lot H (2026-11-17) : le « + » du widget doit arriver sur le champ
/// d'ajout de la liste ACTIVE du widget, pas sur le fallback home.
void main() {
  const listA = "11111111-2222-3333-4444-555555555555";
  const listB = "22222222-3333-4444-5555-666666666666";

  testWidgets("deep-link quickadd : ListScreen de la liste cible, champ d'ajout focalisé",
      (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    for (final (id, title) in [(listA, "Achats"), (listB, "Tâches")]) {
      await db.upsertList(LocalListsCompanion(
        id: Value(id),
        title: Value(title),
        ownerId: const Value(""),
        updatedAt: Value(DateTime.now().toUtc()),
        dirty: const Value(false),
        localOnly: const Value(true),
      ));
    }
    state.quickAddRequested = true;
    state.quickAddListId = listB;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: HomeScreen(state: state)));
    await tester.pumpAndSettle();

    expect(find.byType(ListScreen), findsOneWidget,
        reason: "le quick-add doit pousser la ListScreen");
    expect(tester.widget<ListScreen>(find.byType(ListScreen)).listId, listB,
        reason: "la liste cible (active du widget), pas le fallback");
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode?.hasFocus, isTrue,
        reason: "le champ d'ajout doit être focalisé (clavier ouvert)");
    await db.close();
  });
}
