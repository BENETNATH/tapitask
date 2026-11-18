# Lot M — Instrumentation du flow widget (debug points clairs)

Date : 2026-11-18
Statut : spec prête pour implémentation
APK : rebuild requis après ce lot (retest device)
But : tracer l'enchaînement exact du cold-start depuis le widget « + » et
identifier l'« écran rouge » rapporté par l'utilisateur — sans fix.

## Contexte (faits établis, log `tapitask-live.log` 09:02:26 → 09:02:32)

- Cold launch quickadd (`tapitask://quickadd/...`, PendingIntent widget) :
  process propre, `Displayed +3s209ms`, `Fully drawn`, **aucune ligne
  E/flutter, aucun crash** — mais l'utilisateur rapporte :
  (a) « écran rouge directement, l'application ne s'est pas ouverte »
  (b) « la liste s'ouvre mais pas le clavier »
- IME masqué par le serveur : `ImeTracker onRequestHide
  HIDE_UNSPECIFIED_WINDOW` (jamais demandé).
- `Choreographer: Skipped 69 frames`, `FlutterRenderer: Width is zero` (2×),
  Impeller OpenGLES sur pilote Adreno 2019/2020.
- Piste utilisateur : le souci est apparu après une refonte globale des
  dépendances (SDK Flutter 3.50.0, home_widget 0.10.0, drift 2.35.4,
  material_ui 1.11.0) — régression, liée uniquement à cette app.

## Travail : POINTER, PAS CORRIGER

Un tag unique `TAPITASK-FLOW` côté Kotlin (`android.util.Log.d("TAPITASK-FLOW",
…)`) et côté Dart (`debugPrint('TAPITASK-FLOW …')`), pour un filtre logcat
unique : `adb logcat -s TAPITASK-FLOW:*`.

### Kotlin — `app/android/app/src/main/kotlin/com/tapitask/tapitask/MainActivity.kt`

À chaque étape, UNE ligne (action, valeurs, timestamp fourni par logcat) :

1. `onCreate` : `onCreate action=<action> data=<dataString> restored=<savedInstanceState != null>`
2. `onNewIntent` : `onNewIntent data=<intent.dataString>`
3. dans `onNewIntent`, autour de `invokeMethod("widgetLaunch", uri)` :
   `widgetLaunch pushed` en cas de succès, `widgetLaunch push failed → pendingLaunchUri` dans le catch
4. dans le handler `getLaunchUri` : `getLaunchUri → <uri ou null>`
5. `onResume` : `onResume wantIme=<wantIme>` (et, si le flag est posé,
   `onResume IME requested` juste après `setSoftInputMode`)
6. `onSaveInstanceState` : `onSaveInstanceState skipped (intent null)` uniquement
   dans le cas sauté (le lot K est déjà en place dans le worktree : on
   instrumente le guard existant, pas un autre)

Ne PAS toucher : la logique (garde lot K, demandes IME lot L,
`intent.data = null`, `configureFlutterEngine`) — on n'ajoute que les logs.

### Dart — points de sonde (un `debugPrint('TAPITASK-FLOW …')` chacun)

1. `lib/main.dart` :
   - `main: start`
   - `main: init() done` (après `await appState.init()`)
   - `main: runApp`
   - `lifecycle: <state>` dans `didChangeAppLifecycleState` (TOUTES les valeurs)
2. `lib/state/app_state.dart` :
   - `init: getLaunchUri → <uri ou null>`
   - `applyWidgetUri: <uri> → <résultat>` où résultat ∈
     `bad-scheme | no-token | bad-path | bad-list | quickAddRequested (post-frame)`
   - `post-frame: widget notifyListeners` dans le callback post-frame
     (l.158-159)
   - `applyWidgetToggles: <n> id(s)`
   - `fullSync: start` et `fullSync: done → onChanged notify` dans
     `lib/data/sync_service.dart` (autour de `onChanged?.call()`, l.270 —
     start en tête de `fullSync`/`_pull` selon la structure existante)
3. `lib/ui/home_screen.dart` :
   - `maybeQuickAdd: enter shown=<_quickAddShown> requested=<quickAddRequested>`
   - `maybeQuickAdd: push ListScreen <id>` juste avant `Navigator.push`
4. `lib/ui/list_screen.dart` :
   - `ListScreen: focusAdd scheduled` dans `initState` (branche `focusAdd`)
   - `ListScreen: requestFocus (mounted=<mounted>)` dans le callback post-frame
5. **Identification de l'écran rouge** (`lib/main.dart`) : override
   `ErrorWidget.builder` au début de `main()` (avant `runApp`) :

   ```dart
   ErrorWidget.builder = (errorWidget) {
     debugPrint('TAPITASK-FLOW ROOT_ERROR: ${errorWidget.error}');
     debugPrint('TAPITASK-FLOW ROOT_STACK: ${errorWidget.stack}');
     return const ColoredBox(
       color: Colors.red,
       child: Align(alignment: Alignment.topCenter, child: Padding(
         padding: EdgeInsets.all(16),
         child: Text('Tapitask error — voir logcat TAPITASK-FLOW',
             style: TextStyle(color: Colors.white, fontSize: 14)),
       )),
     );
   };
   ```

   Si l'écran rouge est un ErrorWidget Flutter, le logcat portera
   `ROOT_ERROR` + `ROOT_STACK` complets ; si c'est un artefact de rendu,
   le flow sera propre dans le log et l'écran sans texte.

### Hors périmètre

- Pas de fix, pas de changement de logique, pas de nouveau dépendance.
- Les providers (`ListWidgetProvider`, `QuickAddWidgetProvider`) gardent leurs
  logs existants (`TapitaskWidget`), on n'y touche pas.
- Les specs de lots précédents (F, K, L) : hors périmètre, déjà commitées ;
  les modifications non commitées de `MainActivity.kt` (lots K+L) sont à
  CONSERVER telles quelles (on ajoute des logs dans ce fichier au-dessus).

## Tests

Dart : comportement inchangé (logs seulement) → `flutter test` doit rester
31/31.
Kotlin : aucun test unitaire (décision lots F/K) — build vert.

## Vérification

1. `cd app && flutter test` — 31/31.
2. `flutter build apk --debug` — vert.
3. Device : kill → widget « + » ; capture : `adb logcat -s TAPITASK-FLOW:*`
   (plus un dump complet `adb logcat -d -v time > /tmp/tapitask-flow.log` et
   une photo de l'écran rouge s'il apparaît — il affichera désormais le
   message d'erreur si c'est un ErrorWidget).
