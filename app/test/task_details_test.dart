import "package:drift/drift.dart";
import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/data/google_tasks_api.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/list_screen.dart";

class _TestState extends AppState {
  _TestState(AppDb db) : super(db: db);

  @override
  Future<void> toggleItem(String id, bool done) =>
      db.setDone(id, done, DateTime.now());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      "Google import preserves details and skips tasks already copied to the list",
      () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final state = AppState(db: db);
    await state.init(lightweight: true);
    await db.upsertList(LocalListsCompanion.insert(
        id: "list", title: "List", ownerId: "", updatedAt: DateTime.now()));
    final completedAt = DateTime.utc(2026, 11, 22, 16);
    final tasks = <GoogleTask>[
      (
        id: "child",
        title: "Child",
        parent: "parent",
        notes: null,
        dueDay: null,
        done: false,
        completedAt: null
      ),
      (
        id: "parent",
        title: "Parent",
        parent: null,
        notes: "Imported notes",
        dueDay: "2026-11-23",
        done: true,
        completedAt: completedAt
      ),
    ];

    expect(await state.importGoogleTasks("list", "google-list", tasks), 2);
    final items = await db.itemsOf("list");
    final parent = items.singleWhere((item) => item.label == "Parent");
    expect(parent.done, isTrue);
    expect(parent.completedAt?.toUtc(), completedAt);
    expect(parent.localDue, DateTime(2026, 11, 23));
    expect(parent.notes, "Imported notes");
    expect(
        items.singleWhere((item) => item.label == "Child").parentId, parent.id);
    await db.setItemDetails(parent.id, DateTime.now(), notes: "Edited locally");
    expect(await state.importGoogleTasks("list", "google-list", tasks), 0);
    expect((await db.getItem(parent.id))!.notes, "Edited locally");
  });

  testWidgets("title opens details and only the checkbox completes the task",
      (tester) async {
    final db = AppDb.forTesting(DatabaseConnection(NativeDatabase.memory(),
        closeStreamsSynchronously: true));
    addTearDown(db.close);
    final now = DateTime.now();
    await db.upsertList(LocalListsCompanion.insert(
        id: "list", title: "List", ownerId: "", updatedAt: now));
    await db.addItem("item", "list", "Example task", 0, now,
        notes: "Supporting text\nhttps://example.com/docs");

    await tester.pumpWidget(
        MaterialApp(home: ListScreen(state: _TestState(db), listId: "list")));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Example task"));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text("https://example.com/docs"), findsOneWidget);
    expect((await db.getItem("item"))!.done, isFalse);
    await tester.tap(find.text(S.cancel));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(S.completedTasks), findsOneWidget);
    expect((await db.getItem("item"))!.done, isTrue);
    await tester.tap(find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.hideCompletedTasks));
    await tester.pumpAndSettle();
    expect(find.text("Example task"), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
