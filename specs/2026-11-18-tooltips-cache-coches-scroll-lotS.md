# Lot S — tooltips paramètres, paramètre « cacher les items cochés », scroll

Date : 2026-11-18. Repère : `e7ce6b0` (lot R).

Retour device (APK release lot R) : « tout est en place », 3 commentaires :
1. les tooltips des paramètres marchent sur Windows mais pas sur Android
2. un paramètre pour cacher automatiquement les items cochés du volet et
   du widget — « ce n'est pas le cas actuellement sur le widget, ils
   restent affichés »
3. sur le volet et le widget, si l'items débordent de l'affichage →
   scroller verticalement

## S1 — Tooltips des paramètres : tap sur Android

**Constat** : `app/lib/ui/settings_screen.dart:48-69` — `_switchRow(info:)`
entoure l'icône d'info d'un `Tooltip`. Sur desktop (hover) ça marche ; sur
Android, un `Tooltip` ne s'affiche qu'au **long-press** — un tap simple sur
l'icône ne fait rien. L'utilisateur s'attend à un tap.

**Fix (cible de référence)** : l'icône d'info devient TAPABLE partout :
- dans `_switchRow`, remplacer le `Tooltip(child: Icon(...))` par
  `Tooltip(...)` conservé (hover desktop) dont le `child` est un
  `GestureDetector(onTap: () => _showInfo(info), child: Icon(...))`
  (InkWell 24×24 pour la rétroaction tactile)
- `_showInfo(String text)` : `showDialog` compact (title : le titre du
  réglage, content : le texte d'aide, un bouton fermer) — même pattern que
  les dialogues existants du fichier
- les réglages SANS `info` : rien ne change (pas d'icône, pas de tap)

**Tests (TDD)** : nouveau test dans `app/test/` (fichier dédié
`settings_screen_test.dart`) :
- pump `SettingsScreen(state: state)` avec 1 réglage à `info:` (ex.
  due_dates) → `expect(find.byIcon(Icons.info_outline), findsOneWidget)`
- `await tester.tap(find.byIcon(Icons.info_outline))` + `pumpAndSettle`
- `expect(find.text(S.dueDatesHelp), findsOneWidget)` (le dialogue est
  ouvert) → le test est ROUGE avant fix (le tap ne fait rien)

## S2 — Paramètre « Cacher les items cochés »

**Nouveau réglage utilisateur** : `settings["hide_done"]`, **défaut `true`**
(ce que l'utilisateur demande ; désactivable pour revenir à la vue barrée).

**Écrin** (settings_screen.dart, section « Volet & widget ») :
`_switchRow(S.hideDone, flag("hide_done", dflt: true), (v) => _toggle("hide_done", v), info: S.hideDoneHelp)`
— clés l10n fr+en dans `app/lib/l10n/s.dart` :
`S.hideDone` (« Cacher les items cochés » / "Hide checked items"),
`S.hideDoneHelp` (« Le volet et le widget n'affichent plus les items
cochés. Les items cochés restent dans la liste (voir dans l'app) » /
anglais équivalent).

**Volet (ListScreen)** :
- `app/lib/ui/list_screen.dart` — `_itemsBody()` :
  `final hideDone = widget.state.settings["hide_done"] as bool? ?? true;`
  puis `final top = items.where((i) => i.parentId == null &&
  (!hideDone || !i.done)).toList();`
  _(corrigé : la première version de la spec avait la formule inversée —
  `hideDone || !i.done` ne masquait rien ; les tests rouges ont validé la
  formule ci-dessus)_
- effet : réglage ON → les items cochés (et leurs sous-tâches, rendues
  dans la ligne parent) disparaissent du volet ; réglage OFF → comportement
  actuel (tout est affiché, les cochés barrés)
- le quickadd, la réordonnancement et le dismiss sont inchangés (le
  réordonnancement porte sur la liste visible — positions relatives
  préservées via `state.reorderItem`, qui est index-insensitif côté
  positions absolutes… **vérifier** : `reorderItem(id, pos)` écrit la
  position — avec des items cachés, l'index visible ≠ index absolu ; le
  fix minimal : conserver le comportement actuel du réordonnancement sur
  l'ordre visible EN recrant la position absolue par ordre stable — si
  `reorderItem` est position-absolue, le drag visible doit mapper vers la
  position absolue de l'item déplacé, pas l'index du slot ; à valider en
  lisant `reorderItem`/`position` dans app_state + database ; documenter la
  solution choisie dans le commit)

**Widget** :
- `app/lib/platform/widget_service.dart` — l'écriture des items respecte le
  réglage :
  - `hide_done` ON (défaut) : `db.uncheckedItemsOf(list.id)` (comportement
    actuel — les cochés ne sont jamais écrits)
  - `hide_done` OFF : `db.itemsOf(list.id)` (tous les items, ordre
    position) ; les items cochés sont écrits avec préfixe `✓  ` sur le
    label (le RemoteViews ne fait pas de barré ; le `☐  ` reste pour les
    non-cochés) — le provider ne change pas de logique d'affichage, il
    affiche ce qui est écrit
- l'écriture se fait pour **tous les items** (voir S3 — plus de plafond
  de 5 : `maxItems` supprimé, les clés `list_<li>_item_<j>`/`_id` sont
  écrites pour chaque item ; le provider/adapter itère jusqu'à
  `list_<li>_count`)
- le tap d'item coché dans le widget (réglage OFF) : la ligne est
  **non-cliquable** (pas de PendingIntent) — le toggle restant unidirectionnel
  (cocher) côté widget ; un item non-coché reste cliquable (ACTION_TOGGLE
  inchangé)

**Tests (TDD)** :
- volet : test dans `app/test/list_screen_overflow_test.dart` (ou dédié) —
  2 items (1 coché, 1 non) :
  - `state.settings["hide_done"] = true` → `pumpAndSettle` →
    `expect(find.text("<label coché>"), findsNothing)` + le non-coché
    visible (ROUGE avant fix — l'item coché est affiché)
  - `state.settings["hide_done"] = false` → le coché est visible (barré)
- widget_service : test existant du service (à trouver / créer) —
  - réglage ON : seules les clés `list_0_item_*` des items non-cochés
    sont non-vides
  - réglage OFF : tous les items écrits, les cochés préfixés `✓  `

## S3 — Scroll vertical (volet + widget)

**Volet** : le corps est déjà un `ReorderableListView` dans un `Expanded`
→ il scrolle nativement. Aucune modification de code ; **vérification
device obligatoire** (10+ items dans une liste → scroll fluide).

**Widget** : le layout `list_widget.xml` a 5 lignes fixes
(`widget_item_0..4`) — pas de scroll possible avec des RemoteViews statiques.
Passage à une **ListView RemoteViews + adapter RemoteCollection** (API
framework `android.appwidget`, aucune nouvelle dépendance) :

- `app/android/app/src/main/res/layout/list_widget.xml` :
  - retirer les 5 `widget_item_N`
  - à la place, un `<ListView android:id="@+id/widget_items"
    android:layout_width="match_parent" android:layout_height="0dp"
    android:layout_weight="1" android:divider="@null"
    android:dividerHeight="0dp" android:paddingTop="4dp"/>` entre le
    titre et la barre de boutons (le titre + les boutons restent fixes en
    haut/bas ; la zone items occupe tout le reste et scrolle)
  - nouveau layout `app/android/app/src/main/res/layout/widget_item_row.xml`
    : un seul `TextView` (id `item_row_label`) au look actuel
    (13sp, `#1B1B1B`, `paddingVertical 4dp`, `maxLines 1`,
    `ellipsize end`) — la couleur du texte sera posée par le provider
    (thème), comme aujourd'hui
- **Note API 37 (découverte en implémentation)** : `RemoteAdapter` /
  `BaseRemoteCollection` ont été retirés du SDK — l'implémentation retenue
  est un service `RemoteViewsService` standalone
  (`WidgetItemsRemoteViewsService`, déclaré `BIND_REMOTEVIEWS` +
  `exported=false`) dont l'adapter implémente directement
  `RemoteViewsService.RemoteViewsFactory` (mécanique stable depuis API 11) ;
  le provider pose `setPendingIntentTemplate` (ex-`setOnPendingIntentTemplate`)
  sur la ListView : chaque ligne merge son fill-in
  (ACTION_TOGGLE + EXTRA_ITEM_ID) avec le template → `onReceive` inchangé.
- nouveau fichier
  `app/android/app/src/main/kotlin/com/tapitask/tapitask/WidgetItemAdapter.kt`
  : `class WidgetItemAdapter(context, appWidgetId) :
  RemoteViewsService.RemoteViewsFactory` :
  - `getItemCount()` : 0 si `list_count_lists == 0` ; sinon
    `list_<index>_count` ; si 0 → 1 (la ligne « ✓ Tout est coché »)
  - `getViewAt(position)` : `RemoteViews(pkg, R.layout.widget_item_row)` —
    texte = `list_<index>_item_<position>` (déjà préfixé ☐/✓ + badge par
    Dart), couleur texte via `widgetBackground`-equivalent (même logique
    de thème que le render actuel) ; si count == 0 → texte
    `label_all_done` préfixé ✓, sans PendingIntent
    (`setOnClickFillInIntent(id, null)`)
  - `getItemId(position) = position.toLong()`,
    `onDataSetChanged/onContentsChanged` → `notifyDataSetChanged()`
  - les clés item id (`list_<index>_item_<position>_id`) alimentent le
    `setOnClickFillInIntent(R.id.item_row_label, fillInIntent)` avec
    `action = ACTION_TOGGLE` + `EXTRA_ITEM_ID` (l'adapter ne construit que
    le fillIn ; le PendingIntent de base reste posé par le provider via
    `setRemoteAdapter`… **mécanique exacte** : le provider fait
    `views.setRemoteAdapter(R.id.widget_items, Intent(context,
    ListWidgetProvider::class.java).setAction(RemoteViewsService.INTENT_ACTION_REMOTE_VIEW_SERVICE + ...))` — en pratique, pattern standard :
    le provider crée un Intent vers le provider (action custom
    `ACTION_ADAPTER`) et `setRemoteAdapterColumn(R.id.widget_items,
    "android:text", R.id.item_row_label)` n'est PAS nécessaire pour un
    TextView unique — adapter l'implémentation à ce qui compile et
    fonctionne ; le but est : lignes générées + scroll natif + tap
    préservé via fillInIntent)
- `ListWidgetProvider.kt` :
  - `render()` : au lieu de boucler les 5 `widget_item_N`, poser
    `views.setRemoteAdapter(R.id.widget_items, adapterIntent)` ;
    supprimer `setItem`/`hideItem`/`itemRow` (remplacés par l'adapter) ;
    garder `bindCycle`, le titre, les boutons, `widgetBackground`
  - `onReceive` : `ACTION_TOGGLE` inchangé (le fillInIntent merge
    `EXTRA_ITEM_ID` dans l'intent reçu — le receiver existant ne change
    pas)
  - déclarer le service adapter dans
    `AndroidManifest.xml` :
    `<service android:name=".ListWidgetProvider" android:permission="android.permission.BIND_REMOTEVIEWS"/>`
    (si l'adapter est un nested/standalone `RemoteViewsService` — la
    mécanique choisie doit déclarer le `<service>` avec
    `BIND_REMOTEVIEWS` ; à ajuster selon l'implémentation retenue)
- `widget_service.dart` : `maxItems` supprimé — écriture de tous les items
  (voir S2) ; `list_<li>_count` = nombre d'items écrits

**Tests** : la logique Dart est couverte par les tests S2 (écriture des
clés). L'adapter Kotlin et le scroll : **vérification device** (pas
d'infrastructure de test Kotlin dans le repo — pas de nouvelle dépendance
non plus).

## Hors périmètre

- toggle « décocher » depuis le widget (le widget reste unidirectionnel
  « cocher » ; le décochage se fait dans l'app)
- aperçu du home (déjà limité aux items non-cochés, non signalé)
- widget Windows/flyout (le « volet » Windows est déjà géré par le flyout
  bridge — le paramètre `hide_done` s'y applique si le flyout réutilise le
  même filtrage — **à vérifier** dans flyout_bridge.dart ; sinon hors
  périmètre)
- build/release (après validation)

## Vérification

1. `cd app && flutter test` — vert (S1 ×1, S2 volet ×2, S2 widget ×2, +
   existants)
2. `flutter analyze` — pas de warning nouveau
3. `flutter build apk --debug`
4. device (checklist) :
   - tap icône d'info d'un réglage → dialogue d'aide
   - réglage ON (défaut) : cocher un item dans l'app → il disparaît du
     volet et du widget ; widget : seulement les non-cochés
   - réglage OFF : les cochés barrés dans le volet, ✓ dans le widget
     (non cliquables)
   - liste 10+ items dans le widget → scroll vertical ; tap item en bas
     de liste → coché ; chevrons + boutons toujours en place
   - volet 10+ items → scroll
5. suite complète ×2 (stabilité)
