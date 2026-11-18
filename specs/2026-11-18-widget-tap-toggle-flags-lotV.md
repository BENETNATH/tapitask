# Lot V — widget : tap sur une ligne n'agit pas (FLAG_IMMUTABLE)

## Bug
Sur device (Android 12+), un tap sur une ligne item du widget ne fait rien :
le toggle n'est pas délivré. Tout le reste fonctionne (affichage, scroll,
rafraîchissement des items, cycle de liste, boutons).

## Cause racine (vérifiée)
`ListWidgetProvider.render()` (l.~223) :

    views.setPendingIntentTemplate(
        R.id.widget_items,
        PendingIntent.getBroadcast(context, 0,
            Intent(context, ListWidgetProvider::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))

Le pattern AdapterView RemoteViews est : template + fill-in intent par ligne
(`setOnClickFillInIntent`, adapter `WidgetItemAdapter.getViewAt` :
ACTION_TOGGLE + EXTRA_ITEM_ID). Au clic, le système merge le fill-in dans le
template (`PendingIntent.sendIntent(context, position, fillIn)`).

Depuis l'API 31 (Android 12), les PendingIntents exigent un flag explicite
IMMUTABLE ou MUTABLE, et un PendingIntent **IMMUTABLE refuse le merge de
données** : le fill-in est écarté, le broadcast ACTION_TOGGLE n'est jamais
délivré. Conséquence observée : tap sans effet, alors que le widget reste
bien synchronisé.

Avant le lot S, les lignes étaient statiques avec `setOnClickPendingIntent`
(direct, sans template/merge) → aucun impact ; d'où la régression apparue
uniquement après le lot S.

## Fix (1 ligne)
Dans `ListWidgetProvider.render()`, sur le template uniquement :

    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
→
    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE

Le fill-in est un simple Intent (pas un PendingIntent) : aucun flag à y
poser. `bindOpen` et `bindCycle` conservent `FLAG_IMMUTABLE` (pas de merge
au clic : correct, et plus strict = mieux).

## Pas de test unitaire
Le merge template+fill-in est du côté launcher/system (AppWidgetHostView) ;
non unit-testable côté app. Validation device (checklist plus bas).

## Checklist device (APK lot V)
1. tap sur une ligne → l'item est coché dans l'app ET dispara du widget
   (hide_done ON) / se barre (hide_done OFF)
2. tap sur le bouton +/◀/▶ inchangé (rien de cassé)
3. cycle de liste puis tap : le toggle cible bien l'item de la liste
   courante
4. tap sur une ligne cochée (hide_done OFF) : rien à cocher → inerte
   (comportement attendu, unidirectionnel)

## Surface
1 fichier, 1 ligne modifiée : ListWidgetProvider.kt. Pas de nouvelle
dépendance, pas de feature, pas de refactor.
