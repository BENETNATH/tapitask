# Spec 2026-11-27 — Dédup today_screen/todo_all_screen (widget partagé)

**Statut** : à implémenter. **Périmètre** : `app/lib/ui/today_screen.dart`
+ `app/lib/ui/todo_all_screen.dart` + un nouveau fichier
`app/lib/ui/items_overview_body.dart`. Rien d'autre.

Les deux écrans ont un corps STRICTEMENT identique (StreamBuilder →
état vide Icon+Text → ListView.builder → Card+TaskTile+FutureBuilder
sous-titre), seuls diffèrent : le stream source, le texte d'état vide,
et le texte du sous-titre. Extraire ce corps dans un widget partagé,
SANS changer le rendu (texte, styles, structure identiques, vérifié
caractère pour caractère ci-dessous).

## Nouveau widget `ItemsOverviewBody`

`app/lib/ui/items_overview_body.dart` :
```dart
import "package:material_ui/material_ui.dart";

import "../data/database.dart";
import "../state/app_state.dart";
import "task_details.dart";

/// Corps partagé de TodayScreen/TodoAllScreen : StreamBuilder → état vide
/// → liste de Card/TaskTile. [subtitleText] construit le SUFFIXE affiché
/// après le titre de la liste (today : juste le suffixe retard ;
/// todo_all : échéance + suffixe retard).
class ItemsOverviewBody extends StatelessWidget {
  final Stream<List<LocalItem>> stream;
  final AppState state;
  final String emptyText;
  final String Function(LocalItem item, bool overdue) subtitleText;
  const ItemsOverviewBody({
    super.key,
    required this.stream,
    required this.state,
    required this.emptyText,
    required this.subtitleText,
  });

  Future<LocalList?> _listOf(String id) => state.db.getList(id);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<LocalItem>>(
      stream: stream,
      initialData: const [],
      builder: (context, snapshot) {
        final items = snapshot.data ?? const [];
        if (items.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.celebration_outlined,
                    size: 64, color: scheme.outline),
                const SizedBox(height: 12),
                Text(emptyText, style: TextStyle(color: scheme.outline)),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            final overdue = item.overdueAt(DateTime.now());
            return Card(
              elevation: 0,
              margin: const EdgeInsets.symmetric(vertical: 3),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                    color: overdue
                        ? scheme.errorContainer
                        : scheme.outlineVariant),
              ),
              child: TaskTile(
                state: state,
                item: item,
                title: Text(item.label),
                subtitle: FutureBuilder<LocalList?>(
                  future: _listOf(item.listId),
                  builder: (context, snap) => Text(
                    "${snap.data?.title ?? ""}${subtitleText(item, overdue)}",
                    style: TextStyle(
                        fontSize: 12,
                        color: overdue ? scheme.error : scheme.outline),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
```

## `today_screen.dart` — `build()` devient

Garde l'import `"package:flutter/services.dart"`, le `CallbackShortcuts`
(Ctrl+Z), le `Scaffold`/`AppBar` EXACTEMENT tels quels — seul le `body:`
change :
```dart
body: ItemsOverviewBody(
  stream: _dueStream,
  state: widget.state,
  emptyText: S.nothingToday,
  subtitleText: (item, overdue) => overdue ? S.t("overdueSuffix") : "",
),
```
Supprime la méthode `_listOf` locale (déplacée dans le widget partagé)
et l'import `due_format.dart` s'il devient inutilisé (vérifier —
`today_screen.dart` ne l'importait pas déjà, ne rien changer côté
imports sauf retrait de ce qui devient inutile).

## `todo_all_screen.dart` — `build()` devient

Garde le `Scaffold`/`AppBar` tels quels — seul le `body:` change :
```dart
body: ItemsOverviewBody(
  stream: _todoStream,
  state: widget.state,
  emptyText: S.allDone,
  subtitleText: (item, overdue) {
    final due = item.localDue;
    return "${due != null ? "  •  ${dueLabel(due, withTime: false)}" : ""}"
        "${overdue ? S.t("overdueSuffix") : ""}";
  },
),
```
Garde l'import `due_format.dart` (toujours utilisé via `dueLabel`).
Supprime la méthode `_listOf` locale (déplacée dans le widget partagé).

## Vérification

1. `dart run build_runner build --delete-conflicting-outputs` d'abord.
2. `flutter analyze --no-fatal-infos` → `No issues found!`.
3. `flutter test` (suite complète) → verte. Si `today_screen`/
   `todo_all_screen` n'ont PAS de test dédié existant, en ajouter un
   minimal par écran (device-faithful, cf. convention du projet) qui
   vérifie : état vide affiché quand le stream est vide (texte exact
   `S.nothingToday`/`S.allDone`), et qu'un item avec échéance en retard
   affiche le suffixe de retard dans le sous-titre — pour PROUVER que
   l'extraction n'a rien cassé (texte identique à avant), pas juste
   que `flutter analyze` est content.
4. `git status --short` : uniquement les 2 écrans + le nouveau fichier
   `items_overview_body.dart` (+ tests si ajoutés) + cette spec. Rien
   sous `list_screen.dart` ni `app_state.dart` (hors périmètre).
5. Ne rien committer.
