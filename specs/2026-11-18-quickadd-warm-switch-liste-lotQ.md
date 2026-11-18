# Lot Q — quickadd warm + switch de liste sans éclat

Date : 2026-11-18. Repère : `3205c55` (lot P).

Retour device (APK release lot P) : « presque parfait », 2 points restants :

1. **« + » du widget en warm** : application fermée → ouvre bien l'ajout d'item
   de la liste affichée. Application déjà ouverte → ouvre simplement l'app
   telle qu'elle était (jamais de quickadd).
2. **Switch de liste (chevrons ◀ ▶ / menu du titre)** : l'écran se vide,
   affiche une liste vide intitulée « Liste », puis se rafraîchit sur la
   liste cible. Pas propre.

## Q1 — Quickadd warm : le latch `_quickAddShown` bloque toute relance

**Cause (vérifiée dans le code)** : `app/lib/ui/home_screen.dart`
- l.24 : `bool _quickAddShown = false;`
- l.64 : `if (_quickAddShown || !widget.state.quickAddRequested) return;`
- l.65 : `_quickAddShown = true;`

`_quickAddShown` est posé au **premier** quickadd et n'est remis à `false`
**nulle part**. Le quickadd suivant (app déjà ouverte) arrive via
`onNewIntent` natif → `widgetLaunch` (MethodChannel) →
`_applyWidgetUri` (app_state.dart:150) → `quickAddRequested = true` +
`notifyListeners()` → `HomeScreen._onChanged` → `_maybeQuickAdd()` →
**bloqué par `_quickAddShown`**. Le flag `quickAddRequested` reste en
suspens jusqu'au kill du process (nouvau State au prochain cold start →
ça re-marche une fois). Symptôme exact reporté : cold OK, warm « à chaque »
KO.

**Fix (cible de référence)** : supprimer le latch. Le flag
`quickAddRequested` EST la garde par requête :

- `app/lib/ui/home_screen.dart` :
  - supprimer le champ `bool _quickAddShown = false;` (l.24)
  - dans `_maybeQuickAdd()` : remplacer la garde
    `if (_quickAddShown || !widget.state.quickAddRequested) return;`
    + `_quickAddShown = true;` par
    `if (!widget.state.quickAddRequested) return;` — et lire
    `final target = widget.state.quickAddListId;` puis
    `widget.state.quickAddRequested = false; widget.state.quickAddListId = null;`
    **avant tout await** (déjà le cas : le champ `target` est lu avant les
    awaits existants ; conserver l'ordre lecture→effacement synchrone)
  - adapter la `debugPrint` existante (plus de référence à `_quickAddShown`)

Pas de double-push : les deux call-sites (post-frame `initState` l.45 et
`_onChanged` l.51) tournent dans le même post-frame ; le 1er efface le flag
synchrone avant son premier `await`, le 2nd voit `false` → no-op.

**Tests (TDD, `flutter test`)** : nouveau fichier
`app/test/quickadd_warm_test.dart` (mêmes infra que
`list_screen_overflow_test.dart` : `AppDb.forTesting(NativeDatabase.memory())`,
`addList`, `MaterialApp` avec `localizationsDelegates` :
- Test A « relance warm depuis le home » : 1 liste ;
  `await state.applyWidgetUriForTesting(Uri.parse("tapitask://quickadd?list=$id"))`
  → `pumpAndSettle` → `find.byType(ListScreen)` (cold OK) →
  `Navigator.of(tester.element(find.byType(ListScreen))).pop()` +
  `pumpAndSettle` (retour home) → `applyWidgetUriForTesting(même URI)` →
  `pumpAndSettle` → `expect(find.byType(ListScreen), findsOneWidget)`.
  (avant fix : rouge — le latch bloque la 2e relance)
- Test B « relance warm depuis l'écran liste » : idem mais sans pop (on
  reste sur l'écran liste) → `applyWidgetUriForTesting` → `pumpAndSettle` →
  `expect(find.byType(ListScreen), findsNWidgets(2))` (home offstage pousse
  la 2e). (avant fix : rouge — findsNWidgets(1))

## Q2 — Switch de liste : basculer en place, sans frame « Liste » + vide

**Cause (vérifiée dans le code)** : `app/lib/ui/list_screen.dart` l.53-56 :

```dart
void _switchList(String listId) {
  if (listId == widget.listId) return;
  Navigator.pushReplacementNamed(context, "/list", arguments: listId);
}
```

`pushReplacementNamed` démonte l'État courant et monte un État neuf
(`ListScreenRoute` → `ListScreen` neuf, main.dart:145-152). Sur le 1er
frame de l'État neuf :
- titre : `FutureBuilder(future: state.db.visibleLists())` (l.172-174) →
  `snapshot.data == null` → `lists = []` → branche « < 2 listes » →
  `Text(list?.title ?? "Liste")` (l.180) → **« Liste »**
- corps : `StreamBuilder(stream: state.db.watchItemsOf(widget.listId))`
  (l.416-419) → pas encore d'événement → `items = []` → état vide
  `S.nothingToDoAdd` (l.421-425)

→ frame « Liste » + vide, puis les données arrivent → l'éclat reporté.

**Fix (cible de référence)** : switch **en place** (même État, `setState`) +
**garder les dernières données affichées** pendant le rechargement :

- `app/lib/ui/list_screen.dart` (`_ListScreenState`) :
  - `String _listId;` initialisé dans `initState` depuis `widget.listId`
  - cache listes : `List<LocalList> _lists = const [];` +
    `void _loadLists() { widget.state.db.visibleLists().then((l) { if (!mounted) return; setState(() => _lists = l); }); }`
    appelé dans `initState` et dans `_onChanged` (à la place du
    `FutureBuilder` du titre)
  - cache items : `List<LocalItem> _items = const [];` +
    `StreamSubscription? _itemsSub;` +
    `void _loadItems() { _itemsSub?.cancel(); _itemsSub = widget.state.db.watchItemsOf(_listId).listen((items) { if (!mounted) return; setState(() => _items = items); }); }`
    appelé dans `initState` et dans `_switchList` (à la place du
    `StreamBuilder` du corps)
  - `_switchList` : `if (listId == _listId) return; _listId = listId; _loadItems(); setState(() {});`
  - dans `build`, remplacer le `FutureBuilder` du titre (l.172-242) par le
    même contenu construit sur `_lists` / `_listId` (le titre
    `${list?.title ?? "Liste"} ▾` ne s'affiche « Liste » que si `_lists`
    est vide au montage frais — cas home→push, masqué par la transition,
    HORS PÉRIMÈTRE) ; remplacer le `StreamBuilder` du corps (l.416) par le
    même rendu construit sur `_items`
  - remplacer les 10 lectures `widget.listId` restantes de l'État par
    `_listId` : l.176 (indexWhere titre), l.203 (initialValue), l.210
    (icône check), l.265 (purgeDone), l.272 (ShareScreen), l.417 (supprimé
    avec le StreamBuilder), l.753 (`_list()`), l.806 (`_submit`)
  - `dispose` : `_itemsSub?.cancel();` avant le `removeListener` existant

Comportement inchangé : back (même route, pas de stack modifiée),
chevrons/menu (mêmes cibles), menu ⋮ (mêmes actions sur `_listId`),
`_submit` (ajoute dans la liste courante). Comportement changé assumé : le
brouillon du champ « Ajouter… » et le répéteur `_recurrence` **survivent**
au switch (l'État n'est plus démonté) — plus propre qu'un reset.

**Tests (TDD, `flutter test`)** : nouveau test dans
`app/test/list_screen_overflow_test.dart` (ou fichier dédié) :
- 2 listes « alpha » (idA) et « beta » (idB) ; item « a1 » dans A, item
  « b1 » dans B ; `pumpWidget(MaterialApp(home: ListScreen(state: state,
  listId: idA), localizationsDelegates: ...))`, `pumpAndSettle`
- `expect(find.text("alpha ▾"), findsOneWidget)` +
  `expect(find.text("a1"), findsOneWidget)`
- `await tester.tap(find.byTooltip(S.nextList));` puis
  `await tester.pump();` (UN seul frame — le 1er frame après switch)
- `expect(find.text("Liste"), findsNothing)` (titre : avant fix, rouge —
  l'État neuf montre « Liste »)
- `expect(find.text(S.nothingToDoAdd), findsNothing)` +
  `expect(find.text("a1"), findsOneWidget)` (corps : les données
  précédentes restent affichées le temps du rechargement — avant fix,
  rouge — état vide)
- `await tester.pumpAndSettle();`
- `expect(find.text("beta ▾"), findsOneWidget)` +
  `expect(find.text("b1"), findsOneWidget)` +
  `expect(find.text("a1"), findsNothing)`

## Hors périmètre

- 1er frame du push home→liste (« Liste » 1 frame, masqué par la
  transition) — non signalé, à traiter si ça devient visible
- retrait des sondes TAPITASK-FLOW (lot dédié)
- build/release

## Vérification

1. `cd app && flutter test` — vert (nouveau : quickadd_warm_test ×2,
   switch ×1, + existants)
2. `flutter build apk --debug`
3. device :
   - cold : + widget → quickadd liste (inchangé)
   - warm depuis home ET depuis l'écran liste : + widget → quickadd
   - chevrons ◀▶ + menu du titre : switch sans frame « Liste »/vide
4. suite complète relancée ×2 (stabilité)
