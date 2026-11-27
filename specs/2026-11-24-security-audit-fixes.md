# Spec — lot T : corrections de l'audit sécurité 2026-11-24 (T1–T11)

Date : 2026-11-24 · Repo : tapitask · HEAD de référence : f3daae7
Source : `specs/2026-11-24-audit-security.md` (rapport d'audit — **local only, ne PAS committer**)
Suite de référence : `cd server && .venv/bin/python -m pytest --quiet` (157 tests verts au HEAD)
Méthode : TDD — d'abord le test (rouge), ensuite le fix minimal (vert). Surface minimale (ponytail) : suppression bat ajout, pas de boilerplate.

## Périmètre

### T1 (moyen) — MCP `list_lists` respecte `list_scope` — `server/app/mcp_http.py` L236-256
Problème : la query ne filtre que `owner_id` + partages ; une clé API scopée (`list_scope`) énumère toutes les listes du compte (titres compris), alors que tous les autres tools passent par `accessible_list()`.
Fix : appliquer la contrainte `list_scope` du principal à la query owned (et à shared si le principal est une clé scopée) — mêmes sémantiques que `accessible_list()`.
Tests : clé scopée A1 → `list_lists` ne renvoie que A1 ; clé sans scope → toutes les listes owned ; JWT user → owned + shared inchangé.

### T2 (faible) — rotation de refresh atomique — `server/app/routers/auth.py` L189-200
Problème : deux `/refresh` concurrents avec le même token émettent chacun une paire complète.
Fix : transaction unique — UPDATE du token avec `WHERE used_at IS NULL` ; si rowcount == 0 → 401. Émission de la paire seulement si la prise de possession a réussi.
Test : deux `/refresh` concurrents (même token) → exactement un 200, l'autre 401 ; l'ancien token est inutilisable ensuite.

### T3 (faible) — durcissement `change-email` — `server/app/routers/auth.py` L270-286
Problème : route sans rate limit ; TOTP vérifié avant le mot de passe → oracle de brute-force 2FA avec session volée.
Fix : vérifier le mot de passe avant le TOTP (401 si mdp mauvais, sans jamais vérifier le TOTP) ; appliquer le rate limit in-memory existant (même pattern que `/login`).
Tests : mdp mauvais + TOTP correct → 401, TOTP non consommé (mock non appelé) ; 6e appel rapide → 429.

### T4 (faible) — borne basse sur `updated_at` dans le sync — `server/app/routers/sync.py` L261-290
Problème : `7468e5b` a clampé le futur seulement ; un nouvel item scellé dans le passé devient invisible au delta des autres clients.
Fix : clamp symétrique — `_clamp_client_dt` ramène aussi `updated_at < now − tolérance` à `now`.
Test : upsert d'un item nouveau avec `updated_at = now − 2h` → `updated_at` stocké ≈ now (± tolérance) ; l'item apparaît dans le delta d'un client dont le curseur est entre les deux valeurs.

### T5 (faible) — plafond de webhooks par liste — `server/app/routers/lists.py` L468-484
Problème : pas de plafond de webhooks par liste ; `fire_webhooks` en gather non borné → amplification DoS.
Fix : plafond par liste (config `WEBHOOKS_MAX_PER_LIST`, défaut 10) → 409 à la création au-delà. Le gather reste (le plafond le borne).
Test : 11e hook sur la même liste → 409 ; les 10 premiers fonctionnent.

### T6 (faible) — rate limit par principal sur /sync, bulk, MCP — `server/app/deps.py` + routers
Problème : le limiter in-memory ne couvre que `/auth`.
Fix : appliquer le limiter existant par principal à `POST /sync`, bulk items et endpoint MCP (défaut 300 req/min, configurable).
Test : série d'appels au-delà du seuil (limite configurée basse en test) → 429.

### T7 (moyen) — tokens dans `flutter_secure_storage` — `app/lib/data/api_client.dart` L20-34
Problème : access + refresh tokens (30 j) stockés en clair dans SharedPreferences.
Fix : `pubspec.yaml` + `flutter_secure_storage` ; `ApiClient.load/persist` → secure storage ; migration au load : si les tokens sont présents en clair dans SharedPreferences, les migrer en secure storage et supprimer les clés claires.
Tests (flutter test) : migration (prefs clairs → secure, clés claires supprimées) ; persist (valeurs dans le store secure). `flutter test` ET `flutter build apk --debug` doivent passer.

### T8 (faible) — avertissement http:// — `app/lib` (login_screen.dart L97, sync_service.dart L276)
Problème : URL serveur `http://` acceptée sans exigence TLS ni avertissement.
Fix : avertissement visible (dialogue à l'enregistrement + bannière persistante) quand `server_url` commence par `http://` (« connexion non chiffrée »).
Test widget : URL `http://` → avertissement visible ; `https://` → pas d'avertissement.

### T9 (faible) — pin du paquet CI — `.github/workflows/harness.yml` L62
Problème : `npx -y modern-web-guidance@latest` exécute un paquet non figé sur le runner.
Fix : figer la version exacte (résoudre la version courante, `npx -y modern-web-guidance@<version>`).
Vérification : parse YAML + grep de la version figée.

### T10 (faible) — USER non-root — `server/Dockerfile`
Problème : conteneur API en root.
Fix : création d'utilisateur non-root + `USER`. Le port d'écoute (8000) reste fonctionnel.
Vérification : build docker si disponible, sinon grep + note (CI ne build pas l'image).

### T11 (faible) — profil web du compose en loopback — `docker-compose.yml` L55
Problème : le profil web expose `0.0.0.0` par défaut, contrairement au bind loopback de l'API.
Fix : `"${WEB_BIND:-127.0.0.1}:${WEB_PORT:-8080}:80"`.
Vérification : grep du bind 127.0.0.1 dans le compose.

## Hors périmètre
- Le rapport d'audit `specs/2026-11-24-audit-security.md` — reste untracked, ne PAS committer.
- Tout autre changement d'UI ou de feature.
- Redesign du protocole de sync (le clamp symétrique suffit).
- Redis pour le rate limit (le in-memory couvre ce lot).

## Définition de fait
- Suite serveur 100 % verte : `cd server && .venv/bin/python -m pytest --quiet`
- `flutter test` 100 % vert et `flutter build apk --debug` vert (T7, T8 touchent l'app)
- `git status --short` ne montre que les fichiers du périmètre + le rapport d'audit untracked
- Aucun commit, aucun push, aucune tâche réseau sortante
