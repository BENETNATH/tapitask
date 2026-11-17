# Lot F — Crash du launch widget (NPE fatal Android + assertion écran rouge)

Date : 2026-11-17
Statut : spec prête pour implémentation
APK : rebuild requis après ce lot (retest device)

## Symptômes (reproduits device, 2026-11-17)

Flow widget 1x1 « quick-add » :
1. 1er clic widget → l'app ouvre (cold start) → OK (lent, permission notifs).
2. Retour sur le widget.
3. 2e clic widget → écran rouge (assertion Flutter) ; à l'arrière-plan,
   l'app meurt (NPE fatal, logcat).

## Crash 1 — NPE fatal (mort du process) — VERIFIÉ source

Logcat 09:42:35 (`tapitask-crash.log`) :

    java.lang.NullPointerException: Attempt to invoke virtual method
    'boolean android.content.Intent.hasExtra(java.lang.String)' on a null
    object reference
        at io.flutter.embedding.android.FlutterActivity.shouldRestoreAndSaveState(FlutterActivity.java:1499)
        at io.flutter.embedding.android.FlutterActivityAndFragmentDelegate.onSaveInstanceState(:696)
        at io.flutter.embedding.android.FlutterActivity.onSaveInstanceState(:875)
        at android.app.Activity.performSaveInstanceState
        at android.app.ActivityThread.callActivityOnStop

SDK (`engine/src/.../FlutterActivity.java`) :

    @Override
    public boolean shouldRestoreAndSaveState() {
        if (getIntent().hasExtra(EXTRA_ENABLE_STATE_RESTORATION)) {  // NPE ici
          ...

`getIntent()` est null ⇒ quelqu'un a appelé `setIntent(null)`. C'est notre
code : `MainActivity.onNewIntent` se termine par `setIntent(null)`.

Chaîne : 2e clic widget → `onNewIntent` → `setIntent(null)` → l'activity
s'arrête (back/home) → `onSaveInstanceState` → NPE → process mort.

## Crash 2 — écran rouge (assertion framework, debug) — mécanisme vérifié

Screenshot 09:43 : `Failed assertion: line 2175 pos 12:
'_elements.contains(element)': is not true.`

`framework.dart:2175` = `_InactiveElements.remove(Element)`. L'assertion
signifie qu'un élément est désactivé deux fois (déjà hors du set
`_elements`) ⇒ corruption d'arbre par deux opérations concurrentes.

Déclencheur : le 2e clic widget lance DEUX chaînes async concurrentes qui
appellent `notifyListeners()` :
1. `didChangeAppLifecycleState(resumed)` (main.dart:58) →
   `sync.fullSync()` → `_pull()` → `onChanged()` = `notifyListeners`
   (sync_service.dart:270).
2. `MethodChannel.invokeMethod("widgetLaunch")` (MainActivity.onNewIntent)
   → `_onWidgetLaunch` (app_state.dart:131) → `_applyWidgetUri` →
   `notifyListeners()` (app_state.dart:148) →
   `_HomeScreenState._onChanged` → `setState` + `Navigator.push`
   (quick-add, home_screen.dart:48-52/71).

Le `notifyListeners` de la chaîne 2 atterrit au milieu d'une frame lancée
par la chaîne 1 (ou inversement) → double désactivation → assertion.

Le cold start (1er clic) n'a que la chaîne 1 + le flag posé AVANT la
première frame → pas de race. D'où : 1er clic OK, 2e clic crash.

## Fixes

### F1 — MainActivity.kt (crash 1)

    - setIntent(null)
    + intent.data = null

- `getIntent()` reste non-null → plus de NPE dans
  `shouldRestoreAndSaveState`.
- L'URI est consommé à la 1re lecture : recreate (rotation) et restore
  (process kill) re-lisent l'intent avec `data = null` →
  `launchUriFrom` renvoie null → pas de re-traitement.
- `super.onNewIntent(intent)` garde l'intent réel (déjà le cas).

### F2 — app_state.dart `_applyWidgetUri` (crash 2)

Remplacer le `notifyListeners()` synchrone final par une notification
différée post-frame (le push natif ne doit jamais muter l'arbre au milieu
d'une frame) :

    quickAddRequested = true;
    quickAddListId = list.isEmpty ? null : list;
    SchedulerBinding.instance
        .addPostFrameCallback((_) => notifyListeners());

- Chemin cold (init()) : le flag est posé avant la première frame, la
  notification tombe sur le 1er post-frame → comportement inchangé.
- `@visibleForTesting` sur `_applyWidgetUri` (seam test, 1 ligne).
- Import `package:flutter/scheduler.dart`.

## Tests (Dart, TDD — flutter test)

Nouveau `app/test/app_state_widget_launch_test.dart` :

1. **différé post-frame** : liste en base, `accessToken` posé, widget
   pumpé + 1 frame. Appeler `_applyWidgetUri(tapitask://quickadd?list=<id>)`
   (visibleForTesting) → immédiatement après : aucun listener notifié ;
   `quickAddRequested == true`. `pump()` → listener notifié 1 fois,
   `quickAddListId == id`.
2. **URI non quickadd → aucun effet** :
   `_applyWidgetUri(tapitask://home?list=<id>)` → aucun notify avant ni
   après pump, flag restés faux.

Règles : les 24 tests existants doivent rester verts. Aucun autre fichier
modifié. Pas de nouvelle dépendance.

## Vérification

- `flutter analyze` clean.
- `flutter test` → 24 + 2 nouveaux, tous verts.
- Rebuild APK debug (l'APK de test est celui du lot E, obsolète).
- Retest device (user) : 2e clic widget → plus d'écran rouge ;
  backgrounding après un launch widget → plus de crash NPE.

## Hors périmètre

- Finding audit « togglecycle » (ListWidgetProvider exported) : test
  device séparé, pas lié.
- Finding « fmtexc » (Uri.parse cold path) : déjà couvert lot D
  (validation stricte avant parse) ; retest au retest device.
- Erreur WebSocket 13:12 (serveur 100.89.213.10:8472 injoignable du
  téléphone) : comportement offline attendu, retry par le timer.
