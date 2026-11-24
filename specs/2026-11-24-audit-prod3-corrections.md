# Lot audit production 3 — tapitask (2026-11-24)

Suite du lot C1+C2 (`3974dc2`) et du micro-lot A2+C1.7 (`543f9f7`).
Audit prescriptif : chaque item a été vérifié au code le 2026-11-24
(références de lignes données à titre d'indication — s'aligner sur la
sémantique si le code a bougé). TDD, surface minimale, pas de refactors hors
spec. Baselines à rester vertes : **pytest serveur = 190**, **flutter test =
106**, **flutter analyze --no-pub = no issues**, **flutter build apk --debug**
(env : `PATH=$HOME/flutter/flutter/bin:…`, `ANDROID_HOME=$HOME/android-sdk`,
`JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64`).

## Micro-décisions (à documenter en commentaire si dévié)
- **MD-1 (1.5)** : le serveur est dual-backend (SQLite `aiosqlite` + Postgres
  `asyncpg`, cf. db.py L16-23, DDL double dans main.py). Contrat : les
  datetimes entrants aware sont convertis en **UTC** avant stockage/
  comparaison ; les valeurs stockées restent des datetimes UTC (naïfs-UTC en
  texte SQLite, aware-UTC acceptés en Postgres TIMESTAMPTZ). Pas de migration.
- **MD-2 (1.6 totp)** : **token court signé** plutôt que colonne
  `pending_totp_secret` — aucun client réel n'appelle /totp/setup|enable
  (vérifié : aucun appel dans app/lib), aucune migration, aucun état obsolète
  en base. Réutiliser l'infra token existante (pattern
  `new_email_token`/`decode_token` de auth.py). `/totp/enable` avec
  `disable=True` exige un **code TOTP valide** (pas le mdp — l'utilisateur
  a son authenticateur à la main pour désactiver). `test_totp_flow`
  (server/tests/test_api.py L616) à mettre à jour (il envoie
  `code="000000", disable=True` — générer un code valide avec pyotp).
- **MD-3 (1.6 verify-email)** : `_verify_email_limiter = RateLimiter(5)` par
  key (5/min) ; expiration `email_token` = **24 h** via une nouvelle colonne
  `email_token_created_at` (migration listée dans main.py, double DDL
  sqlite/postgres).
- **MD-4 (2.1)** : branche « ligne cochée » recyclée →
  `setOnClickFillInIntent(R.id.item_row_label, Intent())` vide sans action
  (et non null), conformément à l'audit.
- **MD-5 (3 i18n)** : remplacer les libellés durs **uniquement** quand la clé
  S.* existe déjà (ex. quotidien/hebdomadaire/mensuel → S.daily/S.weekly/
  S.monthly, list_screen.dart L710-712) ; ne PAS créer de nouvelles clés
  pour le reste ; les noms de dossiers par défaut (home_screen L33) sont des
  valeurs de données, pas de l'UI — laisser tel quel (commentaire si ambigu).
- **MD-6 (3 deps)** : parsing `TRUSTED_PROXIES` corrigé dans config.py
  L40 : `[h.strip() for h in … .split(",") if h.strip()]` (fixe le `[""]`
  et les espaces). Fallback Redis→mémoire : sur exception Redis, log
  (logging) + bascule mémoire pour l'appel courant.
- **MD-7 (1.4)** : `reloadProfile({required: false})` — quand `required` et
  l'appel échoue (non configuré, 401, réseau), **rethrow** ; `LoginScreen.
  _submit()` passe `required: true`, passe au `Future<bool>`, et
  `_acceptInvite()` s'arrête si `false`.

## 1.1 Crash boot : showDialog hors MaterialApp (app/lib/main.dart)
`_ChecklistsAppState.build()` retourne `MaterialApp` (L194) ;
`_maybeShowBootUpdate()` (L133) fait `showDialog(context: context, …)` avec
le context du state (au-dessus du MaterialApp, sans Navigator) → crash
garanti post-frame dès qu'une release supérieure existe.
- Ajouter `final _navigatorKey = GlobalKey<NavigatorState>();` sur
  `_ChecklistsAppState` et `MaterialApp(navigatorKey: _navigatorKey, …)`.
- Dans `_maybeShowBootUpdate()` : `final navContext = _navigatorKey
  .currentContext;` — si null, re-planifier (addPostFrameCallback) ou
  sortir proprement ; `showDialog(context: navContext, …)`.
- `onUpdate` du dialog boot : try/catch + état d'attente (voir 1.2 — le
  dialog gère son propre état, le boot doit juste ne pas crasher si l'update
  échoue).
- **Test widget** : `ChecklistsApp` avec `pendingBootUpdate != null` → le
  dialog s'ouvre sans exception (sur le code actuel le test doit échouer).

## 1.2 UpdateDialog figé pendant le téléchargement
`UpdateDialog` (app/lib/ui/update_dialog.dart) est StatelessWidget : le
`updating:` est capturé à la construction de la route ; le
`setState(() => _updating = true)` de `SettingsScreen._showUpdates()`
(settings_screen.dart L196-236) ne reconstruit pas le dialog → pas de
spinner, bouton non désactivé, et l'erreur de téléchargement/installation
n'apparaît pas.
- Transformer `UpdateDialog` en **StatefulWidget** qui gère lui-même
  `_updating` et `_error` autour de `Future<void> Function()? onUpdate`,
  et affiche l'erreur dans le dialog en cas d'échec.
- `SettingsScreen._showUpdates()` : simplifier en conséquence (le dialog est
  la source unique de l'état d'update ; ne pas laisser deux états qui se
  contredisent). Le flux boot de main.dart bénéficie du même fix.
- **Test widget** : tap sur « Mettre à jour » → spinner visible + bouton
  désactivé pendant l'attente ; erreur → affichée dans le dialog.

## 1.3 Freeze 15 s des réglages hors-ligne (app/lib/state/app_state.dart)
`saveSettings()` (L~20) fait `await api.patch("/auth/me", …)` (timeout 15 s)
AVANT `_cacheSettings()` / `notifyListeners()` / `_refreshWidget()` /
`onSettingsChanged?.call()` → hors-ligne, tout est gelé 15 s et le réglage
peut être perdu.
- Ordre : `S.setLocale(...)`, `await _cacheSettings()`, `notifyListeners()`,
  `await _refreshWidget()`, `onSettingsChanged?.call()`, PUIS
  `unawaited(api.patch("/auth/me", {"settings": settings}).catchError((_) {}))`
  (importer `unawaited` de dart:async ; l'échec réseau est silencieux — le
  réglage est déjà local).
- **Test** : api en échec/timeout → listeners notifiés et réglage en cache
  AVANT la fin de l'attente réseau.

## 1.4 Compte, session, WebSocket (app_state.dart, login_screen.dart, sync_service.dart, api_client.dart)
- **(a)** `ApiClient.onSessionExpired` (api_client.dart L33, appelé L230)
  n'est jamais branché. Dans `AppState.init()` :
  `api.onSessionExpired = _handleSessionExpired;` — nouvelle méthode qui
  réinitialise `email`, `pendingEmail`, `isAdmin`, `totp`, ferme le
  WebSocket (`sync.stopRealtime()` — à ajouter si absent : cancel
  `_reconnectTimer`, close `_ws`, cancel `_wsSub`) et `notifyListeners()`.
- **(b)** `reloadProfile()` avale l'erreur (`catch (_) {}`) → après login
  sur un nouveau compte B, `email` peut rester A → `onAccountSwitch()` ne
  purge pas → fuite des données A dans le sync B.
  `reloadProfile({bool required = false})` : si `required` et échec
  (non configuré / accès token null / GET /auth/me échoue) → rethrow.
  `LoginScreen._submit()` l'appelle en `required: true` ; sur échec :
  afficher l'erreur, **pas** de purge ni de fullSync.
- **(c)** `_submit()` → `Future<bool>` (true = connecté).
  `_acceptInvite()` (login_screen.dart L~128) :
  `final ok = await _submit(silent: true); if (!ok) return;` avant le
  `POST /lists/invites/…/accept` (sinon POST sans session).
- **(d)** `SyncService.listenRealtime()` (sync_service.dart L~286) écrase
  `_ws`/`_wsSub` sans fermer l'ancien ni annuler `_reconnectTimer` →
  sockets orphelines, reconnexions doublées. Avant d'ouvrir :
  `_reconnectTimer?.cancel()`, `_wsSub?.cancel()`, `_ws?.sink.close()`.
  Garder les erreurs `jsonDecode` gérées dans le listener (try/catch).
- **Tests** : session expirée → UI reconnectée (email null, WS fermé) ;
  reloadProfile required échoué au login → pas de purge, erreur affichée ;
  _acceptInvite s'arrête si _submit échoue ; listenRealtime 2× → 1 seul WS
  actif (aucune sub orpheline).

## 1.5 Horodatages sync & curseur delta (server/app/routers/sync.py, app/lib/data/sync_service.dart)
- Serveur : `_naive(dt)` (sync.py L21-22) fait `replace(tzinfo=None)` sans
  conversion UTC → un client envoyant +02:00 voit son timestamp décalé de
  2 h. Remplacer par une normalisation **UTC** :
  ```python
  def _utc(dt: datetime) -> datetime:
      return dt.astimezone(timezone.utc) if dt.tzinfo is not None else dt
  ```
  (naïf = supposé UTC, comme les valeurs stockées issues de utcnow()).
  Remplacer tous les usages de `_naive` par `_utc` (comparaisons et
  normalisation avant écriture). Contrat MD-1 (double backend).
- Client : `_pull()` (sync_service.dart L267-273) sauvegarde
  `last_sync = newest` — avec la tolérance d'horloge serveur
  (SYNC_CLOCK_TOLERANCE +5 s), un item poussé à `server_now + 4 s` fait
  sauter définitivement les items créés entre `server_now` et
  `server_now + 4 s`. **Ancrer sur `server_time`** : si
  `serverTime != null` → `_saveLastSync(serverTime - 5 s)` (le pull est
  idempotent via LWW) ; `newest` seulement en fallback si `server_time`
  absent de la réponse.
- **Tests** : serveur — item poussé avec datetime +02:00 stocké/comparé
  comme UTC (pas de décalage) ; client — la valeur sauvée dans
  `last_sync` = server_time - 5 s même quand newest > server_time.

## 1.6 Auth & 2FA (server/app/routers/auth.py)
- **/login — ordre + oracle** (auth.py L~160) : aujourd'hui is_active (403)
  → is_email_verified (428) → TOTP (401) → verify_password. Contournement
  du lockout par TOTP (les échecs TOTP ne passent pas par
  `_register_failed_login`) + énumération d'état de compte. Contrat :
  si le user existe, **verify_password d'abord** ; échec →
  `_register_failed_login(key)` + 401 « Invalid credentials » uniforme.
  Si le password passe : is_active → 403, is_email_verified → 428, TOTP
  (échec TOTP → `_register_failed_login(key)` + 401). User inconnu →
  `_register_failed_login(key)` + 401 uniforme.
- **/totp/setup** (L328-339) : ne **plus** persister `user.totp_secret` au
  setup (aujourd'hui L338-339) → le compte serait verrouillé au prochain
  login si l'écran est fermé avant /totp/enable. Retourner un **token court
  signé** contenant le secret (expiration ~10 min, MD-2) ; `TotpSetupOut`
  gagne le champ token (le secret reste dans le champ existant pour le QR
  code, si la UI l'expose).
- **/totp/enable** (L~350) : activer → exiger le token de setup valide +
  code TOTP valide contre le secret du token, PERSISTER le secret
  uniquement alors. `disable=True` → exiger un **code TOTP valide** contre
  le secret courant (MD-2), sinon 400.
- **/verify-email** (L239) : RateLimiter (MD-3) ; **expiration de
  email_token** (colonne `email_token_created_at`, 24 h, MD-3) : jeton
  expiré → 410/400 « lien expiré » (choisir 400, message clair) +
  migration double DDL dans main.py.
- **Test** : `test_totp_flow` à mettre à jour (MD-2) ; nouveaux tests :
  login mdp faux avec user TOTP → 401 uniforme + compté ; mdp bon + TOTP
  mauvais → 401 + compté ; setup n'écrit rien en base ; enable sans token →
  400 ; disable sans code valide → 400 ; verify-email > 5/min → 429 ;
  email_token > 24 h → rejeté.

## 2.1 Widget Android : désépingle + recyclage
(`app/android/app/src/main/kotlin/…/widget/ListWidgetProvider.kt`,
`WidgetItemAdapter.kt`)
- `onUpdateSafe()` total == 0 (L56-69) : masquer `R.id.widget_items`
  (`View.GONE`) et appeler
  `appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_items)`
  (sinon les anciens items restent affichés) ; remettre `View.VISIBLE`
  dans `render()`.
- `getItemAdapter().getViewAt()` (WidgetItemAdapter L88-121) :
  - branche `snapshotRows.isEmpty()` : toujours
    `setViewVisibility(R.id.item_row_due, View.GONE)` (ligne vide recyclée
    peut montrer l'ancien badge d'échéance) ;
  - branche ligne cochée (`id.isEmpty()`, L~115) :
    `setOnClickFillInIntent(R.id.item_row_label, Intent())` (MD-4) — sans
    ça la ligne recyclée hérite du clic de l'item précédent.
- Pas de toolchain Android en local : review de code + `flutter build apk
  --debug` (compile le module natif si le plugin est intégré au build) ;
  sinon noter « à valider sur device ».

## 2.2 Race dirty outbox & renameList hors-ligne
- `_pushOutbox()` (sync_service.dart L~200) : `db.clearDirty(acceptedIds)` /
  `clearListDirty(list.id)` sans vérifier qu'aucune mutation locale n'a eu
  lieu PENDANT le POST /sync → une coche/renommage fait pendant l'appel
  réseau est marqué propre et jamais poussé. Contrat : capturer
  l'`updatedAt` de chaque item/list poussé ; après le POST, ne cleaner que
  si `updatedAt local courant <= updatedAt capturé` (query par id avec la
  condition, ou par generation si plus simple — documenter).
- `AppState.renameList()` : `await _refreshWidget();` est DANS le
  `if (api.isConfigured && api.accessToken != null)` → hors-ligne, un
  renommage de liste épinglée ne met pas le widget à jour. Le sortir du if
  (toujours rafraîchir le widget en local).
- **Tests** : mutation pendant un POST /sync en cours (fake api lente) →
  l'item est repoussé ; renameList hors-ligne → widget rafraîchi.

## 2.3 parent_id & réponses lists.py
- `lists.py:add_item` valide le parent (L155-162 : existe, même liste, pas
  sous-tâche) mais `patch_item` (L244-245 : `item.parent_id = data.parent_id`
  sans rien) ni `sync.py:_apply_item_upsert` non plus. Extraire un **helper
  partagé** (session, list_id, parent_id, exclude_item_id=None) : le parent
  doit exister dans la même liste, ne pas être supprimé, ne pas être l'item
  lui-même (cycle), ne pas être déjà une sous-tâche → sinon 400.
  Appliquer dans les 3 (add_item via le helper — comportement inchangé).
- `rename_list` : la réponse `ChecklistOut(...)` retourne
  `role="member"` en dur (même pour le propriétaire) et omet
  `folder=checklist.folder` → corriger les deux.
- `list_summary` : `total=len(items)` où `items = unchecked_of(...)` →
  total est toujours == unchecked. `total` = compte de TOUS les items
  non supprimés de la liste.
- **Tests** : patch_item parent inexistant/dans autre liste/dans soi-même /
  parent sous-tâche → 400 ; upsert sync idem ; rename_list propriétaire →
  role owner + folder présent ; list_summary total > unchecked quand des
  items sont cochés.

## 2.4 Webhooks (server/app/events.py)
- `validate_webhook_url()` : le check `parsed.scheme not in ("http","https")`
  (L~29) vient APRÈS le bypass WEBHOOK_ALLOWED_HOSTS — inverser : scheme en
  PREMIER.
- L242 : `httpx.AsyncClient(timeout=settings.WEBHOOK_TIMEOUT)` sans
  `trust_env` → défaut True : si HTTP_PROXY/HTTPS_PROXY est défini sur
  l'hôte, l'IP épinglée et le check SSRF sont contournés.
  `httpx.AsyncClient(timeout=…, trust_env=False)`.
- **Tests** : URL non-http(s) avec host en WEBHOOK_ALLOWED_HOSTS → refusé ;
  AsyncClient construit avec trust_env=False (capturer le constructeur via
  monkeypatch).

## 2.5 Updaters : Zip Slip, timeouts, streaming
- `extractUpdateZip()` (windows_updater.dart) : écrit
  `p.join(tmpDir, entry.key)` sans garde Zip Slip (`../`). Valider
  `p.canonicalize(p.join(tmpDir, entry.key))` commence par
  `p.canonicalize(tmpDir)` (sinon ignorer/refuser l'entrée).
- Vérifier le schéma **https** de l'URL de téléchargement (updater Windows +
  Android + update_service).
- `http.readBytes(...)` (android_updater.dart, windows_updater.dart) et
  `client.get(...)` (update_service.dart) : aucun timeout + binaire chargé
  en RAM. **Stream vers le fichier** (download → file sink) + **timeout** ;
  ajouter un timeout sur `checkForUpdates` (update_service.dart L77) si
  absent.
- **Tests** : entrée zip `../evil` refusée ; URL http:// refusée ;
  checkForUpdates timeout sur réponse lente (fake).

## 3.1 Streams Drift dans build()
`home_screen.dart` L383 (`watchVisibleLists()`), `today_screen.dart` L49
(`watchDueItems()`), `todo_all_screen.dart` L43 (`watchAllUncheckedItems()`)
: les flux sont recréés à chaque build → flash de l'état vide. Stocker en
**champ d'état créé dans initState()** (le stream Drift est multicast/rejeu
— vérifier `start()` si besoin pour le rejeu depuis le début).

## 3.2 Erreurs réseau non catchées dans l'UI
`share_screen.dart` (5 occurrences `on ApiException` L38-90),
`admin_screen.dart` (3 occurrences), `_EmailDialog`
(settings_screen.dart L569) : hors-ligne/timeout, le spinner tourne
indéfiniment et les actions lèvent des exceptions non gérées. Ajouter un
`catch (e)` générique (message d'erreur visible) et un état `_busy` dans
`_EmailDialog`. Ajouter aussi `dispose()` des TextEditingController dans
`LoginScreen`, `ListScreen`, `HomeScreen`, `ShareScreen` (vérifier ce qui
manque — n'ajouter que ce qui n'est pas déjà disposé).

## 3.3 RateLimiter & Redis & TRUSTED_PROXIES
- `RateLimiter.hits` (deps.py L34) : les deque vides ne sont jamais purgés
  du dict (fuite lente, 1 key par IP/cible). Purger les clés vides
  périodiquement (ex. à chaque check, si `len(hits) > 10_000`, retirer les
  deque vides — documenter).
- Branche Redis (deps.py L52-56) : si Redis tombe, `self.redis.incr(...)`
  lève → toute l'API en 500. try/except → log + **fallback mémoire** pour
  l'appel courant (MD-6).
- `TRUSTED_PROXIES` parsing (config.py L40) : `"".split(",")` → `[""]` +
  pas de strip des espaces. MD-6.

## 3.4 SMTP bloquant sur le partage
`sharing.py` L58/L112 : `await send_email(...)` bloque la requête 10-20 s si
le relais est lent. `asyncio.create_task(...)` comme dans auth.py
(le mailer `send_email` est documenté best-effort — vérifier que
`_sync_send` avale ses exceptions, sinon envelopper dans une coroutine
locale qui log l'erreur).

## 3.5 i18n en dur
`list_screen.dart` L710-712 : « quotidien »/« hebdomadaire »/« mensuel » →
`S.daily`/`S.weekly`/`S.monthly` (clés existantes dans app/lib/l10n/s.dart
L96-98 FR / L283+ EN). Balayer les fichiers cités (home_screen,
today_screen, todo_all_screen, login_screen, share_screen) et ne remplacer
que ce qui a une clé S.* existante (MD-5).

## 3.6 Dépendance de test implicite
`server/requirements.txt` : `server/tests/test_compose_env.py` importe yaml
non listé. Ajouter `PyYAML==6.0.3` (version installée vérifiée dans le venv).

## 3.7 ApiClient : récursion infinie possible
`api_client.dart` : les retries après `_tryRefresh()` (get L167-170, patch
L128+, delete L158-161, _post L187-194) n'ont pas de garde → si un 401
persiste après un refresh « réussi », boucle infinie. Ajouter
`bool retried = false` aux méthodes concernées (et au retry de `_post`) :
deuxième 401 après refresh → propager l'erreur.

## Livrables
- **pytest** : 190 baseline + nouveaux tests, tous verts (2× stable).
- **flutter analyze --no-pub** : no issues ; **flutter test** : 106 baseline
  + nouveaux, tous verts (2× stable) ; **flutter build apk --debug** : vert
  (env Android noté en tête).
- **node --check** si app.js touché (attendu : non).
- `scripts/review.py record` (REVIEWER=hermes) APRÈS staging sélectif
  vérifié par `git diff --cached --stat` ; la spec EST commitée ; le rapport
  `specs/2026-11-24-audit-security.md` reste **untracked** (consigne user).
- Commit conventionnel fix, push origin main, CI verte
  (`gh run list --json headSha,workflowName,conclusion` — workflows :
  harness, modern-web-scan ; `commits` est PR-only, skipped = normal sur
  push direct main).
- Déviations par rapport à la spec : toutes documentées avec justification.
