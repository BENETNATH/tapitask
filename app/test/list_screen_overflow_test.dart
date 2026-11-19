import "package:drift/drift.dart" hide isNull;
import "package:flutter_test/flutter_test.dart";
import "package:drift/native.dart";
import "package:material_ui/material_ui.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/list_screen.dart";

/// Ralentit les seules lectures (SELECT) : la DB en mémoire répond avant
/// le 1er frame de l'État neuf (switch lot Q) — le flash « Liste » + vide
/// serait invisible. L'horloge de test n'avance que via pumpAndSettle,
/// donc le 1er frame après le switch voit toujours les données nulles.
class _SlowExecutor extends QueryExecutor {
  _SlowExecutor(this._inner);
  final QueryExecutor _inner;

  @override
  SqlDialect get dialect => _inner.dialect;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) => _inner.ensureOpen(user);

  @override
  Future<List<Map<String, Object?>>> runSelect(
      String statement, List<Object?> args) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return _inner.runSelect(statement, args);
  }

  @override
  Future<int> runInsert(String statement, List<Object?> args) =>
      _inner.runInsert(statement, args);

  @override
  Future<int> runUpdate(String statement, List<Object?> args) =>
      _inner.runUpdate(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) =>
      _inner.runDelete(statement, args);

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) =>
      _inner.runCustom(statement, args);

  @override
  Future<void> runBatched(BatchedStatements statements) =>
      _inner.runBatched(statements);

  @override
  TransactionExecutor beginTransaction() => _inner.beginTransaction();

  @override
  QueryExecutor beginExclusive() => _inner.beginExclusive();

  @override
  Future<void> close() => _inner.close();
}

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

  testWidgets(
      "Q2 : switch de liste en place — pas de frame « Liste » ni frame vide",
      (tester) async {
    // 2 listes : alpha (index 0, updatedAt le plus récent) puis beta.
    // alpha → next (chevron ▶) → beta.
    final db = AppDb.forTesting(_SlowExecutor(NativeDatabase.memory()));
    final state = AppState(db: db);
    const idA = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    const idB = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff";
    final now = DateTime(2026, 11, 18);
    await db.upsertList(LocalListsCompanion(
      id: const Value(idA),
      title: const Value("alpha"),
      ownerId: const Value(""),
      updatedAt: Value(now),
      dirty: const Value(false),
      localOnly: const Value(true),
    ));
    await db.upsertList(LocalListsCompanion(
      id: const Value(idB),
      title: const Value("beta"),
      ownerId: const Value(""),
      updatedAt: Value(now.subtract(const Duration(hours: 1))),
      dirty: const Value(false),
      localOnly: const Value(true),
    ));
    await db.addItem("itemA", idA, "a1", 0, now);
    await db.addItem("itemB", idB, "b1", 0, now);

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    // Route nommée "/list" comme main.dart : le switch passe par
    // pushReplacementNamed avant le fix (État neuf → frame « Liste » + vide).
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
      onGenerateRoute: (settings) => settings.name == "/list"
          ? MaterialPageRoute(
              builder: (_) => ListScreen(
                  state: state, listId: settings.arguments as String))
          : null,
      home: ListScreen(state: state, listId: idA),
    ));
    // pumpAndSettle n'attend pas un futur en attente (horloge factice) :
    // avancer explicitement au-delà du délai de lecture de _SlowExecutor.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text("alpha ▾"), findsOneWidget);
    expect(find.text("a1"), findsOneWidget);

    await tester.tap(find.byTooltip(S.nextList));
    // pushReplacementNamed (avant fix) : la nouvelle route n'entre dans
    // l'arbre qu'au 2e frame après up() — les 2 pump() ci-dessous donnent
    // le 1er frame de l'écran après le switch. (Horloge factice gelée :
    // les lectures retardées de _SlowExecutor n'ont pas abouti → si un
    // État neuf est monté, il est obligatoirement dans un état nul.)
    await tester.pump();
    await tester.pump(); // le 1er frame de l'écran après le switch

    expect(find.text("Liste"), findsNothing,
        reason: "Q2 : le titre ne doit pas flasher « Liste » au 1er frame");
    expect(find.text(S.nothingToDoAdd), findsNothing,
        reason: "Q2 : le corps ne doit pas flasher l'état vide au 1er frame");
    expect(find.text("a1"), findsOneWidget,
        reason: "Q2 : les données précédentes restent affichées le temps du "
            "rechargement");

    // Rechargement : laisser les lectures retardées aboutir.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text("beta ▾"), findsOneWidget);
    expect(find.text("b1"), findsOneWidget);
    expect(find.text("a1"), findsNothing);
    await db.close();
  });

  testWidgets("téléphone étroit : le titre ne chevauche pas le menu ⋮",
      (tester) async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    final id1 = await addList(db, "list1", "Google Tasks - My Tasks");
    await addList(db, "list2", "Autre");

    // ~360 dp de large, police système agrandie (cas de la capture).
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: MediaQuery(
          data: const MediaQueryData(
              size: Size(360, 800), textScaler: TextScaler.linear(1.3)),
          child: ListScreen(state: state, listId: id1),
        )));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final appBar = find.byType(AppBar);
    final title = find.descendant(
        of: appBar, matching: find.text("Google Tasks - My Tasks ▾"));
    final menu = find.descendant(of: appBar, matching: find.byIcon(Icons.more_vert));
    expect(title, findsOneWidget);
    expect(menu, findsOneWidget);
    expect(tester.getRect(title).right,
        lessThanOrEqualTo(tester.getRect(menu).left));
    // Partager / nettoyer sont passés dans le menu ⋮.
    expect(find.descendant(of: appBar, matching: find.byIcon(Icons.share)),
        findsNothing);
    // Puce d'échéance dans la zone d'ajout.
    expect(find.byIcon(Icons.event_outlined), findsOneWidget);
    await db.close();
  });
}
