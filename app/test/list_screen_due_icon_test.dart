import "package:drift/drift.dart" hide isNull;
import "package:drift/native.dart";
import "package:material_ui/material_ui.dart";
import "package:flutter_test/flutter_test.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/list_screen.dart";

void main() {
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

  Future<void> pumpList(WidgetTester tester, AppState state,
      String listId) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: listId)));
    await tester.pumpAndSettle();
  }

  testWidgets("sous-titre échéance : icônes Material, aucun emoji",
      (tester) async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    // Masque l'icône Icons.event de la secondary pour que l'icône du
    // sous-titre soit la seule occurrence.
    state.settings["visible_actions"] = false;
    final listId = await addList(db, "list1", "Courses");
    final base = DateTime.now().add(const Duration(days: 3));
    final due = DateTime(base.year, base.month, base.day, 9);
    await db.addItem("i1", listId, "Pain", 0, DateTime.now(),
        dueDate: due, recurrence: "daily", notes: "levure");

    await pumpList(tester, state, listId);

    expect(find.textContaining("📅"), findsNothing);
    expect(find.textContaining("↻"), findsNothing);
    expect(find.textContaining("📝"), findsNothing);
    expect(find.byIcon(Icons.event), findsOneWidget);
    expect(find.byIcon(Icons.replay), findsOneWidget);
    expect(find.byIcon(Icons.notes_outlined), findsOneWidget);
    expect(find.textContaining("${due.day}/${due.month}"), findsOneWidget);
    await db.close();
  });

  testWidgets("échéance dépassée : icône warning, aucun emoji ⚠",
      (tester) async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    state.settings["visible_actions"] = false;
    final listId = await addList(db, "list2", "Tâches");
    await db.addItem("i2", listId, "Facture", 0, DateTime.now(),
        dueDate: DateTime.now().subtract(const Duration(days: 1)));

    await pumpList(tester, state, listId);

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.textContaining("⚠ "), findsNothing);
    await db.close();
  });
}
