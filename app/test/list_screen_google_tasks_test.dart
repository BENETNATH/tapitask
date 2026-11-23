import "dart:convert";

import "package:drift/drift.dart" hide isNull;
import "package:drift/native.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:material_ui/material_ui.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/list_screen.dart";

void main() {
  testWidgets("list export confirms the destination and reports partial writes",
      (tester) async {
    const authChannel = MethodChannel("com.tapitask/tapitask/google_tasks");
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(authChannel, (call) async {
      expect(call.method, "authorize");
      return "test-token";
    });
    addTearDown(() => messenger.setMockMethodCallHandler(authChannel, null));

    final db = AppDb.forTesting(DatabaseConnection(
      NativeDatabase.memory(),
      closeStreamsSynchronously: true,
    ));
    final now = DateTime(2026, 11, 23);
    await db.upsertList(LocalListsCompanion(
      id: const Value("source"),
      title: const Value("Achats"),
      ownerId: const Value(""),
      updatedAt: Value(now),
    ));
    await db.addItem("bread", "source", "Pain", 0, now);
    await db.addItem("rice", "source", "Riz", 1, now);
    await db.addItem("milk", "source", "Lait", 2, now);
    await db.setDone("milk", true, now);
    final state = AppState(db: db);
    addTearDown(db.close);

    final sent = <String>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: ListScreen(state: state, listId: "source"),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(PopupMenuButton<String>),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.sendOpenToGoogleTasks));
      await tester.pumpAndSettle();

      expect(find.text(S.googleTasksOpenCount(2)), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(DropdownButton<String>),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Courses Google").last);
      await tester.pumpAndSettle();
      expect(sent, isEmpty);

      await tester.tap(find.text(S.googleTasksSend));
      await tester.pumpAndSettle();
      expect(sent, ["Riz", "Pain"]);
      expect(find.text(S.googleTasksCopied(1, 2)), findsOneWidget);
      expect(find.text(S.googleTasksWriteFailed("Pain")), findsOneWidget);
      expect(find.text(S.googleTasksSend), findsNothing);
      await tester.tap(find.text(S.close));
      await tester.pumpAndSettle();
      expect(find.text("Riz"), findsOneWidget);

      await tester.longPress(find.text("Pain"));
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.sendToGoogleTasks));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.text("Pain")),
        findsOneWidget,
      );
      await tester.tap(find.text(S.cancel));
      await tester.pumpAndSettle();
      expect(sent, ["Riz", "Pain"]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => MockClient((request) async {
              if (request.method == "GET") {
                return http.Response(
                    '{"items":[{"id":"destination","title":"Courses Google"}]}',
                    200);
              }
              expect(request.url.path, "/tasks/v1/lists/destination/tasks");
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              expect(body.containsKey("due"), isFalse);
              expect(body["status"], "needsAction");
              sent.add(body["title"] as String);
              return http.Response('{}', sent.length == 1 ? 201 : 429);
            }));
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}
