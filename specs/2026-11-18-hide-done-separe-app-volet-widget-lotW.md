# Lot W — « Cacher les items cochés » : réglage app ≠ réglage volet/widget + le widget respecte enfin le réglage

## Bug W0 (diagnostic vérifié, confirmé device par l'user)

Le switch « Cacher les items cochés » (section « Volet & widget ») n'a
aucun effet sur le widget : les items cochés y apparaissent dans tous les
cas. En revanche l'app (ListScreen) applique le réglage immédiatement.

Cause racine (vérifiée en code) :

- `settings_screen.dart` `_toggle()` : `state.settings[key] = value;
  await state.saveSettings();` — met à jour le MAP LIVE (d'où l'UI de
  l'app qui se met à jour au setState) et persiste — mais n'appelle JAMAIS
  `_refreshWidget()`.
- Le widget n'est réécrit que par `AppState._refreshWidget()`
  (`WidgetService.update()` → prefs partagées + `updateWidget`), appelé sur
  les mutations d'items — jamais sur un changement de réglage.
- Conséquence : après un toggle du réglage, les prefs du widget conservent
  les dernières données écrites jusqu'à la prochaine mutation d'item — le
  widget ne reflète donc jamais le réglage s'il n'y a pas de mutation.
- Mêmes trous pour `theme` (fond du widget) et `lang` (labels du widget) :
  `_pickTheme()` / `_pickLanguage()` passent aussi par `saveSettings()`
  sans refresh widget.

Le code d'écriture du widget est correct en soi (`widget_service.dart` :
`hide_done` ON → `uncheckedItemsOf`, OFF → `itemsOf` + préfixe « ✓  ») —
vérifié par `widget_service_hide_done_test.dart` (vert). Le bug est le
manque de rafraîchissement, pas l'écriture.

## Besoin user (deux features séparées)

1. « Cacher les items cochés » **dans l'application** (la liste principale)
   — nouveau réglage distinct, dans la section « Fonctionnalités ».
   L'user veut garder cette feature (elle est intéressante), mais séparée.
2. « Cacher les items cochés » **dans le volet (flyout Windows) et le
   widget** — le réglage existant (section « Volet & widget »), qui doit
   vraiment agir sur le volet + widget uniquement.

## Fixes

### W1 — refresh central des surfaces compactes à chaque changement de réglage
`AppState.saveSettings()` (le SEUL point de passage de tous les
changements de réglage : `_toggle`, `_pickTheme`, `_pickLanguage`) :
après `_cacheSettings()` + `notifyListeners()`, ajouter :

    await _refreshWidget();
    onSettingsChanged?.call();

- `_refreshWidget()` réécrit les prefs du widget (items selon hide_done,
  thème, labels) et déclenche `updateWidget` (provider → render →
  notifyAppWidgetViewDataChanged, lot U) : le widget suit IMMÉDIATEMENT
  tout changement de réglage.
- `onSettingsChanged` : nouveau callback nullable sur AppState (même
  pattern que `isMainWindowVisible`/`restoreMainWindow`), posé par le
  TrayController (Windows) : `state.onSettingsChanged = () => flyout.refresh();`
  (le stub web `tray_controller_web.dart` ne pose rien — no-op).
- Pas de liste de clés à maintenir : n'importe quel réglage (présent ou
  futur) rafraîchit les surfaces compactes. Coût négligeable (quelques
  écritures prefs + 1 broadcast), idempotent.

### W2 — nouveau réglage `hide_done_app` (app)
- `AppState.settings` : défauts explicites — ajouter `"hide_done": true`
  ET `"hide_done_app": true` (comportement inchangé ; le map actuel est
  muet sur hide_done, le défaut venait du `?? true` des lecteurs).
- `list_screen.dart` : le filtre du corps de liste ET la logique
  onReorder (2 occurrences, clé `hide_done`) → `hide_done_app`.
- `settings_screen.dart` : nouvelle ligne switch dans la section
  « Fonctionnalités » : `S.hideDoneApp`, clé `hide_done_app`, dflt true,
  `info: S.hideDoneAppHelp` (icône info tappable, comme les autres).

### W3 — le flyout respecte `hide_done`
`flyout_bridge.dart` `_push()` : aujourd'hui TOUJOURS
`uncheckedItemsOf` (les cochés n'apparaissent jamais, réglage ignoré).
- ON (défaut) : `uncheckedItemsOf` — comportement actuel.
- OFF : `itemsOf` — tous les items ; le flag done de la ligne (`I <id>
  <0|1> <label>`) passe à 1 : le volet natif (Win32) applique déjà
  `ListView_SetCheckState(item.done)` — les cochés apparaissent cochés,
  et l'action native « uncheck » existe déjà dans `_onNative`.
- Extraire la sélection des items dans une méthode testable, SANS garde de
  plateforme : `Future<List<LocalItem>> itemsFor(String listId)` (lit
  `state.settings["hide_done"]`, défaut true) ; `_push()` l'appelle.
- `FlyoutBridge.refresh()` public : `Future<void> refresh() => _push();`
  (no-op hors Windows via la garde isAvailable de `_push`) — appelé par
  le callback W1.

### W4 — l10n
- Nouvelles clés `hideDoneApp` + `hideDoneAppHelp` (FR + EN) :
  - FR : « Cacher les items cochés » /
    « La liste de l'application n'affiche plus les items cochés.
    Indépendant du réglage Volet & widget. »
  - EN : « Hide checked items » /
    « The app list no longer shows checked items. Independent of the
    flyout & widget setting. »
- `hideDone`/`hideDoneHelp` inchangés (ils décrivent déjà « le volet et
  le widget »).

## Pas de changement
- `widget_service.dart` (écriture déjà correcte), provider/adapter Kotlin,
  QuickAddWidget, `home_screen.dart` (l'aperçu du home reste
  non-cochés par design — hors périmètre), le toggle unidirectionnel du
  widget.

## Tests (TDD)

- `list_screen_hide_done_test.dart` : retargeter la clé `hide_done` →
  `hide_done_app` (ON défaut masque, OFF affiche barré) + cas de
  séparation : `hide_done` = OFF + `hide_done_app` = ON (défaut) → l'item
  coché est MASQUÉ de l'app (règlage app fait foi) ; `hide_done` = ON +
  `hide_done_app` = OFF → l'item coché est VISIBLE (le réglage
  volet/widget n'a plus d'effet sur l'app).
- Nouveau `settings_hide_done_widget_test.dart` (rég W0) : mock du canal
  `home_widget` (pattern de `widget_service_hide_done_test.dart`) —
  monter SettingsScreen avec 1 liste épinglée (1 item coché, 1 non),
  toggler `hide_done` OFF puis ON, et vérifier que le mock reçoit les
  écritures `list_*` correspondantes (cochés préfixés « ✓  » / absents)
  + `updateWidget` — avant le fix : aucun appel après le toggle (rouge).
- Nouveau `flyout_items_test.dart` (W3) : `FlyoutBridge.itemsFor()` sur
  DB mémoire — `hide_done` ON (défaut) → uniquement non-cochés ; OFF →
  tous les items (cochés inclus).
- `i18n_test.dart` : parité FR/EN des nouvelles clés (si le test existe
  déjà sur le pattern des clés).
- `widget_service_hide_done_test.dart` : inchangé, doit rester vert.
- Suite complète verte, `flutter build apk --debug` vert.

## Checklist device (APK lot W)
1. Widget : toggler « Cacher les items cochés » (Volet & widget) OFF →
   les items cochés apparaissent IMMÉDIATEMENT dans le widget (préfixe
   ✓) ; ON → ils disparaissent immédiatement. (Le bug W0 user :
   « les items cochés apparaissent dans tous les cas ».)
2. Nouveau switch (Fonctionnalités) : OFF → les items cochés
   apparaissent barrés dans la liste de l'app, le widget n'est pas
   affecté par ce réglage ; ON → ils disparaissent de l'app.
3. Changer le thème dans les réglages → le fond du widget suit
   immédiatement.
4. Windows : le flyout respecte le réglage Volet & widget (OFF → items
   cochés affichés cochés dans le volet, re-cochables/décochables).

## Surface
Dart uniquement : app_state.dart, settings_screen.dart, list_screen.dart,
flyout_bridge.dart, s.dart, tray_controller.dart (+ main.dart si le
câblage du callback y est plus propre — à trancher par le run : le
pattern isMainWindowVisible est posé dans main.dart). Pas de Kotlin, pas
de nouvelle dépendance, pas de feature.
