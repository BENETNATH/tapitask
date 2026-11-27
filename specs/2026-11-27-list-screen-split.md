# Spec 2026-11-27 — `list_screen.dart` : extraire le menu du `build()`

**Statut** : à implémenter. **Périmètre** : `app/lib/ui/list_screen.dart`
UNIQUEMENT. Extraction PURE (même classe `_ListScreenState`, même
`State`, aucun nouveau fichier, aucun changement de widget tree ni de
comportement) — pas un refactor architectural, juste un découpage en
méthodes nommées pour la lisibilité. Référence :
`specs/2026-11-27-audit-findings.md` (item « build() de 534 lignes »).

**Garde-fou explicite** : cet écran a un historique de bugs de
géométrie AppBar déjà corrigés et verrouillés par
`test/list_screen_overflow_test.dart` (lot P). Cette extraction ne doit
RIEN changer à la structure du widget tree (ordre des widgets, types,
props) — SEULEMENT déplacer des blocs de code existants dans des
méthodes nommées, appelées depuis le MÊME endroit du `build()`. Si à
la lecture le découpage s'avère plus risqué que prévu (ex. une
variable capturée par closure se comporte différemment extraite),
ARRÊTE et documente dans le rapport plutôt que de forcer.

## 1. Extraire le switch `onSelected` du `PopupMenuButton` (actuel
`build()`, ~ligne 249-316, ~67 lignes)

Nouvelle méthode privée de `_ListScreenState` :
```dart
Future<void> _onListMenuAction(String action) async {
  final state = widget.state;
  // ... corps EXACT actuellement inline dans onSelected (lignes
  // 250-316), aucune ligne changée, juste déplacé tel quel ...
}
```
`build()` devient :
```dart
PopupMenuButton<String>(
  onSelected: _onListMenuAction,
  itemBuilder: (context) => _buildListMenuItems(),
),
```

## 2. Extraire la liste du `itemBuilder` (actuel `build()`, ~ligne
317-435, ~118 lignes)

Nouvelle méthode privée :
```dart
List<PopupMenuEntry<String>> _buildListMenuItems() {
  return [
    // ... corps EXACT actuellement inline dans itemBuilder (lignes
    // 318-434), aucune ligne changée, juste déplacé tel quel ...
  ];
}
```
Référencée depuis `build()` comme ci-dessus (`itemBuilder: (context) =>
_buildListMenuItems()`).

## Contraintes

- Variables utilisées dans ces blocs (`state`, `_listId`,
  `_hideCompleted`, `widget.state.defaultListId`, `canSendToGoogleTasks`,
  `_lists`, `context` via le paramètre du callback…) restent accessibles
  identiquement — ce sont déjà des champs/paramètres de la même classe
  `_ListScreenState`, aucune capture externe à gérer.
- `context` dans `_onListMenuAction` : le paramètre `context` du
  `PopupMenuButton.onSelected` callback original N'EST PAS un
  paramètre de la fonction `onSelected` (qui ne reçoit que `action`) —
  vérifier dans le code actuel comment `context` est obtenu dans ce
  bloc (probablement `this.context` de l'État, implicite). Garder
  EXACTEMENT le même mécanisme, ne pas ajouter de paramètre `context`
  artificiel si l'original n'en avait pas besoin.
- Aucun autre changement dans `list_screen.dart` — ne pas toucher au
  reste du `build()`, aux autres méthodes, aux imports (sauf ajout
  d'imports strictement nécessaires si un type utilisé dans le bloc
  extrait n'était pas encore importé — improbable puisque le code ne
  bouge pas de fichier).

## Vérification

1. `dart run build_runner build --delete-conflicting-outputs` d'abord.
2. `flutter analyze --no-fatal-infos` → `No issues found!`.
3. `flutter test` (suite complète, PAS seulement les tests de
   `list_screen`) → verte, 0 régression. `test/list_screen_overflow_test.dart`,
   `test/list_screen_due_icon_test.dart`, `test/list_screen_hide_done_test.dart`,
   `test/list_screen_google_tasks_test.dart` sont la preuve directe de
   non-régression pour CET écran — vérifier explicitement leur statut
   dans le rapport final (pas juste le total de la suite).
4. `git status --short` : UNIQUEMENT `list_screen.dart` modifié.
5. Ne rien committer.

## Si le découpage s'avère risqué

Si en cours de route un comportement ne peut PAS être préservé à
l'identique sans changement additionnel (ex. `context` capturé
différemment, closure qui référence une variable locale du `build()`
non accessible depuis une méthode de classe) : NE PAS forcer un
contournement — revenir au code d'origine, documenter précisément le
blocage dans le rapport final, et s'arrêter là pour ce fichier.
