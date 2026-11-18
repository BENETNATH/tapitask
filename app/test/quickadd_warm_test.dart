import "package:drift/drift.dart" hide isNull;
import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/home_screen.dart";
import "package:tapitask/ui/list_screen.dart";

/// Spec 2026-11-18 lot Q (Q1) : le « + » du widget doit relancer le
/// quickadd alors que l'app est déjà ouverte (warm). Le flag
/// `quickAddRequested` EST la garde par requête ; un latch permanent
/// bloquait toute relance après le premier quickadd.
void main() {
  const listId = "11111111-2222-3333-4444-555555555555";

  Future<AppState> setup() async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    await db.upsertList(LocalListsCompanion(
      id: const Value(listId),
      title: const Value("alpha"),
      ownerId: const Value(""),
      updatedAt: Value(DateTime.now().toUtc()),
      dirty: const Value(false),
      localOnly: const Value(true),
    ));
    return AppState(db: db);
  }

  /// Relance widget + 1 frame forcé : `_applyWidgetUri` diffère son
  /// `notifyListeners` en post-frame, et en test `pump()` ne bâtit un
  /// frame que s'il a été demandé — en production, c'est le frame de
  /// onNewIntent (reprise d'activity) qui joue ce rôle.
  Future<void> relaunch(WidgetTester tester, AppState state, Uri uri) async {
    await state.applyWidgetUriForTesting(uri);
    tester.binding.scheduleFrame();
    await tester.pumpAndSettle();
  }

  testWidgets("Q1 : relance warm depuis le home — le quickadd se relance",
      (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    final state = await setup();
    final db = state.db;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: HomeScreen(state: state)));
    await tester.pumpAndSettle();

    final uri = Uri.parse("tapitask://quickadd?list=$listId");
    // 1ère relance (cold) : la ListScreen est poussée.
    await relaunch(tester, state, uri);
    expect(find.byType(ListScreen), findsOneWidget,
        reason: "cold : le quickadd pousse la liste cible");

    // Retour au home.
    Navigator.of(tester.element(find.byType(ListScreen))).pop();
    await tester.pumpAndSettle();

    // 2e relance (warm, app déjà ouverte).
    await relaunch(tester, state, uri);
    expect(find.byType(ListScreen), findsOneWidget,
        reason: "warm : la 2e relance du widget doit rouvrir le quickadd (Q1)");
    await db.close();
  });

  testWidgets("Q1 : relance warm depuis l'écran liste — 2e ListScreen poussée",
      (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    final state = await setup();
    final db = state.db;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: HomeScreen(state: state)));
    await tester.pumpAndSettle();

    final uri = Uri.parse("tapitask://quickadd?list=$listId");
    await relaunch(tester, state, uri);
    expect(find.byType(ListScreen), findsOneWidget);

    // Pas de pop : on reste sur l'écran liste, le home est offstage.
    // skipOffstage: false — les routes sous le stack restent dans l'arbre
    // mais hors scène (find.byType les exclut par défaut).
    await relaunch(tester, state, uri);
    expect(find.byType(ListScreen, skipOffstage: false), findsNWidgets(2),
        reason: "warm depuis l'écran liste : le home (offstage) pousse la 2e "
            "ListScreen (Q1)");
    await db.close();
  });
}
