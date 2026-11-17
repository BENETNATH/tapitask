# Spec I — Front-end web fonctionnel (build web vert + persistance locale)

Date : 2026-11-17 — lot I.

## Contexte

`flutter build web --release` échoue : `dart:ffi` n'est pas disponible sur web, et
plusieurs imports non web-safe parsèment l'arbre :

| Fichier | Problème |
|---|---|
| `lib/data/database.dart` | `dart:io`, `drift/native.dart` (NativeDatabase → sqlite3 → FFI), `path_provider` |
| `lib/platform/tray_controller.dart` | `dart:io`, `tray_manager`, `window_manager` (FFI, pas de support web) |
| `lib/state/app_state.dart` | `dart:io` (Platform), `home_widget` (pas de support web) |
| `lib/platform/widget_service.dart` | `home_widget` (pas de support web) |
| `lib/platform/alert_service.dart` | `dart:io` (Platform) |
| `lib/ui/list_screen.dart` | `dart:io show Platform` |
| `lib/platform/flyout_bridge.dart` | `dart:io` — mais n'est importé QUE par tray_controller.dart (restera hors du build web, à ne pas toucher) |

Drift 2.35.4 fournit le support web officiel via `package:drift/wasm.dart`
(`WasmDatabase.open(...)`) : persistance auto (FileSystem Access API / IndexedDB /
in-memory selon le navigateur). Les assets requis sont DÉJÀ posés dans `web/`
(`sqlite3.wasm`, `drift_worker.js` — release drift-2.35.4, à ne pas re-télécharger).

## Contrats

### I1 — Connexion drift en import conditionnel

Nouveau dossier `lib/data/connection/` :

- `unsupported.dart` : stub — `DatabaseConnection openConnection() => throw UnimplementedError();`
- `native.dart` : `DatabaseConnection openConnection()` — déplace TEL QUEL la logique
  actuelle de `_openConnection()` dans `database.dart` (LazyDatabase +
  `NativeDatabase.createInBackground` + `getApplicationDocumentsDirectory` + les 3
  PRAGMAs WAL/busy_timeout/foreign_keys et son commentaire sur la double connexion
  fenêtre principale / flyout).
- `web.dart` : `DatabaseConnection openConnection()` :
  ```dart
  import 'package:drift/drift.dart';
  import 'package:drift/wasm.dart';
  import 'package:flutter/foundation.dart';

  DatabaseConnection openConnection() {
    return DatabaseConnection.delayed(Future(() async {
      final result = await WasmDatabase.open(
        databaseName: 'tapitask',
        sqlite3Uri: Uri.parse('sqlite3.wasm'),
        driftWorkerUri: Uri.parse('drift_worker.js'),
      );
      if (result.missingFeatures.isNotEmpty) {
        debugPrint('WasmDatabase: ${result.chosenImplementation} '
            '(missing: ${result.missingFeatures})');
      }
      return result.resolvedExecutor;
    }));
  }
  ```
- `connection.dart` :
  ```dart
  export 'unsupported.dart'
      if (dart.library.ffi) 'native.dart'
      if (dart.library.js_interop) 'web.dart';
  ```

`database.dart` : supprime les imports `dart:io`, `drift/native.dart`,
`path/path.dart`, `path_provider` ; importe `connection/connection.dart` ;
`AppDb() : super(openConnection());` ; supprime `_openConnection()`.
`AppDb.forTesting(super.e)` reste.

### I2 — TrayController no-op sur web

Nouveau `lib/platform/tray_controller_web.dart` : classe `TrayController` avec la
même surface publique que la version native (constructeur `(this.state)`,
`init()`, `isInitialized`, `showMainWindow()`, `isMainWindowVisible()`,
`restoreMainWindow()`, `quit()`) — corps no-op (pas de FFI, pas de tray, pas de
flyout ; sur web l'app vit dans l'onglet du navigateur).

`main.dart` : une seule ligne change —
`import "platform/tray_controller_web.dart" if (dart.library.io) "platform/tray_controller.dart";`
(le reste de main.dart est inchangé ; `TrayController?` + les 2 closures restent).

`flyout_bridge.dart` : **inchangé** (importé uniquement par tray_controller.dart).

### I3 — WidgetService : version web no-op + API launch

`lib/platform/widget_service.dart` (native, inchangé hormis) : ajouter
- `static Future<Uri?> initiallyLaunched() async => HomeWidget.initiallyLaunchedFromHomeWidget();`
- `static Stream<Uri> get clicks => HomeWidget.widgetClicked;`

Nouveau `lib/platform/widget_service_web.dart` : même classe `WidgetService`, même
surface (`maxLists`, `maxItems`, `update`, `pendingToggles`, `clearToggles`) — corps
no-op / valeurs vides — plus `initiallyLaunched()` → `null` et `clicks` →
`const Stream.empty()`.

`lib/state/app_state.dart` :
- supprime `import "dart:io";` et `import "package:home_widget/home_widget.dart";`
  (ajoute `package:flutter/foundation.dart` si absent) ;
- import conditionnel :
  `import "../platform/widget_service_web.dart" if (dart.library.io) "../platform/widget_service.dart";`
- les 2 usages `Platform.isAndroid` → `defaultTargetPlatform == TargetPlatform.android` ;
- le bloc de launch widget (`if (Platform.isAndroid) {...} else {...}`) est entouré de
  `if (!kIsWeb) { ... }` (sur web : pas de widget, rien à rejouer) ;
- les appels `HomeWidget.initiallyLaunchedFromHomeWidget()` /
  `HomeWidget.widgetClicked` → `WidgetService.initiallyLaunched()` /
  `WidgetService.clicks`.

### I4 — Garde-fous web restants

- `lib/platform/alert_service.dart` : supprime `dart:io` ; la garde d'init devient
  `if (_initialized || kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;`
- `lib/ui/list_screen.dart` : supprime `dart:io show Platform` ;
  `autofocus: Platform.isWindows` → `autofocus: defaultTargetPlatform == TargetPlatform.windows`.

### I5 — README (note de déploiement courte, section Webapp)

Après le bloc de build, 2-3 lignes max :
- servir `sqlite3.wasm` avec `Content-Type: application/wasm` (nginx :
  `types { application/wasm wasm; }`) ;
- l'origine web doit être ajoutée à `CORS_ORIGINS` du serveur ;
- headers COOP/COEP optionnels (`Cross-Origin-Opener-Policy: same-origin`,
  `Cross-Origin-Embedder-Policy: require-corp`) pour la persistance performante
  (FileSystem Access API) — sans eux drift bascule sur IndexedDB (fonctionnel, plus lent).

## Hors périmètre

- Pas de nouvelle dépendance pubspec (drift/foundation sont déjà présents ;
  `package:web` n'est importé que par drift lui-même).
- Pas de toucher à `flyout_bridge.dart`, `tray_controller.dart` (native), au serveur,
  à `web/index.html`, aux assets déjà posés.
- Pas de commit (l'assistant committe après vérification indépendante).
- Les autres specs du dossier specs/ sont déjà implémentées et commitées :
  elles sont HORS PÉRIMÈTRE.

## Preuve (gates, TOUS obligatoires)

1. `cd app && flutter build web --release` → **vert** (preuve principale ; itérer sur
   les erreurs du compilateur web s'il en reste d'autres)
2. `flutter test` → suite complète verte (31 tests, zéro régression)
3. `flutter analyze` → 0 issue
4. `flutter build apk --debug` → vert (aucune régression native — les imports
   conditionnels doivent résoudre la version native en VM/Android)

## Tests TDD

Le cœur du lot est de la compilation conditionnelle (preuve = build web + apk +
suite verte). Pas de test factice : si un morceau touché est testable en VM
(ex. le comportement du stub web n'est PAS testable en VM — ne pas forcer un test),
ajouter un test uniquement s'il vérifie un vrai comportement régressif
(ex. `alert_service` ne s'initialise pas sans plateforme supportée, si déjà couvert
par la suite existante : rien à faire).
