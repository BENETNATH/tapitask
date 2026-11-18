# Lot R — Retrait des sondes TAPITASK-FLOW + échafaudage écran-rouge

Date : 2026-11-18. Repère : `6bf617b` (lot Q).

Demande user : « retirer toutes les balises de débug » — l'instrumentation
posée pendant le debugging device (lots K–Q) ne doit pas partir en
production.

## Périmètre (inventaire exhaustif au commit de référence)

**À RETIRER** :
- Toutes les sondes `TAPITASK-FLOW` (29 occurrences) :
  - Dart (22 `debugPrint`/multi-lignes) : `app/lib/main.dart` (7),
    `app/lib/state/app_state.dart` (7), `app/lib/ui/home_screen.dart` (3),
    `app/lib/ui/list_screen.dart` (2), `app/lib/data/sync_service.dart` (2)
  - Kotlin (8 `Log.d`) :
    `app/android/app/src/main/kotlin/com/tapitask/tapitask/MainActivity.kt`
- Le bloc échafaudage lot M dans `app/lib/main.dart` :
  `ErrorWidget.builder = (details) { debugPrint ROOT_ERROR/ROOT_STACK +
  boîte rouge }` (le red-screen est corrigé par le lot N — l'échafaudage
  est inutile)

**À CONSERVER (code fonctionnel qui entoure les sondes)** :
- `MainActivity.kt` : la garde `onSaveInstanceState` (`if (getIntent() !=
  null)`), la logique `wantIme` / `SOFT_INPUT_STATE_VISIBLE` dans
  `onResume`, la logique `onNewIntent` (push `widgetLaunch`, IME direct,
  `intent.data = null`), `pendingLaunchUri` + handler `getLaunchUri`
- Les `debugPrint` NON TAPITASK-FLOW du code produit :
  `app/lib/platform/flyout_bridge.dart` (log d'échec flyout),
  `app/lib/data/connection/web.dart` (impl. Wasm choisie)
- Les logs `TapitaskWidget` de `ListWidgetProvider.kt` (`Log.e` d'échec +
  `Log.d` du render) — code produit présent dès l'initial commit

## Fix

- Supprimer chaque déclaration sonde entière (statement complet, y compris
  les continuations multi-lignes) ; laisser le code autour intact
  (aucun comportement ne change)
- Retirer les imports devenus inutiles :
  - `MainActivity.kt` : `import android.util.Log` si plus aucun `Log.`
    après retrait
  - les fichiers Dart : vérifier au linter (`unused_import`) ;
    `foundation.dart` reste si d'autres symboles l'utilisent
- Ne toucher à rien d'autre (pas de refactor, pas de feature)

## Tests

Aucun nouveau test (retrait d'instrumentation, aucun comportement modifié).
Vérifications obligatoires :
1. `rg -c "TAPITASK-FLOW" app/` → **zéro résultat**
2. `rg -n "ErrorWidget.builder" app/lib` → **zéro résultat**
3. `flutter analyze` → aucun warning `unused_import` /
   `directives_ordering` nouveau
4. `flutter test` → suite complète verte (compte = lot Q, +43)
5. `flutter build apk --debug` → build OK
