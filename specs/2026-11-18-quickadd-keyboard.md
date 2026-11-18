# Lot L — Clavier au launch quickadd (widget « + »)

Date : 2026-11-18
Statut : spec prête pour implémentation
APK : rebuild requis après ce lot (retest device)

## Symptôme (reproduit device, 2026-11-18, build 9c42d8e)

Clic sur le widget 1x1 « + » → l'app ouvre directement sur la liste ciblée
(donc le deep-link `tapitask://quickadd` fonctionne, push ListScreen OK) —
mais le clavier ne s'ouvre pas ; le champ d'ajout n'est pas focalisé
visuellement.

Preuve log (`tapitask-repro.log`) : 08:58:12 `START act=com.tapitask.tapitask.
action.LAUNCH dat=tapitask://quickadd/...` → cold start (PID 10692,
`Late-enabling -Xcheck:jni`), result code=0, transition ouverte, aucun crash,
aucune ligne E/flutter.

## Cause (vérifiée source)

- `AndroidManifest.xml` (line 18) : `android:windowSoftInputMode="adjustResize"`
  → l'ÉTAT de l'IME est indétérminé (unspecified) au lancement de l'activity.
- Côté Dart, le focus est demandé par
  `ListScreen.initState → addPostFrameCallback(_addFocus.requestFocus())`
  (`lib/ui/list_screen.dart:36-40`) — programmatique, sans interaction
  utilisateur.
- Sur Android, un launch d'activity depuis un PendingIntent de widget
  (background start) avec `STATE_UNSPECIFIED` : un `requestFocus()`
  programmatique ne fait pas monter l'IME — c'est le comportement normal du
  système (anti-popup). Le clavier ne monte que si l'activity demande
  explicitement l'IME visible (`SOFT_INPUT_STATE_VISIBLE`) en plus de l'état
  de focus Flutter.
- Conséquence observée : liste ouverte (le push ne dépend pas du clavier),
  clavier fermé (la demande d'IME n'a jamais été faite au niveau fenêtre).

## Fix (Kotlin uniquement, MainActivity.kt)

Les deux formes de URI émises par `QuickAddWidgetProvider.kt:40-41` :
`tapitask://quickadd` (aucune liste) et `tapitask://quickadd?list=<id>`.
Détection : `intent.dataString?.startsWith("tapitask://quickadd") == true`
(couvre les deux ; le reste est validé côté Dart).

```kotlin
class MainActivity : FlutterActivity() {
    private val channelName = "com.tapitask/tapitask/widget"
    private var pendingLaunchUri: String? = null
    private var wantIme = false   // NEW

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingLaunchUri = launchUriFrom(intent)
        // NEW : launch « + » → demander l'IME visible à la fenêtre au resume
        // (un requestFocus programmatique seul ne fait pas monter le clavier
        // sur un launch depuis un widget, windowSoftInputMode=adjustResize).
        wantIme = pendingLaunchUri?.startsWith("tapitask://quickadd") == true
    }

    // NEW
    override fun onResume() {
        super.onResume()
        if (wantIme) {
            wantIme = false
            window.setSoftInputMode(
                WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE or
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val uri = launchUriFrom(intent) ?: return
        pendingLaunchUri = null
        try {
            MethodChannel(flutterEngine!!.dartExecutor, channelName)
                .invokeMethod("widgetLaunch", uri)
        } catch (_: Exception) {
            pendingLaunchUri = uri
        }
        intent.data = null
        // NEW : relance « + » alors que l'app est ouverte → fenêtre déjà
        // visible, on demande l'IME directement.
        if (uri.startsWith("tapitask://quickadd")) {
            window.setSoftInputMode(
                WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE or
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
    }
    // ... (onSaveInstanceState du lot K, configureFlutterEngine,
    //      launchUriFrom : inchangés)
}
```

- Import `android.view.WindowManager` à ajouter.
- `ADJUST_RESIZE` conservé : cohérence avec le manifest (l'UI se redimensionne
  quand le clavier monte).
- Côté Dart : AUCUN changement — le `requestFocus()` post-frame de
  `ListScreen` (lot H) reste le routage du clavier vers le champ d'ajout ;
  les deux mécanismes sont complémentaires (la fenêtre demande l'IME visible,
  le focus Flutter choisit le champ).
- Pas de `setIntent`, pas de toucher aux autres routes (le widget « Ouvrir »
  `tapitask://home/...` ne doit PAS forcer le clavier).

## Tests

Kotlin : pas d'infra unitaire (décision lots F/K) : preuve = manifest +
source + build vert + retest device.
Dart : aucun changement → `flutter test` inchangée (doit rester 31/31).

## Vérification

1. `cd app && flutter test` — 31/31.
2. `flutter build apk --debug` — vert.
3. Retest device (4 cas) :
   a. tuer l'app → widget « + » → la liste s'ouvre ET le clavier est ouvert,
      le curseur dans le champ d'ajout (tape un caractère pour confirmer).
   b. idem sans liste ciblée (widget « + » créé sans liste active) → app
      ouverte, clavier attendu sur le champ d'ajout de la liste par défaut.
   c. app ouverte (chaude) → widget « + » → clavier ouvert sur le champ
      d'ajout.
   d. widget « Ouvrir » (2x2, `tapitask://home/...`) → clavier NON forcé
      (comportement inchangé).
