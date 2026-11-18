import "package:drift/drift.dart" hide isNull;
import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/state/app_state.dart";

/// Spec lot F (2026-11-17) : le push natif « widgetLaunch » ne doit pas
/// notifier au milieu d'une frame (assertion framework / écran rouge).
void main() {
  const kListId = "11111111-2222-3333-4444-555555555555";

  /// AppState prêt pour un launch widget : 1 liste visible,
  /// [withToken] = false → sans session (accessToken resté null).
  Future<(AppDb, AppState)> makeState({bool withToken = true}) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    state.api = await ApiClient.load();
    if (withToken) state.api.accessToken = "test-token";
    await db.upsertList(LocalListsCompanion(
      id: const Value(kListId),
      title: const Value("Achats"),
      ownerId: const Value(""),
      updatedAt: Value(DateTime.now().toUtc()),
      dirty: const Value(false),
      localOnly: const Value(true),
    ));
    return (db, state);
  }

  testWidgets("quickadd : notify différé post-frame, flags posés aussitôt",
      (tester) async {
    final (db, state) = await makeState();
    var notified = 0;
    state.addListener(() => notified++);
    // ValueNotifier : marque l'arbre dirty pour que pump() exécute une
    // frame réelle (cas réel : la chaîne sync concurrente build une frame).
    final tick = ValueNotifier(0);
    await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<int>(
            valueListenable: tick,
            builder: (_, v, __) => Scaffold(body: Text('$v')))));
    await tester.pump();

    notified = 0;
    await state.applyWidgetUriForTesting(
        Uri.parse("tapitask://quickadd?list=$kListId"));
    expect(notified, 0, reason: "pas de notify avant le post-frame");
    expect(state.quickAddRequested, isTrue);

    tick.value++; // frame programmée (vsync)
    await tester.pump(); // post-frame
    expect(notified, 1);
    expect(state.quickAddListId, kListId);
    await db.close();
  });

  testWidgets(
      "quickadd sans session : flags posés (notify différé post-frame), id liste posé",
      (tester) async {
    final (db, state) = await makeState(withToken: false);
    expect(state.api.accessToken, isNull);
    var notified = 0;
    state.addListener(() => notified++);
    final tick = ValueNotifier(0);
    await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<int>(
            valueListenable: tick,
            builder: (_, v, __) => Scaffold(body: Text('$v')))));
    await tester.pump();

    notified = 0;
    await state.applyWidgetUriForTesting(
        Uri.parse("tapitask://quickadd?list=$kListId"));
    expect(notified, 0, reason: "pas de notify avant le post-frame");
    expect(state.quickAddRequested, isTrue);

    tick.value++;
    await tester.pump(); // post-frame
    expect(notified, 1);
    expect(state.quickAddListId, kListId);
    await db.close();
  });

  testWidgets("URI non quickadd : aucun effet, aucun notify", (tester) async {
    final (db, state) = await makeState();
    var notified = 0;
    state.addListener(() => notified++);
    final tick = ValueNotifier(0);
    await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<int>(
            valueListenable: tick,
            builder: (_, v, __) => Scaffold(body: Text('$v')))));
    await tester.pump();

    notified = 0;
    await state.applyWidgetUriForTesting(
        Uri.parse("tapitask://home?list=$kListId"));
    expect(notified, 0);
    tick.value++;
    await tester.pump();
    expect(notified, 0);
    expect(state.quickAddRequested, isFalse);
    expect(state.quickAddListId, isNull);
    await db.close();
  });
}
