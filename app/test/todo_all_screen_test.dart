import "package:drift/drift.dart" hide isNull;
import "package:drift/native.dart";
import "package:material_ui/material_ui.dart";
import "package:flutter_test/flutter_test.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/todo_all_screen.dart";

void main() {
  Future<String> addList(AppDb db, String id, String title) async {
    await db.upsertList(LocalListsCompanion(
      id: Value(id),
      title: Value(title),
      ownerId: const Value(""),
      updatedAt: Value(DateTime.now().toUtc()),
      dirty: const Value(false),
      localOnly: const Value(false),
    ));
    return id;
  }

  Future<void> pumpTodoAll(WidgetTester tester, AppState state) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: TodoAllScreen(state: state)));
    await tester.pumpAndSettle();
  }

  testWidgets("état vide : texte exact S.allDone", (tester) async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    await addList(db, "l1", "Courses");

    await pumpTodoAll(tester, state);

    expect(find.text(S.allDone), findsOneWidget);
    await db.close();
  });

  testWidgets("item en retard : échéance + suffixe dans le sous-titre",
      (tester) async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    await addList(db, "l2", "Courses");
    final now = DateTime.now();
    await db.addItem("i1", "l2", "Facture", 0, now,
        dueDate: DateTime(now.year, now.month, now.day - 1, 9));

    await pumpTodoAll(tester, state);

    expect(find.text("Facture"), findsOneWidget);
    expect(
        find.text("Courses  •  ${S.yesterdayOverdue}${S.t("overdueSuffix")}"),
        findsOneWidget);
    await db.close();
  });
}
