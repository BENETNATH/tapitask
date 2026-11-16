# Android deep link — durcissement (audit record: exported_activity_widget_action_deep_link)

## Contexte

Les widgets (2x2 liste, 1x1 quick-add) lancent l'app via
`HomeWidgetLaunchIntent.getActivity(...)` (package `home_widget`, pub.dev) qui
pose l'action **publique** `es.antonborri.home_widget.action.LAUNCH` + la URI
en data. Le plugin ne vérifie que l'égalité de l'action, jamais l'expéditeur :
n'importe quelle app peut forger l'intent.

Surface côté app :

1. `_applyWidgetUri` (app_state.dart:113) se contente de
   `uri.toString().contains("quickadd")` et copie le paramètre `list` tel quel
   → `_maybeQuickAdd` (home_screen.dart:61) pousse `ListScreen(listId: target)`
   sans vérifier l'existence ni la membership.
2. `ACTION_TOGGLE` (ListWidgetProvider.onReceive:243) : broadcast explicite vers
   un receiver `exported="true"` — n'importe quelle app peut y envoyer un
   `item_id` qui sera marqué « fait » dans les prefs partagées.

Note : la vérification d'expéditeur n'est **pas possible** pour un lancement
d'activité sur Android (pas d'API publique de caller package) — la correction
est donc : action privée + validation stricte de la URI + existence/membership.

## Périmètre

- Android uniquement (le chemin Windows/iOS du plugin reste intact, hors impact).
- Pas de nouvelle dépendance. Pas de refactor. Pas de changement de manifest
  (launcher `exported` obligatoire ; receivers `exported` requis pour
  APPWIDGET_UPDATE qui est un broadcast protégé).
- Le package `home_widget` reste (saveWidgetData + autres plateformes).

## Fichiers

| Fichier | Changement |
|---|---|
| `android/app/src/main/kotlin/com/tapitask/tapitask/TapitaskActions.kt` | **Nouveau** (~6 lignes) : `object TapitaskActions { const val ACTION_LAUNCH = "com.tapitask.tapitask.action.LAUNCH" }` |
| `.../MainActivity.kt` | MéthodChannel `com.tapitask/tapitask/widget` : méthode `getLaunchUri` (retourne le URI en attente, puis le vide) + push `widgetLaunch(uriString)` depuis `onNewIntent` |
| `.../ListWidgetProvider.kt` | `bindOpen` : PendingIntent direct vers MainActivity (action privée, data=URI, NEW_TASK\|SINGLE_TOP) au lieu de `HomeWidgetLaunchIntent.getActivity` ; `onReceive(ACTION_TOGGLE)` : validation UUID de `item_id` avant `checkItem` |
| `.../QuickAddWidgetProvider.kt` | Idem pour le bouton 1x1 |
| `lib/state/widget_intent.dart` | **Nouveau** : fonction pure testable (ci-dessous) |
| `lib/state/app_state.dart` | `_applyWidgetUri` : validation stricte + membership + session ; branche Android → nouveau MethodChannel (reprend les deux entrées cold/hot), autres plateformes → chemin plugin existant inchangé |
| `lib/ui/home_screen.dart` | `_maybeQuickAdd` : garde double — vérifier `target ∈ visibleLists()` avant de pousser, sinon fallback par défaut |
| `test/widget_intent_test.dart` | **Nouveau** : matrice de tests |

## Spécifications

### 1. PendingIntents natifs (providers)

Remplacer :

```kotlin
HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse(...))
```

par :

```kotlin
val intent = Intent(context, MainActivity::class.java).apply {
    action = TapitaskActions.ACTION_LAUNCH
    data = Uri.parse("tapitask://quickadd?list=" + (listId ?: ""))
    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
}
PendingIntent.getActivity(context, <code>, intent,
    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
```

Codes distincts par bouton (open/add/quickadd) pour éviter les collisions
`FLAG_UPDATE_CURRENT`. Supprimer l'import `HomeWidgetLaunchIntent` des deux
providers (garder `HomeWidgetPlugin.getData` qui sert au rendu).

### 2. MainActivity.kt

```kotlin
class MainActivity : FlutterActivity() {
    private val channelName = "com.tapitask/tapitask/widget"
    private var pendingLaunchUri: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingLaunchUri = launchUriFrom(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val uri = launchUriFrom(intent) ?: return
        pendingLaunchUri = null  // consommé direct par le push
        MethodChannel(flutterEngine!!.dartExecutor, channelName)
            .invokeMethod("widgetLaunch", uri)
        setIntent(null)
    }

    private fun launchUriFrom(intent: Intent?): String? =
        if (intent?.action == TapitaskActions.ACTION_LAUNCH)
            intent.dataString else null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "getLaunchUri") {
                    val uri = pendingLaunchUri
                    pendingLaunchUri = null
                    result.success(uri)
                } else result.notImplemented()
            }
    }
}
```

(Détails d'implémentation laissés à opencode : `flutterEngine` peut être
non-resolved en `onNewIntent` pré-ready → replier sur `pendingLaunchUri` si le
channel n'est pas prêt, consommé ensuite par `getLaunchUri`.)

### 3. `lib/state/widget_intent.dart` (fonction pure)

```dart
/// Valide une URI de lancement venue d'un widget.
/// Renvoie :
///  - l'id de liste (si `?list=<uuid>` est valide et accessible),
///  - "" pour « ouvrir le quick-add par défaut » (pas de param list),
///  - null si la URI doit être ignorée (inconnue, invalide, non accessible).
String? validateQuickAddUri(Uri? uri, Set<String> accessibleListIds)
```

Règles (toutes testables sans DB) :
- `uri == null` → null
- `uri.scheme != "tapitask"` → null
- `uri.path != "quickadd"` → null (couvre `tapitask://home` et tout autre)
- pas de paramètre `list` → `""`
- `list` vide → null
- `list` doit matcher `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`
  (insensible à la casse) **ET** appartenir à `accessibleListIds` (casse
  stricte, idem DB) → renvoyer l'id ; sinon null
- paramètres superflus (`&evil=1`) : ignorés, pas d'erreur

### 4. `app_state.dart`

`_applyWidgetUri` devient `Future<void>` :

- URI non-tapitask → ignore (pas de state change, pas de notify).
- `api.accessToken == null` (pas de session) → ignore.
- `path == "quickadd"` :
  - `ids = (await db.visibleLists()).map((l) => l.id).toSet()`
    (la DB locale ne contient que les listes dont l'utilisateur est
    membre/propriétaire — proxy de membership suffisant, cohérent avec
    `addQuickItems`).
  - `list = validateQuickAddUri(uri, ids)` ; null → ignore ; `""` →
    `quickAddRequested = true`, `quickAddListId = null` ; sinon →
    `quickAddRequested = true`, `quickAddListId = list`.

Branche plateforme dans `init()` :

```dart
if (Platform.isAndroid) {
  _widgetLaunchSub = _widgetChannel.receiveBroadcastStream()
      .listen((data) => _applyWidgetUri(data is String ? Uri.parse(data) : null));
  final cold = await _widgetChannel.invokeMethod<String>("getLaunchUri");
  await _applyWidgetUri(cold == null ? null : Uri.parse(cold));
} else {
  // chemin existant inchangé (HomeWidget.initiallyLaunchedFromHomeWidget + widgetClicked)
}
```

`_widgetChannel = MethodChannel("com.tapitask/tapitask/widget")`.
`dispose()` : annuler les deux subscriptions selon la plateforme.

### 5. `_maybeQuickAdd` (home_screen.dart) — garde double

Avant de pousser `ListScreen(listId: target)` : vérifier que `target` est dans
`db.visibleLists()` ; sinon ignorer la demande (pas de fallback surprise :
la validation amont rend ce cas théorique, mais 3 lignes valent la défense).

### 6. Broadcast `ACTION_TOGGLE` (ListWidgetProvider.onReceive)

Valider `item_id` contre le même pattern UUID (insensible à la casse) avant
`checkItem` ; invalide → ignoré silencieusement. (Le Dart side applique
`setDone` avec try/catch déjà ; la validation natif évite de polluer les prefs
avec des id factices.)

## Tests (TDD — d'abord les tests, puis l'implé)

`app/test/widget_intent_test.dart` (pas de dépendance DB/platforme) :

1. `null` → null
2. `tapitask://home` → null
3. `https://evil/quickadd?list=<uuid-valide>` → null (mauvais scheme)
4. `tapitask://home?list=<uuid-valide>` → null (mauvais path)
5. `tapitask://quickadd` (sans list) → `""`
6. `tapitask://quickadd?list=` (vide) → null
7. UUID valide **dans** le set → id renvoyé
8. UUID valide **hors** set → null
9. UUID majuscule hors set (le set contient la minuscule) → null
10. formats invalides : `abc`, `12345678-1234-1234-1234-12345678901`,
    `not-a-uuid`, 35 chars → null
11. UUID valide + param superflu `&evil=1` → id renvoyé
12. `tapitask://quickadd?list=<uuid>` avec set vide → null

Contrôle de compilation : `flutter build apk --debug` (Kotlin + manifest).

## Hors périmètre (délibéré)

- Vérification signature/expéditeur : impossible sur un launch d'activité
  Android (documenté ci-dessus) ; l'action privée + la validation stricte
  atteignent l'objectif.
- Manifest : inchangé (justification documentée).
- Windows flyout / iOS : pas d'impact (plugin conservé pour ces plateformes).
- `_applyWidgetToggles` (ids cochés) : le Dart applique déjà avec try/catch ;
  la validation UUID natif couvre le cas.

## Vérification sur device (par l'utilisateur, après APK)

A. Widget 2x2 → bouton ＋ : quick-add ouvert sur la bonne liste.
B. `adb shell am start -a com.tapitask.tapitask.action.LAUNCH
   -n com.tapitask.tapitask/.MainActivity
   -d "tapitask://quickadd?list=00000000-0000-0000-0000-000000000000"`
   → l'app s'ouvre normalement, **pas** de quick-add.
C. `adb shell am start -a es.antonborri.home_widget.action.LAUNCH
   -n com.tapitask.tapitask/.MainActivity
   -d "tapitask://quickadd?list=<uuid-inexistant>"`
   → rien ne se passe (action publique non écoutée + UUID inconnu rejeté).
D. Tap sur un item du widget → coché (le toggle continue de fonctionner).
E. `adb shell am broadcast
   -n com.tapitask.tapitask/.ListWidgetProvider
   -a com.tapitask.tapitask.action.TOGGLE_ITEM --es item_id "garbage"`
   → aucun crash, rien appliqué.
