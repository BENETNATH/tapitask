# Lot K — Garde onSaveInstanceState contre NPE FlutterActivity (getIntent null)

Date : 2026-11-18
Statut : spec prête pour implémentation
APK : rebuild requis après ce lot (retest device)

## Preuve (log device `tapitask-crash.log`, fourni 2026-11-18)

Crash buffer, 11-17 13:16:54 (PID 15767) :

    FATAL EXCEPTION: main
    java.lang.NullPointerException: Attempt to invoke virtual method
    'boolean android.content.Intent.hasExtra(java.lang.String)' on a null
    object reference
        at io.flutter.embedding.android.FlutterActivity.shouldRestoreAndSaveState(FlutterActivity.java:1499)
        at io.flutter.embedding.android.FlutterActivityAndFragmentDelegate.onSaveInstanceState(:696)
        at io.flutter.embedding.android.FlutterActivity.onSaveInstanceState(:875)
        at android.app.Activity.performSaveInstanceState(Activity.java:2485)
        at android.app.ActivityThread.callActivityOnStop(...)

Mécanisme confirmé dans le SDK local
(`~/flutter/flutter/engine/src/flutter/shell/platform/android/io/flutter/embedding/android/FlutterActivity.java`) :
`shouldRestoreAndSaveState()` fait `if (getIntent().hasExtra(...))` SANS test de nullité.
Le trigger historique de notre code (`setIntent(null)` en fin de `onNewIntent`) a déjà
été corrigé (lot F, cf54fef → `intent.data = null`), mais `getIntent()` peut rester
null sur des recreations système (return recents après kill process, chemins OEM) :
le NPE au prochain `onSaveInstanceState` (stop activity) est alors fatal et garanti.

## Fix (Kotlin uniquement, 1 override)

Fichier : `app/android/app/src/main/kotlin/com/tapitask/tapitask/MainActivity.kt`

    override fun onSaveInstanceState(outState: Bundle) {
        // getIntent() peut être null sur recreation système (return recents
        // après kill process) : super.onSaveInstanceState →
        // shouldRestoreAndSaveState() → NPE fatal (FlutterActivity.java:1499,
        // sans test de nullité côté engine). Sans intent, l'état à restaurer
        // n'existe pas : sauter le save (recreate = démarrage frais).
        if (getIntent() != null) {
            super.onSaveInstanceState(outState)
        }
    }

- Pas de `setIntent(...)` : on ne réinvente pas l'intent, on saute juste le save.
- Aucun autre changement dans le fichier : `onCreate`, `onNewIntent`
  (`intent.data = null`, lot F) et `configureFlutterEngine` restent tels quels.

## Tests

Kotlin : pas d'infra unitaire (pas de Robolectric à ajouter — décision lot F) :
preuve = source SDK (ligne 1499) + build vert + retest device.
Dart : aucun changement Dart → suite `flutter test` inchangée (doit rester 31/31).

## Vérification

1. `cd app && flutter test` — 31/31.
2. `flutter build apk --debug` — vert (JAVA_HOME 17, ANDROID_HOME exportés).
3. Retest device : tuer l'app (swipe recents), relancer, laisser s'arrêter au
   moins une fois (back/home) sans crash ; + flow widget (2 clics).
