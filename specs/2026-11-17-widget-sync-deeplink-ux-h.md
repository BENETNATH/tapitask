# Lot H — Widget : sync du cochage au resume, deep-link « + » avec focus, bouton Ouvrir en icône, défaut 2x2

Date : 2026-11-17
Statut : spec prête pour implémentation
APK : rebuild requis après ce lot (retest device)

Retest device 2026-11-17 : les 2 crashs du lot F sont résolus. Quatre
nouveaux points signalés :

- (A) le cochage d'un item dans le widget ne se répercute pas dans l'app
- (B) le « + » (widget 1x1) arrive au même endroit que « Ouvrir »
  (l'app/home) au lieu du champ d'ajout de la liste active du widget
- (C) faire le bouton « Ouvrir » plus simple, avec une icône
- (D) taille par défaut du widget liste : 4x3 trop grand → 2x2

## A — Le cochage widget → app n'est appliqué qu'au cold start

`_applyWidgetToggles()` (app_state.dart:190) lit `widget_toggled`
(via `WidgetService.pendingToggles()`, canal plugin `home_widget`),
applique `db.setDone(id, true)` et `clearToggles()` — mais il est
appelé UNIQUEMENT dans `init()` (app_state.dart:99).

Le flow réel : cocher dans le widget → le provider natif écrit
`widget_done_ids`/`widget_toggled` (prefs partagées) et redessine le
widget (c'est pourquoi le widget montre l'item coché) → on retourne
dans l'app → l'activity singleTask est RESUMÉE, pas re-créée →
`init()` ne rejoue pas → le toggle reste en attente → l'app montre
l'item non coché. Un seul force-stop + relance l'appliquerait.

Fix :
- `app_state.dart` : renommage `_applyWidgetToggles` →
  `applyWidgetToggles` (public, le try/catch existant est conservé).
- `main.dart` `didChangeAppLifecycleState(resumed)` : ajouter
  `appState.applyWidgetToggles();` à côté de `appState.sync.fullSync();`
  — chaque passage au premier plan applique les toggles en attente
  (le `clearToggles()` rend l'opération idempotente ensuite).

Note : la direction app → widget est déjà correcte (`toggleItem`
appelle `_refreshWidget()`).

## B — Le « + » doit arriver sur le champ d'ajout de la liste active

Deux causes :
1. `QuickAddWidgetProvider.onUpdate` lance `tapitask://quickadd` SANS
   liste → l'app retombe sur le fallback (1re liste épinglée) ou home,
   pas sur la liste AFFICHÉE dans le widget liste.
2. Même avec une liste, `HomeScreen._maybeQuickAdd` pousse
   `ListScreen` SANS focaliser le champ d'ajout.

Fix :
- `QuickAddWidgetProvider.kt` `onUpdate` : lire les prefs partagées
  (`HomeWidgetPlugin.getData`) : `list_count_lists`, `list_index`
  (clamping index >= total → 0), `list_<i>_id` ; si une liste existe →
  `data = Uri.parse("tapitask://quickadd?list=<id>")`, sinon
  `tapitask://quickadd` (fallback existant). La validation stricte
  côté Dart (validateQuickAddUri : UUID + membership visible) est
  inchangée.
- `ListWidgetProvider.kt` `onReceive(ACTION_CYCLE)` : après
  `triggerUpdate(context)`, déclencher aussi l'update du
  `QuickAddWidgetProvider` (son PendingIntent embarque l'id de liste
  au moment de son onUpdate — il serait obsolète après un cycle
  ◀/▶). Petit helper `triggerQuickAddUpdate(context)` (même pattern
  que `triggerUpdate`, ids de QuickAddWidgetProvider).
- `list_screen.dart` : nouveau paramètre constructeur
  `this.focusAdd = false` ; `FocusNode` dédié sur le TextField
  d'ajout rapide ; si `focusAdd`, `requestFocus()` en
  `addPostFrameCallback` (le clavier s'ouvre avec le focus).
- `home_screen.dart` `_maybeQuickAdd` : `ListScreen(..., focusAdd: true)`
  sur les deux Navigator.push (cible précise + fallback).

Conséquence : le bouton « ＋ Ajouter » du widget liste (déjà
`tapitask://quickadd?list=<id>`) bénéficiera du focus aussi.

## C — Bouton « Ouvrir » : texte → icône

- Nouveau `res/drawable/ic_widget_open.xml` : vector drawable 24dp,
  glyphe « open in new » (flèche qui sort d'un carré), fill blanc
  (le fond du bouton reste `widget_open_background`, teal).
- `list_widget.xml` : le TextView `widget_open` (« Ouvrir ») devient
  une `ImageView` (même id `widget_open`, même fond, ~40dp, padding 8dp,
  `scaleType=fitCenter`, `contentDescription=@string/widget_open_desc`
  — ajouter la string).
- `ListWidgetProvider.kt` : dans `render()`, remplacer
  `setTextViewText(R.id.widget_open, ...)` par
  `setImageViewResource(R.id.widget_open, R.drawable.ic_widget_open)` ;
  idem dans la branche état vide (total == 0) pour que l'icône existe
  même sans listes. Les bindings PendingIntent (ids) sont inchangés.
- `label_open` (WidgetService) : la sauvegarde est conservée (hors
  périmètre, inoffensive).

## D — Taille par défaut du widget liste : 2x2

`list_widget_info.xml` :
- `minWidth` 180dp → 110dp
- `minHeight` 110dp → 110dp (inchangé)
- `targetCellWidth` 3 → 2
- `targetCellHeight` 2 → 2

En 2x2, le layout montre titre + 2 items + la rangée des boutons
(les items 3-5 sont clipés) ; `resizeMode="horizontal|vertical"` est
conservé — l'utilisateur peut encore agrandir pour voir plus
d'items.

## Tests (Dart, TDD — flutter test)

Nouveau `app/test/widget_toggles_test.dart` :
1. **toggle appliqué + effacé** : item en base ; mock du canal
   `MethodChannel('home_widget')` (TestDefaultBinaryMessenger) :
   `getWidgetData{id: "widget_toggled"}` → `"<id>"`,
   `saveWidgetData{id, data}` mémorisé ; `state.applyWidgetToggles()`
   → item `done` en base + `widget_toggled` vidé + `widget_done_ids`
   vidé.
2. **rien en attente → aucun effet** : `getWidgetData` → null → item
   non coché, aucune exception.

Nouveau `app/test/quick_add_focus_test.dart` :
3. **deep-link quickadd → ListScreen + focus** : 2 listes en base,
   `AppState` ; pump `MaterialApp(home: HomeScreen(state))` avec
   `quickAddRequested = true` + `quickAddListId = <id cible>` ;
   pumpAndSettle → on est sur la ListScreen de la bonne liste ; le
   unique TextField est focalisé (`tester.widget<TextField>(...).focusNode.hasFocus`
   est true).

Rappels : les 28 tests existants restent verts. Pas de nouvelle
dépendance. Les fichiers Kotlin/XML ne sont pas testables en CI
(pas d'infra Kotlin) : vérif build + retest device.

## Vérification

- `flutter analyze` clean (0 issue).
- `flutter test` → 28 + 3 nouveaux, tous verts.
- `flutter build apk --debug` OK (valide Kotlin + XML).
- Retest device :
  - cocher un item dans le widget → rouvrir l'app (sans tuer le
    process) → l'item est coché dans l'app
  - « + » → l'app s'ouvre sur la liste active du widget, champ
    d'ajout focalisé, clavier ouvert ; idem pour « ＋ Ajouter »
  - cycle ◀/▶ dans le widget liste puis « + » → toujours la bonne liste
  - bouton Ouvrir : icône, pas de texte
  - nouveau placement du widget liste : 2x2

## Hors périmètre

- Les 2 findings audit (togglecycle, fmtexc) : le test
  togglecycle sera couvert par le retest « cocher un item » ;
  fmtexc déjà couvert par la validation stricte (lot D).
- Le widget QuickAdd reste 1x1 (inchangé).
