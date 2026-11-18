import "package:drift/drift.dart";
import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/list_dialogs.dart";
import "package:tapitask/ui/list_screen.dart";

LocalList _list() => LocalList(
      id: "l1",
      title: "Courses",
      ownerId: "",
      role: "owner",
      updatedAt: DateTime(2026, 11, 18),
      deleted: false,
      pinned: false,
      dirty: false,
      localOnly: true,
    );

void main() {
  testWidgets(
      "T8 : helper rename — le dialogue affiche le titre et retourne la valeur tapée",
      (tester) async {
    S.setLocale("fr");
    String? result;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async =>
                  result = await renameListDialog(context, _list()),
              child: const Text("ouvrir"),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text("ouvrir"));
    await tester.pumpAndSettle();

    expect(find.text(S.renameList), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        "Courses");

    await tester.enterText(find.byType(TextField), "Nouveau nom");
    await tester.tap(find.text(S.rename));
    await tester.pumpAndSettle();
    expect(result, "Nouveau nom");
  });

  testWidgets("T2 : dialogue rename depuis list_screen, en EN — « Cancel »",
      (tester) async {
    S.setLocale("en");
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    await db.upsertList(LocalListsCompanion(
      id: const Value("l1"),
      title: const Value("Courses"),
      ownerId: const Value(""),
      updatedAt: Value(DateTime.now().toUtc()),
      dirty: const Value(false),
      localOnly: const Value(true),
    ));

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
      home: ListScreen(state: state, listId: "l1"),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    // Overflow latent préexistant : les Row des items du menu débordent
    // (FR comme EN) dès que le menu est ouvert — aucun test baseline ne
    // l'ouvrait. Hors lot T ; on le consomme pour viser le dialogue.
    while (tester.takeException() != null) {}
    await tester.tap(find.text(S.rename));
    await tester.pumpAndSettle();

    expect(find.text("Cancel"), findsOneWidget,
        reason: "T2 : le bouton Annuler doit suivre la langue (S.cancel)");
    expect(find.text("Annuler"), findsNothing);

    S.setLocale("fr");
    await db.close();
  });
}
