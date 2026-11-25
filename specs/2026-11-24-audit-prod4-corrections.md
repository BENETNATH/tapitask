# Lot audit production 4 — tapitask (2026-11-24)

Suite de `46fd01a` (lot prod 3, 1.1–3.7). Audit prescriptif vérifié au code
le 2026-11-24 (HEAD `46fd01a`). TDD, surface minimale.
Baseline réelle de `46fd01a` : serveur **209 passed**, flutter **124
passed**, analyze propre, build apk vert.
CI = workflow `harness` (seul workflow au push ; `commits` skipped normal).

## Décisions
- **D-1 (B1)** : double correction — (a) `_initNetwork()` :
  `reloadProfile(required: true)` → `onAccountSwitch()` AVANT
  `sync.init()` ; (b) dans `_submit()`, si `reloadProfile` échoue :
  annuler en écrasant les tokens déjà persistés (`api.accessToken = null;
  api.refreshTokenValue = null; await api.persist()`) — le pattern
  « ne persister qu'après succès » est rejeté : `_auth()` est partagé
  (login + refresh) et déplacer le `persist()` casserait le flux refresh
  ; le catch qui restaure l'étant est minimal et local.
- **D-2 (B2)** : `register()` — si `existing.is_email_verified` est True
  OU `existing.pending_email is not None` → `HTTP 202`
  `_REGISTER_UNIFORM_MESSAGE` sans toucher `existing.email_token` ni
  envoyer d'email (l'audit le prescrit ; le 202 reste uniforme pour les
  autres cas SMTP_ENABLED).
- **D-3 (B3)** : `_utc()` et `_clamp_client_dt()` retournent des
  datetimes **aware UTC** (`dt.replace(tzinfo=timezone.utc)` si naïf,
  sinon `astimezone(timezone.utc)` — un naive est supposé UTC, contrat
  MD-1) ; `_utc_naive()` reste réservé aux comparaisons mémoire
  (contrat MD-1 inchangé). Vérifié au smoke Postgres (P1).
- **D-4 (M6)** : gate du dialog boot : ajouter `!kIsWeb` à la condition
  `windows || android` (l'app web n'offre pas d'installateur) ;
  `update_opener_web.dart` : remplacer `dart:html` par `package:web`
  (déjà en pubspec.lock ; ne PAS activer de wasm flag).
- **D-5 (M8)** : navigation post-login — finaliser sur une pile
  `[Home]` : depuis un login atteint via Réglages
  (`[Home, Settings, Login]`), `pushReplacementNamed` laisse
  `[Home, Settings, Home]`. Fix minimal : `popUntil` jusqu'au premier
  route « home » existant dans la pile (nom de route à localiser dans
  main.dart) puis `pushReplacementNamed("/home")` ; si aucune route
  antérieure n'existe, `pushReplacementNamed` seul. Tester le cas
  `Réglages → Connexion → login OK → Retour` (plus de pile résiduelle).
- **D-6 (S2)** : bouton « Se déconnecter » dans SettingsScreen :
  localiser s'il existe déjà un endpoint serveur de logout
  (`/auth/logout`) — s'il existe : l'appeler puis purge locale
  (tokens null + persist + état déconnecté) ; sinon : purge locale seule
  (documenter). Le comportement attendu : retour LoginScreen,
  `ApiClient.onSessionExpired`/`handleSessionExpired` non nécessaire —
  c'est une déconnexion volontaire.
- **D-7 (L1)** : `pyproject.toml` racine (section `[tool.ruff]`) —
  sélecteur `E4, E7, E9, F, I`, `target-version = "py312"` (venv serveur
  = python3.12), line-length 88 ; corriger les **93 findings**
  (mesurés le 2026-11-24 avec ruff 0.17.3 : 54×I001, 14×E741, 11×F401,
  10×F841, **2×F821 bug réel** — `datetime` non importé dans
  `server/app/routers/lists.py` L388 `_add_months` —, 1×E401, 1×E402).
  Le `scripts/pre-push` (harness) cherche `pyproject.toml` dans `.` —
  il couvre donc `server/` ; après le lot, `ruff check . && ruff format
  --check .` doivent passer à la racine (ruff global, PAS dans la venv —
  ne formater que le code, pas specs/).
- **D-8 (P1)** : smoke test PostgreSQL réel — PostgreSQL 19.0 est
  installé en local (`/usr/lib/postgresql/19`, `psql (PostgreSQL) 19.0`)
  : cluster temporaire (initdb + pg_ctl en /tmp), base dédiée,
  `DATABASE_URL=postgresql+asyncpg://…` — le test est commité
  (server/tests/test_smoke_postgres.py, **skipif** si `TAPITASK_PG_DSN`
  absent → ne casse pas la CI sans PG) et est **exécuté réellement**
  pendant le lot (DSN local), avec le scénario de non-régression B3 :
  horodatage client naive + aware (+02:00) → valeur stockée = l'UTC
  attendue (drift 0).
- **D-9 (S4)** : chaînes FR en dur → `S.t()` UNIQUEMENT si la clé existe
  dans `s.dart` (pattern MD-5) ; `overdueSuffix` existe (confirmée
  s.dart L35/L228, utilisée en dur today_screen L97 + todo_all L92) —
  les autres (login « Je n'ai pas de compte »/« Valider », libellés
  home/list/share) : si pas de clé, garder + documenter (pas de
  création de clés).

## B1 — Fuite inter-comptes si reloadProfile échoue (D-1)
- `app/lib/state/app_state.dart` `_initNetwork()` (L153) : réordonner en
  `reloadProfile(required: true)` → (si email changé) `onAccountSwitch()`
  → `sync.init()` ; un échec de reloadProfile avant le sync doit conduire
  à l'état déconnecté (pas de sync avec les données du compte précédent).
- `app/lib/ui/login_screen.dart` `_submit()` : sur échec de
  `reloadProfile(required: true)` → écraser les tokens persistés par
  `_auth()` (voir D-1) avant l'affichage d'erreur.
- **Tests** : widget/integration — login compte B avec `/auth/me` qui
  échoue → `api.accessToken == null` après ; `_initNetwork` avec compte
  B actif → `sync.init` appelé APRÈS le reload (ordre, mock/spy).

## B2 — /auth/register ne doit pas invalider un token existant
(`server/app/routers/auth.py`, register ~L120)
- Si `existing.is_email_verified` ou `existing.pending_email is not
  None` → `202` `_REGISTER_UNIFORM_MESSAGE`, zéro écrit
  `email_token`, zéro envoi SMTP.
- **Tests** : (a) compte vérifié → register → 202, `email_token`
  inchangé (valeur sentinelle), aucun mail capturé ; (b) compte avec
  `pending_email` non nul → idem (et surtout pas d'envoi à l'ancien
  email — le mail d'origine va à pending_email) ; (c) compte
  non-vérifié sans pending → comportement existant conservé (token
  réécrit + envoi) — tests existants à maintenir.

## B3 — Aware UTC dans les binds Postgres (D-3)
- `sync.py` : `_utc()` aware-UTC ; `_clamp_client_dt()` aware-UTC
  (le clamp ±5 s s'applique puis aware) ; `_utc_naive()` réservé
  comparaisons mémoire (contrat MD-1, doc inchangée).
- `lists.py` `patch_item` : idem pour l'horodatage assigné.
- **Tests** : le test B3 de P1 (Postgres réel) est la preuve ; en
  SQLite, ajouter un test unitaire que `_clamp_client_dt`/`_utc`
  retournent `tzinfo is not None` (aware).

## M1 — pending_notifies après savepoint (sync.py)
`event_notifies` liste locale dans `_apply_event`/`_apply_list_create`
& co ; `pending_notifies.extend(event_notifies)` UNIQUEMENT après la
sortie du `session.begin_nested()` (un flush en échec n'envoie pas de
notification).
- **Test** : un lot mixte (1 event valide + 1 event qui échoue au
  savepoint, ex. FK cassée) → `notify_list` appelé uniquement pour le
  valide (mock/spy), l'échec est dans `rejected`.

## M2 — LWW + audit + notify sur list.create (update) et list.rename
- `_apply_list_create` branche `existing` : si
  `existing.updated_at >= stamp` (comparaison `_utc_naive`) → ignorer
  (LWW) ; sinon appliquer + `record_change` + `pending_notifies`.
- branche `list.rename` de `_apply_event` : même triade (LWW +
  record_change + notify).
- **Tests** : renommage récent côté serveur + rename old offline →
  ignoré (LWW) ; rename plus récent → appliqué + entrée d'audit +
  notification.

## M3 — Webhooks : DNS non bloquant + CGNAT v4-mappé + rejet explicite
(`server/app/events.py`)
- `socket.getaddrinfo` synchrone → `await asyncio.to_thread(socket.getaddrinfo, host, None)`
  (les 2 sites, L66 + L170) — le worker uvicorn unique ne doit pas
  être bloqué par un DNS lent.
- `_ip_is_public()` : déplier `ip = ip.ipv4_mapped or ip` avant les
  checks (CGNAT `100.64.0.0/10` en `::ffff:`) — et/ou `not ip.is_global`
  (vérifier les deux lectures au code, choisir la plus étroite).
- dans `_webhook_host_allowed()`, l'`except Exception: continue` →
  rejet : si aucune adresse n'est valide → `return False, None`.
- **Tests** : host résolvant vers `::ffff:100.64.0.1` → rejeté ;
  host DNS lents mockés (to_thread spy) → l'attente passe par
  to_thread (spy) ; host non résolvable → rejet explicite (pas de
  notification envoyée).

## M4 — CORS_ORIGINS nettoyé (`server/app/config.py` L20)
Réutiliser le helper `_parse_csv(...)` (celui de TRUSTED_PROXIES) au
lieu de `.split(",")` — `CORS_ORIGINS=a, b` ne doit plus garder un
espace.
- **Test** : config avec espaces → les origines sont stripped.

## M5 — _loadToken : valeur vide = null (`app/lib/data/api_client.dart`)
La branche `plain != null` migre sans filtrer `""` (écrit `""` en
secure storage et retourne `""` → `accessToken != null` avec un token
vide). Appliquer le filtre `value.isEmpty ? null : value` aux deux
branches (une valeur plain vide n'est PAS migrée — elle est juste
supprimée).
- **Test** : SharedPreferences legacy `{"access_token": ""}` →
  `accessToken == null`, clé absente des deux stores.

## M6 — Web : pas de dialog boot + package:web (D-4)
- `main.dart` L99 : `!kIsWeb &&` dans le gate.
- `update_opener_web.dart` : `dart:html` → `package:web`
  (API équivalente, import `package:web/web.dart`).
- **Tests** : widget test avec `debugDefaultTargetPlatformOverride =
  windows` + kIsWeb simulé (ou test unitaire de la condition extraite —
  à la surface la plus testable, documenter) → pas de dialog ;
  l'import package:web compile (flutter analyze + build apk).

## M7 — setup_tapitask.ps1 : chemins forward-slash (L73)
`storeFile=$Root/tapitask.keystore` → `($Root -replace '\\', '/')`
(`java.util.Properties.load` interprète `\U`, `\t`…).
- **Test** : N/A (Windows) — le diff lu + `pwsh -NoProfile -Command
  "…"` si pwsh dispo, sinon lu et documenté.

## M8 — Navigation post-login : pile résiduelle (D-5)
Comme D-5 : finaliser sur `[Home]` ; test widget :
`Home → Settings → Login → login OK` → `Back` ne ramène ni sur
Settings ni sur un Home fantôme (1 route dans la pile).

## S1 — WidgetItemAdapter : Intent() vide partout (L102)
La branche « tout coché » passe encore `null` à
`setOnClickFillInIntent` (recyclage → ancien intent de toggle) :
`Intent()` (cohérence MD-4, L130).
- **Test** : N/A Kotlin — diff lu (le build apk compile).

## S2 — Bouton « Se déconnecter » (D-6)
SettingsScreen : bouton qui appelle le logout (endpoint si existant,
sinon purge locale) → état déconnecté (LoginScreen), tokens purgés,
WS fermé, widget mis à jour.
- **Test** : widget — login simulé → tap logout → `accessToken == null`,
  route login, pas de tentative de sync.

## S3 — _busy + mounted guards
`login_screen.dart` (double-tap), `search_screen.dart`,
`admin_screen.dart`, `share_screen.dart`, `list_screen.dart` (après
`await _list()`) : guard `_busy`/`_submitted` sur le submit +
`if (!mounted) return;` après chaque await avant `setState`.
- **Test** : widget — double tap login → 1 seul appel API (spy).

## S4 — Chaînes FR → S.t() si clé existe (D-9)
`"  •  en retard"` → `S.t("overdueSuffix")` dans today_screen L97 et
todo_all L92 (clé confirmée) ; les autres libellés cités : uniquement si
clé existante, sinon documenté.
- **Test** : test widget existant couvrant l'affichage retard (mettre à
  jour si le texte est asserté).

## S5 — Hygiène serveur (5 items)
- `auth.py` : `asyncio.create_task(_send_…)` sans référence forte →
  réutiliser le pattern `_in_flight` (sharing.py / lists.py) pour
  éviter le GC du task.
- admin : le reset de mot de passe par admin doit révoquer les
  RefreshToken de l'utilisateur (DELETE par user) ; purge des lignes
  expirées/révoquées de `refresh_tokens` (un `DELETE WHERE expires_at <
  now()` au startup suffit — documenter).
- `ws.py` : couper la connexion si le JWT access expire (vérifier
  l'exp dans la boucle de keepalive/autorisation existante) et/ou
  documenter si la vérif est faite ailleurs (à confirmer au code —
  l'audit dit « uniquement si is_active passe à False »).
- `lists.py` `my_lists` : doublon quand le propriétaire accepte sa
  propre invitation (`ListMember` en plus de `owner_id`) → dédupliquer
  (le test de l'audit : invitation auto-acceptée → 1 entrée).
- `mcp_server.py` `_uuid_arg` (L113) : `return str(uuid.UUID(value))`
  (normalisation ; refuse les accolades/espaces).
- **Tests** : 1 par item (mocks pour les 2 premiers, le reste direct).

## L1 — Config ruff + lint (D-7)
Comme D-7 : `pyproject.toml` racine + correction des 93 findings
(I001/F401 auto, E741 renoms, F841, **F821 bug réel** — ajouter le
`datetime` manquant à `lists.py` et vérifier le comportement de
`_add_months`), E401/E402. Le gate pre-push doit ensuite tourner au
push (« harness pre-push: ruff (.) ») et passer.
- Ne PAS toucher aux workflows CI (harness reste pytest-only — la
  parité se fait en pre-push, comme Aptigraph).

## P1 — Smoke test PostgreSQL 19 réel (D-8)
- `server/tests/test_smoke_postgres.py` : module pytest,
  **skipif `os.environ.get("TAPITASK_PG_DSN")` absent** (CI sans PG
  reste verte) ; quand le DSN est présent :
  - setup : schema via le migration path de l'app (localiser
    l'équivalent alembic/init), user test ;
  - scénario 1 (non-régression B3) : sync avec un horodatage client
    **naïf** et un **aware +02:00** → lire la valeur stockée côté
    Postgres (`updated_at`) → égale à l'UTC attendue (tolérance 1 s) —
    un décalage ±1 h/±2 h = échec ;
  - scénario 2 : LWW réel — 2 updates (1 old offline après un update
    serveur) → le plus récent gagne, `record_change` présent ;
  - scénario 3 : register + login + refresh + verify-email (B2) sur
    PG (le flux tokens complet, pas seulement SQLite).
- Exécution réelle pendant le lot : cluster PG 19 temporaire
  (initdb/pg_ctl en /tmp, `psql`/`pg_ctl` dans `/usr/lib/postgresql/19/`)
  + `TAPITASK_PG_DSN=postgresql+asyncpg://…` → le module passe vert.
  Le cluster est détruit en fin de lot ; le script de
  reproductibilité (quelques lignes : initdb/start/pytest/stop) est
  commité dans `scripts/` (ex. `scripts/pg-smoke.sh`) — sans dépendance
  réseau, localhost uniquement.

## Livrables
- **pytest** : 209 baseline + nouveaux tests, tous verts 2× stable
  (module P1 skip sans DSN, vert avec DSN local) ; `flutter analyze
  --no-pub` no issues ; `flutter test` 124 baseline + nouveaux 2×
  stable ; `flutter build apk --debug` vert.
- `ruff check . && ruff format --check .` verts à la racine (L1).
- Smoke PG réel exécuté (P1) — résultat rapporté (valeurs lues en base).
- `scripts/review.py record` (REVIEWER=hermes) APRÈS staging sélectif
  vérifié par `git diff --cached --stat` (TJOURS vérifier le staged
  stat après chaque add) ; spec commitée avec le lot ;
  `specs/2026-11-24-audit-security.md` reste **untracked** (jamais
  commité).
- Commit conventionnel fix, push origin main, CI (`harness`) verte sur
  le nouveau sha.
- Déviations par rapport à la spec : toutes documentées avec
  justification.
