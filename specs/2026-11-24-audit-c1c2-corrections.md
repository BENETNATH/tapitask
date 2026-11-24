# Lot C1+C2 — corrections de l'audit (2026-11-24)

Périmètre : tous les points de l'audit « Bloquants de production » (C1.1–C1.7) et
« Bugs importants / risques d'exploitation » (C2.1–C2.12). Méthode : TDD (test
d'abord quand c'est testable), surface minimale, pas de refactor, pas de feature.

Arbitrages user (2026-11-24) :
- **A1** label vide : le client ne crée pas l'item (skip) ; le serveur rejette un
  label vide sur création (400 → event rejeté → outbox purgé).
- **A2** `checkForUpdates()` au boot : si une update est dispo, afficher le dialog
  d'update au boot.
- **A3** web http:// : tokens en mémoire uniquement (pas de persistance) + bannière
  http:// existante. Pas de blocage de l'app.
- **A4** migration v1 : des bases réellement migrées existent → corriger le SQL de
  MIGRATIONS **et** ajouter un ALTER one-shot TIMESTAMP→TIMESTAMPTZ.

## C1.1 — Sync : 500 bloquants de l'outbox

### C1.1a — Label vide (A1)
- `app/lib/state/app_state.dart` (`_addParsedLine` et toute voie d'ajout qui parse
  une ligne) : après extraction des mots-clés (due, #folder, récurrence), si le
  libellé restant est vide après trim → **ne pas créer l'item** (skip), ni item
  local ni event outbox. Le reste de la saisie (due/folder) est ignoré avec elle.
- `server/app/routers/sync.py` (`_apply_item_upsert`) : sur un item **nouveau**
  (pas encore en base), si `event.label` est `None` ou ne contient que des
  espaces → `HTTPException(400)` (→ event rejeté). Sur un item **existant**, un
  label `None`/vide **garde** l'ancien label (colonne NOT NULL, jamais vidée).

### C1.1b — SyncEvent sans validation
- `server/app/schemas.py` : `SyncEvent` doit appliquer les mêmes validations que
  `ItemIn`/`ChecklistIn` : interdiction `\x00` (réutiliser `_no_null_bytes`) et
  longueurs (label ≤ longueur max des labels existants, notes, color ≤ 16,
  folder ≤ 100, recurrence ∈ {none,daily,weekly,monthly}) sur `label`, `notes`,
  `color`, `folder`, `recurrence`.
- `server/app/routers/sync.py` (`sync()`) : aujourd'hui seul `HTTPException` est
  basculé dans `rejected`. Tout `DataError`/`IntegrityError` (asyncpg) remonte en
  500 et l'appareil reste bloqué en boucle. Fix : envelopper le traitement
  **par event** (savepoint `begin_nested`) ; sur `DataError`/`IntegrityError` →
  rollback du savepoint + `rejected.append(event.id)` (un event malformé ou en
  conflit unique ne réussira jamais → rejet, pas de retry). Les erreurs
  infrastructure restent non attrapées (500 + retry de lot) comme aujourd'hui.
- Tests : event label 300 chars → 200 avec l'id dans `rejected` ; event avec
  `\x00` → rejeté ; event label vide sur item nouveau → rejeté ; lot mixte valide
  + invalide → le valide est appliqué, l'invalide rejeté, 1 seul commit de batch.

### C1.1d — `_spawn_next` concurrent (IntegrityError au commit de batch)
- Deux `/sync` concurrents qui cochent la même tâche récurrente passent tous les
  deux le check `recurrence_source_id` → deux insertions → IntegrityError sur le
  commit final de batch → 500. Fix : dans `_spawn_next`
  (`server/app/routers/lists.py`) avec `commit=False`, l'insertion de
  l'occurrence passe par un savepoint (`begin_nested`) : sur `IntegrityError`
  (contrainte unique `recurrence_source_id`) → rollback savepoint, re-check,
  retourner `None` (l'occurrence existe déjà ou vient d'être créée). L'upsert
  courant reste appliqué normalement.
- Test : deux sessions concurrentes complètent le même item récurrent → exactement
  1 occurrence, pas d'erreur.

### C1.1e — `POST /auth/verify-email` : collision d'email
- `server/app/routers/auth.py` (~L245) : avant `user.email = user.pending_email`,
  vérifier que l'email n'est pas déjà pris par **un autre** utilisateur — sur
  `User.email` **et** `User.pending_email`. Si pris → `HTTPException(409)` avec
  detail ; `user.pending_email = None` (état périmé nettoyé, l'utilisateur
  relance change_email).
- Test : compte B prend l'email que compte A attendait en pending → verify-email
  de A → 409, pending_email(A) vidé.

## C1.2 — Impossible d'effacer due_date / parent_id / assignee_id / color / folder
Sémantique : dans un upsert sync, le client envoie l'état complet de l'item ;
`null` = « retirer » (le client l'envoie déjà, cf. audit).
- `server/app/routers/sync.py` (`_apply_item_upsert`) :
  - `parent_id`, `assignee_id`, `due_date`, `notes` : `None` → **mettre à null**
    (notes : `None` → `""` si la colonne est NOT NULL, à vérifier sur le model).
  - `recurrence` : `None` → `None`/`"none"` selon le model (vérifier).
  - `label` : jamais vidé (voir C1.1a). `done`/`position` : comportement actuel
    conservé.
  - Remplacer le pattern `event.X or item.X` par une assignment explicite.
- `_apply_list_create` / chemin rename du même fichier : `color`/`folder` `None`
  → vider l'existant (actuellement `if event.color is not None` = jamais vidé).
- `server/app/routers/lists.py` (`patch_item` L226, et tout endpoint PATCH du
  fichier avec le même pattern `if data.X is not None` pour un champ nullable) :
  `None` = vider. Balayer tous les PATCH de `lists.py` pour le même pattern.
- Tests : upsert avec `due_date=null` après mise → vidée ; `parent_id=null` →
  vidée ; `assignee_id=null` → vidée ; PATCH item `due_date: null` → 200 + vidée ;
  PATCH list `color: null` / `folder: null` → vidés.

## C1.3 — Webhooks HTTPS cassés + appelant bloqué
- `server/app/events.py` (`_fire`) : l'URL est réécrite en IP littérale + header
  `Host`, sans SNI → `CERTIFICATE_VERIFY_FAILED` en prod. Fix : passer
  `extensions={"sni_hostname": hostname_origine}` au `client.post` (httpx).
  Vérifier la version httpx pinnée supporte les request extensions (sinon :
  custom transport minimal — documenter dans le code).
- `server/app/routers/lists.py` L239 (`patch_item`) et L461 (`purge_done_items`) :
  `await fire_webhooks(...)` bloque l'appelant jusqu'à WEBHOOK_TIMEOUT. Fix :
  fire-and-forget `asyncio.create_task(fire_webhooks(...))` avec conservation d'une
  référence (set de tâches en cours au module pour éviter le GC). Le log d'échec
  existe déjà.
- Tests : (1) test d'intégration TLS local : serveur TLS avec certificat auto-signé
  (SAN = hostname de test), hook pointant sur ce hostname avec IP pinnée → delivery
  OK avec sni_hostname ; (2) hook lent (mock qui dort au-delà du timeout) → la
  réponse de `patch_item` revient rapidement (< ~1 s) ; le task est bien créé.

## C1.4 — docker-compose : variables d'env manquantes
- `docker-compose.yml` (service `api`) : ajouter le pass-through des variables
  lues par `server/app/config.py` mais aujourd'hui absentes de l'environment :
  `TRUSTED_PROXIES`, `WEBHOOK_ALLOWED_HOSTS`, `WS_PING_INTERVAL`,
  `WEBHOOKS_MAX_PER_LIST`, `PRINCIPAL_RATE_LIMIT_PER_MINUTE`,
  `RATE_LIMIT_PER_MINUTE` (formats `${VAR:-default}` avec le défaut du code).
  Vérifier le nom exact de chaque variable dans `config.py` avant d'écrire.
- Test : pytest qui parse le YAML et asserte la présence des 6 clés dans
  `api.environment`.

## C1.5 — Auto-update Windows (bat) + UX update
- `app/lib/data/windows_updater.dart` (`buildUpdateBat`) : `del "%~f0"` en milieu
  de script casse les lignes suivantes (« Le fichier de commandes est introuvable »).
  Ordre cible (le `del` du bat courant strictement en dernière ligne) :
  ```
  xcopy /E /Y /I "%tmpDir%\*" "%appDir%"
  del "%appDir%\run_update.bat"
  start "" "%appDir%\tapitask.exe"
  del "%~f0"
  ```
  (l'empty folder `update-tmp` subsiste : documenter en commentaire ; un rmdir
  après `del %~f0` reproduirait le bug.)
- Test unitaire : le bat généré contient `start` avant `del "%~f0"` et
  `del "%~f0"` est la dernière ligne non-vide.
- `app/lib/ui/settings_screen.dart` (`_showUpdates`) : état « en cours » (disable
  la row + spinner), empêcher les clics multiples pendant le check et le
  téléchargement (UpdateDialog : bouton de téléchargement disabled pendant le
  téléchargement).
- `app/lib/main.dart` (A2) : au boot, si `checkForUpdates()` trouve une update,
  afficher le dialog d'update. Comme le check tourne avant `runApp`, stocker le
  résultat (ex. dans `appState`) et présenter le dialog post-frameCallback après
  `runApp` (plateformes desktop uniquement, comme le reste du flux update).

## C1.6 — Démarrage bloqué hors-ligne + réglages perdus
- `app/lib/data/api_client.dart` : aucun `.timeout(...)` sur les appels `http.*`.
  Ajouter un timeout global (const 15 s) sur toutes les méthodes
  (get/post/patch/delete + refresh) — centraliser via un helper si plus lisible.
- `app/lib/main.dart` + `app/lib/state/app_state.dart` : `await appState.init()`
  avant `runApp` attend le fullSync + reloadProfile → gel 60–120 s si le serveur
  drop le traffic. Fix minimal : `init()` ne bloque que sur la partie **locale**
  (ouverture db, réglages) ; la partie réseau (fullSync, reloadProfile,
  realtime) tourne en tâche de fond non fatale (erreurs loguées, jamais de
  crash), avec le timeout de C1.6-http. `runApp` est appelé dès que l'état local
  est prêt.
- Réglages perdus hors-ligne : `_loadCachedSettings()` n'est appelé que dans la
  branche `lightweight: true`. L'appeler **toujours** au démarrage (avant
  `reloadProfile`), pour que theme/lang/folders/hide_done_app/due_keywords
  survivent à un démarrage hors-ligne.
- Tests flutter : (1) init offline (mock api qui échoue) → `runApp` atteint
  rapidement, pas de blocage ; (2) réglages en cache (lang/theme) appliqués
  après init offline sans serveur ; (3) le timeout http est effectivement passé
  (assert sur le paramètre ou comportement timeout mocké).

## C1.7 — Flux compte : 202 register, verify-email, token vide
- `app/lib/data/api_client.dart` :
  - `_auth`/`register` : si la réponse (2xx) ne contient pas `access_token`
    (cas 202 « email à vérifier ») → lever une exception typée (ex.
    `EmailVerificationRequired`), pas un faux succès avec `accessToken = null`.
  - `persist()` : si `accessToken`/`refreshTokenValue` est `null` → **retirer**
    la clé (`_secure.delete`) au lieu d'écrire `""`. `_loadToken` : traiter
    `""` comme `null` (rétro-compat avec les "" déjà persistés).
- `app/lib/ui/login_screen.dart` :
  - `_submit` : catcher `EmailVerificationRequired` → rester sur l'écran,
    message « Un email de vérification a été envoyé » + pointer vers le bouton
    « Vérifier mon email » ; pas de navigation, pas de `fullSync`.
  - `_verifyEmail` : appeler `_applyServerUrl()` **avant** le POST (comme
    `_submit`), et catcher aussi les exceptions non-Apex (ArgumentError,
    http.ClientException) → message d'erreur, pas de crash.
  - `SettingsScreen` : l'état « connecté » conditionné sur un token **non vide**
  (vérifier la condition affichée).
- Tests flutter : register mocké 202 → pas de navigation, message affiché, aucun
  token persisté ; verify-email avec baseUrl non appliqué → pas de crash ;
  `persist(null)` → clé absente.

## C2.1 — flutter_secure_storage web/Android au boot
- `app/lib/data/api_client.dart` (`load`) : entourer les accès `_secure.read()`
  (et les writes dans `persist`) d'un try/catch `PlatformException`/generic.
  Sur échec (web http:// hors secure context, restauration Android sans clé
  Keystore) : tokens **en mémoire uniquement**, flag
  `secureStorageUnavailable = true` (la bannière http:// de C1.x existe déjà ;
  l'UI peut s'appuyer sur ce flag si besoin) ; l'app démarre normalement (A3).
- `app/android/app/src/main/AndroidManifest.xml` : ajouter
  `android:allowBackup="false"` sur `<application>`.
- Tests : mock `_secure` qui lève → `load()` complète sans crash, tokens null ;
  test qui assert `allowBackup="false"` dans le manifest (lecture du fichier).

## C2.2 — Bannière http:// sous la barre de statut Android
- `app/lib/main.dart` (`appShell`) : la bannière est rendue dans
  `MaterialApp.builder` au-dessus du Navigator, sans `Material`/`SafeArea` →
  passe sous la status bar. L'encapsuler dans `Material` + `SafeArea(top: true)`.
- Test widget : la bannière est rendue dans un SafeArea (structure).

## C2.3 — Crash ListScreen sur couleur invalide
- `app/lib/ui/list_screen.dart` L135 : `Color(int.parse(...))` → utiliser
  `parseColor()` (int.tryParse) comme `home_screen.dart`, avec fallback (null →
  pas de couleur appliquée / valeur par défaut du contexte).
- Test widget : list.color invalide (ex. `#zz`) → pas d'exception, rendu normal.

## C2.4 — start_hidden inopérant sous Windows
- `app/windows/runner/flutter_window.cpp` (~L102) : `SetNextFrameCallback`
  appelle `this->Show()` inconditionnellement après `runApp`, réaffichant la
  fenêtre même si `TrayController.init()` l'avait laissée cachée. Garder le
  `Show()` conditionnel sur le flag start-hidden (inspecter comment le flag
  passe — TrayController/paramètre de ligne de commande — et réutiliser cette
  source de vérité dans le runner).

## C2.5 — Flyout Win32 (`app/windows/runner/flyout_window.cpp`)
- `DrawListItem` (LVS_OWNERDRAWFIXED) : `FillRect` du fond **inconditionnellement**
  (aujourd'hui seulement si `selected`) — sinon traînées à la désélection.
- `drc.left` : garantir qu'il ne chevauche pas la zone de la case à cocher,
  même fenêtre étroite (drc.left = fin de la case + padding, borné à la largeur).
- `RebuildChips` : ne pas détruire/recréer tous les contrôles à chaque pixel de
  WM_SIZE — n'agir que si la largeur a réellement changé (comparer avec la
  dernière largeur gérée).

## C2.6 — Widget Android : snapshot
- `app/android/app/src/main/kotlin/com/tapitask/tapitask/WidgetItemAdapter.kt` :
  `getCount()`/`getViewAt(position)` relisent `SharedPreferences` à chaque bind →
  `IndexOutOfBoundsException` si la liste change pendant le bind du launcher.
  Lire les données **une fois** dans `onDataSetChanged()` (snapshot), l'utiliser
  dans `getCount()`/`getViewAt()` (guard `position < snapshot.size`).

## C2.7 — Refresh concurrent + session expirée
- `app/lib/data/api_client.dart` : single-flight sur le refresh — si un 401
  arrive pendant un refresh en cours, attendre le **même** Future
  (`Future<bool>? _refreshInFlight`) au lieu de relancer `/auth/refresh` avec le
  même (déjà roté) token.
- Si le refresh échoue définitivement (401) : `accessToken = null`,
  `refreshTokenValue = null`, persister le retrait, notifier (l'app bascule en
  état déconnecté ; vérifier que le WebSocket ne boucle pas en 4401 — il doit
  s'arrêter proprement).
- Tests : deux 401 simultanés → exactement 1 appel `/auth/refresh` (mock
  compté) ; refresh → 401 → tokens nuls + état déconnecté.

## C2.8 — Changement de compte : purge locale
- Se connecter avec un autre compte depuis `LoginScreen` ne purge ni
  `last_sync` ni SQLite (`LocalLists`/`LocalItems`) → mélangement des données +
  pull incrémental qui rate l'historique. Fix : au login réussi, si le compte
  diffère du dernier (comparer l'id/user de l'user, ex. via le profil), vider
  les tables locales et réinitialiser `last_sync` avant le `fullSync`.
- Test : deux comptes mockés, données locales du compte A → login B → tables
  vides avant le pull, last_sync nul.

## C2.9 — `_pushOutbox` sans `since`
- `app/lib/data/sync_service.dart` (chemin push) : le POST /sync sans `since`
  force le serveur à calculer/renvoyer toute la base, immédiatement jetée avant
  le `_pull`. Envoyer `since = last_sync` dans la requête push quand disponible
  (sinon `null` = full, comme aujourd'hui).
- Test : mock HTTP assertant la présence du paramètre `since` quand last_sync est
  défini.

## C2.10 — Migration v1 : due_date TIMESTAMP → TIMESTAMPTZ (A4)
- `server/app/main.py` (`MIGRATIONS` L129) : `("items", "due_date", "TIMESTAMP",
  "TIMESTAMP")` → `TIMESTAMPTZ`.
- Ajouter un **one-shot** pour les bases réellement migrées depuis v1 : vérifier
  le type courant de `items.due_date` (information_schema) ; s'il est
  `timestamp without time zone` →
  `ALTER TABLE items ALTER COLUMN due_date TYPE TIMESTAMPTZ USING due_date AT TIME ZONE 'UTC'`
  ; sinon no-op. Intégrer au mécanisme de migration existant (inspecter comment
  les colonnes de MIGRATIONS sont appliquées et dans quel registre d'état
  stocker le one-shot).
- Tests : base avec due_date TIMESTAMP + lignes → après migration, type
  timestamptz, valeurs conservées ; base fresh (create_all) → pas d'erreur, no-op.

## C2.11 — MCP : validation + batch
- `server/mcp_server.py` (serveur stdio) : `list_id`/`item_id` interpolés dans
  les URLs sans validation — valider en UUID (erreur JSON-RPC si invalide) ;
  ajouter un `timeout=` (10 s) sur `urlopen`.
- `server/app/mcp_http.py` (tool d'ajout en masse, cf. audit « add_items ») :
  2 commits + 1 notify par ligne → **un seul commit de fin + un seul
  notify_list** par tool call ; ajouter la validation `\x00` + longueurs (mêmes
  règles que C1.1b) → erreur paramètre si invalide.
- Tests : tool avec uuid invalide → erreur ; ajout de N lignes → 1 commit
  (spy) + 1 notify ; ligne avec `\x00` → erreur paramètre.

## C2.12 — Scripts de build locaux
- `scripts/setup_tapitask.sh` et `scripts/setup_tapitask.ps1` :
  - emplacement de `key.properties` incohérent avec ce que lit
    `build.gradle.kts` — aligner sur le chemin lu (vérifier le gradle, c'est la
    source de vérité) ;
  - mauvais chemin APK dans le `.sh` (`flutter-release` au lieu du vrai
    dossier de sortie — vérifier le layout gradle réel) ;
  - ajouter `--dart-define=APP_VERSION=<version>` (déterminée depuis le tag git
    ou un paramètre du script) aux builds, sinon la version est figée « dev ».
- Vérification : `bash -n` sur le .sh, `pwsh -NoProfile -Command "& {parse}"`
  (ou équivalent) sur le .ps1 ; lecture attentive des chemins.

## Hors périmètre
- Aucune refonte du protocole sync (la sémantique null=vider est appliquée
  là où le client envoie déjà l'état complet).
- Pas de changement des valeurs par défaut de rate-limiting (seulement le
  pass-through compose, C1.4).
- Les rapports d'audit (`specs/2026-11-24-audit-security.md`, etc.) restent
  **non commités**.

## Livrables attendus
- Code corrigé + tests (serveur : `server/tests/`, flutter : `app/test/`).
- Suites vertes : `pytest` (server) et `flutter test` + `flutter analyze`.
- Commit conventionnel unique ou quelques commits conventionnels ; la spec est
  commitée avec le lot ; les rapports d'audit ne sont PAS commités.
