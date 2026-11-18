# Lot U — widget : les items ne se rafraîchissent pas après changement de données

Date : 2026-11-18. Repère : `a0a3c4f` (lot T).

Retour device (APK release lot T, qui intègre le lot S) : « tout fonctionne
mais les items dans le widget ne sont pas mis à jour ».

## Diagnostic (vérifié dans le code, 18/11)

Le lot S a remplacé les 5 lignes statiques du widget par une `ListView`
RemoteViews alimentée par un adapter (`WidgetItemAdapter`,
`RemoteViewsService`). Les lignes ne sont plus écrites directement dans
les `RemoteViews` — elles sont fournies par la collection au bind.

Mécanique Android : quand un widget contient un AdapterView lié via
`setRemoteAdapter`, un simple `updateAppWidget(id, views)` ne relit PAS
les données de la collection — le launcher conserve le service déjà bindé
et n'appelle plus `onDataSetChanged()`/`getCount()`/`getViewAt()`.
L'appel qui déclenche le re-lire est
`AppWidgetManager.notifyAppWidgetViewDataChanged(appWidgetId, viewId)`
(documentation officielle AppWidget, présente dans l'exemple canonique de
widget ListView).

Conséquence observée : le widget s'affiche au bind (titre, boutons, liste
scrollable, premier état) mais :
- cocher/ajouter/renommer un item dans l'app → `toggleItem`/`addItem` →
  `_refreshWidget()` → provider `onUpdate` → `render()` (setRemoteAdapter
  + updateAppWidget) → les lignes restent en l'état antérieur ;
- cycle ◀/▶ de liste → `triggerUpdate` → même chemin → le titre change
  (RemoteViews statique) mais les items restent ceux de l'ancienne liste.

Avant le lot S, les lignes étaient des `setTextViewText` directs dans
`render()` → `updateAppWidget` suffisait → le rafraîchissement fonctionnait.
C'est la migration vers la collection qui a cassé le refresh, pas l'écriture
des prefs (celle-ci est intacte et testée).

## Fix (1 ligne)

`app/android/app/src/main/kotlin/com/tapitask/tapitask/ListWidgetProvider.kt`
— dans `render()`, après `appWidgetManager.updateAppWidget(appWidgetId, views)`
(l. 225) :

```kotlin
appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_items)
```

L'adapter relit les prefs à chaud dans `rows()` → le re-lire suffit
(aucun cache à invalider, `onDataSetChanged()` est déjà vide par design).
Tous les chemins de mise à jour passent par `render()` (onUpdate direct,
ACTION_CYCLE via triggerUpdate, ACTION_TOGGLE via triggerUpdate,
`HomeWidget.updateWidget` de Dart) → un seul point d'insertion.
`notifyAppWidgetViewDataChanged` : API 1, minSdk 24 — aucun souci de
compatibilité. La branche `total == 0` (aucune liste épinglée) ne pose pas
de setRemoteAdapter → rien à y faire.

## Tests

Pas de test unitaire possible (comportement du launcher, pas
d'infrastructure de test Kotlin, pas de nouvelle dépendance) —
**vérification device obligatoire** :
1. cocher un item dans l'app → il dispara du widget immédiatement
2. ajouter un item → il apparaît dans le widget
3. cycle ◀/▶ → les items changent avec la liste (et non plus le titre seul)
4. réglage « Cacher les items cochés » ON↔OFF → le contenu du widget
   bascule (seuls non-cochés ↔ tous avec ✓)
