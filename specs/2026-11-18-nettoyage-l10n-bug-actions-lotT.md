# Lot T — bug réglage « Actions visibles », nettoyage l10n, déduplication

Date : 2026-11-18. Repère : `f89e1cc` (lot S).

Origine : audit ponytail (DeepSeek V4 Flash, lecture seule) du 18/11,
chaque constat vérifié empiriquement par le parent (grep + lecture).
« fais TOUT » : les 11 constats validés sont dans le périmètre.

## T1 — Bug : le réglage « Actions visibles » est inopérant

**Constat vérifié** : `app/lib/ui/settings_screen.dart:312-313` écrit
`settings["item_actions"]` ; le getter `visibleActions`
(`app/lib/state/app_state.dart:65`) lit `settings["visible_actions"]`
(défaut `true`, `app_state.dart:41`) ; seul consommateur :
`list_screen.dart:538`. Les tests utilisent `visible_actions`
(`list_screen_due_icon_test.dart:39,63`). Le switch n'a donc aucun effet.

**Fix (1 ligne)** : aligner le switch sur `visible_actions` :
`flag("visible_actions", dflt: true)` + `_toggle("visible_actions", v)`.

**Test (TDD)** : nouveau test (dans `settings_screen_test.dart`) :
pump SettingsScreen avec `state.settings["visible_actions"] = true` →
`tester.tap` sur le switch de la ligne visibleActions → pumpAndSettle →
`expect(state.settings["visible_actions"], false)` — ROUGE avant fix
(le toggle écrit la mauvaise clé, `visible_actions` reste true).

## T2 — « Annuler » en dur ×8 → `S.cancel`

`home_screen.dart:147,168,338,548` et `list_screen.dart:111,178,285,755` :
`const Text("Annuler")` → `Text(S.cancel)` (retirer `const`).
`S.cancel` existe (fr « Annuler », en « Cancel »).

**Test** : le test i18n de section (`app/test/i18n_test.dart`) est le
garde-fou de traduction ; pour ce lot, test widget : dans une langue EN
(`S.setLocale("en")`), ouvrir l'un des dialogues concernés (ex. rename
depuis list_screen) → `expect(find.text("Cancel"), findsOneWidget)` +
`expect(find.text("Annuler"), findsNothing)` — ROUGE avant fix
(le bouton affiche « Annuler » même en EN).

## T3 — Chaînes FR en dur dans l'UI → clés l10n existantes + suppression des clés mortes

**Chaînes en dur à remplacer** (les clés existent déjà dans `s.dart`) :
- `admin_screen.dart:168` « Promouvoir admin » → `S.promoteAdmin`
- `admin_screen.dart:137` « actif » → `S.active`
- `share_screen.dart:166-167` « Viewer » / « Editor » →
  `S.roleViewer` / `S.roleEditor`
- `share_screen.dart:212` « rôle : $role » → construire avec `S.roleOf`
  (vérifier la signature de la clé existante et l'adapter ; si la clé ne
  prend pas le paramètre, utiliser le mot-clé `roleOf` + interpolation)
- `home_screen.dart:530,535` « Partager le dossier… » →
  `S.shareFolderOf(folder)` (helper existant, `s.dart:597`)

**Clés mortes à supprimer** (vérifié : référencées uniquement dans
`s.dart` — maps fr+en + getters) :
`adminRole`, `roleOf` (si non utilisé par le fix ci-dessus),
`invitationsSent`, `todayLabel`, `tomorrowLabel`, `yesterdayOverdue`,
`dailyLabel`, `weeklyLabel`, `monthlyLabel`, `emailVerifiedShort`,
`groupByFolder`, `refreshDelay`, `enableSync`, `pinAlwaysVisible`,
`shareFolder` (si non utilisé par `shareFolderOf`), `roleOwner` (vérifier
l'usage avant suppression — le fix T3 admin peut l'employer).
**Règle** : après remplacement, pour chaque clé du groupe « membres /
admin / échéances / sync / dossiers », `rg` de son identifiant dans
`app/lib` (hors `s.dart`) + `app/test` : zéro référence → supprimer de
`_fr`, `_en` ET le getter. `promoteAdmin` reste (utilisé par T3 +
sondage `i18n_test.dart:30`).

**Test** : l'existant `i18n_test.dart` doit passer (liste de sondage à
ajuster si un getter disparaît) ; ajouter dans ce test :
`S.active`, `S.roleViewer`, `S.roleEditor` dans les sondages EN
(anti-régression FR-residual).

## T4 — Méthodes DB mortes

- `database.dart:254 allUncheckedItems()` : zéro appelant (vérifié) →
  supprimer la méthode.
- `database.dart getItem(id)` : seul appelant `database_test.dart:145`
  (vérifié ; l'entry point Windows hors repo ne consomme pas la DB —
  il consomme `init(lightweight)` niveau app, pas des méthodes DB) →
  supprimer la méthode + le bloc de test associé dans
  `database_test.dart`.

**Test** : pas de nouveau test ; la suite existante doit passer (le test
supprimé était le seul consommateur).

## T5 — Clé `openAction` FR-only

`s.dart:94` (fr) sans équivalent dans `_en` → `t()` retombe sur le FR :
les widgets EN affichent « Ouvrir ». Ajouter
`"openAction": "Open"` dans `_en`.

**Test** : ajout au sondage `i18n_test.dart` : `S.setLocale("en")` →
`expect(S.openAction, "Open")`.

## T6 — Commentaire faux + typage dans search_screen

- `search_screen.dart:7` : « Ctrl+K côté bureau » → le binding in-app est
  `Ctrl+F` (`home_screen.dart:361`) → corriger le commentaire.
- `search_screen.dart:18` : `List<dynamic>? _results` →
  `List<LocalItem>? _results` (import de `database.dart` déjà présent si
  besoin).

**Test** : pas de test dédié (commentaire + typage ; `flutter analyze`
garde le typage honnête).

## T7 — `dflt: true` mort sur 4 flags

`settings_screen.dart:297,301,304,308` : `flag(..., dflt: true)` alors
que `app_state.dart:37-40` initialise `due_dates`/`folders`/`alerts`/
`templates` à `false` (la clé existe toujours → le fallback `dflt` ne
se déclenche jamais). Aligner sur `dflt: false` (documente la réalité ;
aucun changement de comportement).

**Test** : pas de test dédié (cosmétique, comportement inchangé —
vérifier que les tests existants des réglages passent).

## T8 — Triplé de dialogs home/list → fichier partagé

`home_screen.dart:134-225` (`_renameList`, `_deleteList`, `_pickColor`)
et `list_screen.dart:98-192` : les 3 dialogues sont recopiés à l'identique
(seule divergence : `_parseColor` home:347 vs `Color(int.parse(...))`
inline list:146).

**Fix** : nouveau fichier `app/lib/ui/list_dialogs.dart` exposant 3
helpers (rename / delete / pickColor) avec le même contrat (retour
`Future<String?>` / `Future<bool>` / `Future<Color?>` à confirmer en lisant
les call sites) ; les deux écrans consomment le helper ; le parsing couleur
est unifié (celui de home, le plus robuste).

**Test** : les tests existants couvrant ces flux (list_screen_overflow,
home) doivent passer ; ajouter 1 test : le helper rename produit le
dialogue attendu (titre + retour de la valeur tapée) — TDD rouge si le
test vise le helper avant extraction.

## T9 — Bloc `select(localLists)..where(id)..getSingle()` ×3 → `AppDb.getList(id)`

`list_screen.dart:786 _list()`, `today_screen.dart:110 _listOf(id)`,
`todo_all_screen.dart:115 _listOf(id)` : même bloc try/catch → null ×3.

**Fix** : ajouter `Future<LocalList?> getList(String id)` dans
`AppDb` (le pattern try/getSingle/catch→null) ; les 3 call sites
consomment `state.db.getList(_listId)`.

**Test** : pas de nouveau test (extraction comportement-identique ;
suite existante + analyze).

## T10 — 3 implémentations de format d'échéance → 1 helper

`list_screen.dart:767 _dueLabel`, `todo_all_screen.dart:103 _fmtDue`,
`app_state.dart:296 dueSuffix` : 3 variantes « aujourd'hui / demain /
jj/mm [/ hh:mm] ».

**Fix** : 1 fonction unique, ex.
`String dueLabel(DateTime d, {required bool withTime})` dans
`app/lib/ui/due_format.dart` (utilise `S.*` : todayLabel/tomorrowLabel
supprimés au T3 ? — NON : si T3 les supprime comme morts, les réutiliser
ici ; ordre : implémenter le helper d'abord, puis T3 ne supprime que les
clés réellement sans consommateur). Les 3 call sites délèguent au helper ;
`dueSuffix` garde son gate `compact_due` + sa branche « en retard »
(`S.overdueSuffix`).

**Test (TDD)** : `due_format_test.dart` — `dueLabel(aujourd'hui, withTime: false)
= S.todayLabel`, demain → S.tomorrowLabel, autre → « jj/mm », avec
`withTime: true` → suffixe ` hh:mm` ; ROUGE avant création du helper.

## Hors périmètre

- `init({lightweight})` : entry point Windows hors repo — pas touché.
- `material_ui` (paquet externe) : non audité, pas touché.
- Refacto de `flyout_bridge.dart` / `native.dart` / `sync_service.dart` :
  non touché (frontières de confiance).

## Vérification

1. `cd app && flutter test` — vert (nouveaux : T1, T2, T5, T8, T10 +
   ajustements i18n/database)
2. `flutter analyze` — pas de warning/info nouveau
3. `flutter build apk --debug`
4. device (checklist, après APK release) :
   - réglage « Actions visibles » OFF → les icônes d'actions disparaissent
     du volet (le bug T1)
   - EN : dialogues « Cancel » (T2), widget « Open » (T5)
   - share/admin : textes traduits (T3)
5. suite complète ×2 (stabilité)
