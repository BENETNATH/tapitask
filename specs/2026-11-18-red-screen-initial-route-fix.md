# Lot N — Fix écran rouge cold-start widget (initial route engine)

Date : 2026-11-18
Statut : spec prête pour implémentation
APK : rebuild requis après ce lot (retest device)
Complète le diagnostic lot M : le `ROOT_ERROR` capturé est
`Could not find a generator for route RouteSettings("/", null)`.

## Diagnostic (établi, reprodit localement)

Chaîne complète, prouvée par `tapitask-red.log` + sources SDK 3.50 +
source engine :

1. Cold-start depuis le widget : l'intent a `data=tapitask://home` (ou
   `tapitask://quickadd/<id>`). Le moteur Android
   (`FlutterActivityAndFragmentDelegate.maybeGetInitialRouteFromIntent`,
   `shouldHandleDeeplinking` par défaut) prend l'URI de l'intent comme
   **initial route** : `setInitialRoute("tapitask://home")` →
   `PlatformDispatcher.defaultRouteName = "tapitask://home"`.
2. Côté framework (`widgets/app.dart`, getter `_initialRouteName`) : si
   `defaultRouteName != "/"`, il **remplace** `initialRoute` → le
   Navigator interne est construit avec `initialRoute = "tapitask://home"`.
3. `NavigatorState.restoreState` (seul point d'entrée des routes
   initiales en 3.50) → `defaultGenerateInitialRoutes(navigator,
   "tapitask://home")` → pas de route nommée ainsi → résultat vide →
   **fallback `_routeNamed("/", allowNull: false)`** → l'app n'a ni
   `home:`, ni route `/`, ni `onGenerateRoute`, ni `onUnknownRoute` →
   **exception** → écran rouge (debug ; null-check en release).
4. Cold-start launcher (pas de data) : `setInitialRoute("/")` →
   `defaultRouteName == "/"` → `initialRoute = "/home"` → la branche
   deep-link pousse `/` en `allowNull: true` (toléré absent) puis `/home`
   (trouvé) → OK. D'où « launcher OK, widget KO ».
5. L'écran rouge est permanent tant que le process vit (le navigator
   n'a jamais de route) ; kill + launcher = OK car rechargement propre.
6. La refonte des dépendances (SDK 3.50 : `restoreState` comme seul
   point d'entrée + sémantique deep-link `initialRoute`) est l'origine du
   régres. L'app est seule concernée car seule à lancer avec un
   data-URI `tapitask://` ET à définir ses routes `/x` sans `home` ni
   `/`.

Repro locale validée (`flutter test`, ce SDK) :
- `MaterialApp(initialRoute: "tapitask://home", routes: sans / ni home)`
  → levée.
- Idem avec `home:` (ou une route `/`) → OK.

## Fix (minimal, Dart uniquement — `app/lib/main.dart`)

Remplacer le cold-start par `home:` (le fallback `/` résout alors
toujours) et ne plus passer d'`initialRoute` :

```dart
final appRoutes = <String, WidgetBuilder>{
  "/home": (_) => HomeScreen(state: appState), // conservé : login fait
                                               // pushReplacementNamed("/home")
  "/list": (_) => const ListScreenRoute(),
  "/login": (_) => LoginScreen(state: appState),
  "/settings": (_) => SettingsScreen(state: appState),
  "/today": (_) => TodayScreen(state: appState),
  "/todo": (_) => TodoAllScreen(state: appState),
};
```

et dans `_ChecklistsAppState.build` :

```dart
return MaterialApp(
  ...
  home: HomeScreen(state: appState),
  routes: appRoutes,
  // (plus de initialRoute:)
);
```

- `home:` → le fallback `_routeNamed("/")` (allowNull: false) du moteur
  résout toujours, quelle que soit l'initial route envoyée (launcher "/",
  widget `tapitask://home` / `tapitask://quickadd/<id>`).
- Les routes nommées restent (navigation `pushNamed` inchangée) ; le
  flux widget (getLaunchUri / MethodChannel) n'est pas touché :
  l'initial route du moteur est ignorée par design, l'URI est traité en
  Dart.
- `home:` et `routes: {"/home": ...}` coexistent sans conflit.

Hors périmètre : Kotlin (pas de `shouldHandleDeeplinking` à changer),
les sondes TAPITASK-FLOW (lot M) restent en place.

## Tests — `app/test/red_screen_regression_test.dart` (nouveau)

Le test ne pump pas `ChecklistsApp` complet (état app/DB non initialisé
en test) : il pump un `MaterialApp` de même forme que l'app (`home:`
placeholder + `appRoutes` réel importé de `main.dart`), ce qui couvre
exactement le mécanisme de résolution. `initialRoute` du MaterialApp du
test = l'initial route que le moteur enverrait (même valeur dans le
Navigator, même code framework) :

1. `cold start launcher (initial route "/")` → home affiché,
   `takeException()` null.
2. `cold start widget (initial route "tapitask://home")` → idem.
3. `cold start quickadd (initial route "tapitask://quickadd/<uuid>")` →
   idem.
4. `configuration sans home (régress) : initial route inconnue lève` →
   MaterialApp(routes seules, initialRoute `tapitask://home`) →
   `takeException()` non null (documente le bug ; échouerait si on
   retirait `home:`).

Supprimer le fichier scratch `app/test/repro_red_screen_test.dart`
(créé pendant le diagnostic, remplacé par ce test de regression).

## Vérification

1. `flutter test` : 31 existants + 4 nouveaux = 35/35.
2. `flutter build apk --debug` vert.
3. Device : kill → widget « + » → l'app s'ouvre (plus d'écran rouge),
   puis ListScreen avec clavier (valide aussi lot L). `adb logcat -s
   TAPITASK-FLOW:*` doit montrer `applyWidgetUri ... → quickAddRequested`
   puis `maybeQuickAdd: push ListScreen <id>` puis
   `ListScreen: requestFocus` et `onResume IME requested`.
