# Spec — corrections audit run-2 (lot A) : JWT, exposition, hooks, sync scope, refresh

Date : 2026-11-16 · Repo : tapitask (HEAD a1a351f) · Suite de référence : `cd server && .venv/bin/python -m pytest --quiet` → **38 passed** (baseline, à rester 100 % verte).

Contexte : audit de sécurité run-2 (13 records, voir `~/security-audit-skill/tapitask/run-2/findings.json`). Chaque fix ci-dessous correspond à un record confirmed. TDD : le test est écrit d'abord (rouge), puis le fix minimal (vert). Surface minimale — pas de refactor, pas de feature, pas de commentaire superflu. **Ne pas committer** (le commit est fait par l'assistant après vérification).

## Périmètre

### 1. `tapitask.config.jwt_secret.test_prefix_bypass` (medium) — app/config.py L52

État actuel (vérifié) :
```python
# RFC 7518 §3.2: HMAC-SHA256 keys should be at least 32 bytes. Production
# secrets shorter than that are rejected — tests use the TEST_ENV marker.
if len(settings.JWT_SECRET) < 32 and not settings.JWT_SECRET.startswith("test-"):
    raise RuntimeError(
        "JWT_SECRET trop court (< 32 octets) — générez un secret solide : "
        'python3 -c "import secrets; print(secrets.token_urlsafe(48))"'
    )
```
Le préfixe `test-` dans le CONTENU du secret est un bypass : un secret de 7 octets `test-x` est accepté en production.

Fix : la dérogation passe par une variable d'environnement ORTHOGONALE au contenu, `TEST_ENV` (valeur exacte `"1"`). Plus rien ne dépend du préfixe du secret.

Tests (nouveau fichier `server/tests/test_config.py`) — le guard s'évalue à l'import, donc tests en **sous-processus** (exécuter `python -c "import app.config"` avec `cwd=server` / `PYTHONPATH=server`, environ contrôlé) :
- `JWT_SECRET=short-secret`, pas de `TEST_ENV` → exit ≠ 0, erreur RuntimeError.
- `JWT_SECRET=short-secret`, `TEST_ENV=1` → exit 0.
- `JWT_SECRET=test-abc` (préfixe mais < 32), pas de `TEST_ENV` → exit ≠ 0 (règression du finding).
- `JWT_SECRET` de 32 octets, pas de `TEST_ENV` → exit 0 (chemin production).

Conséquences obligatoires (sinon la suite casse) :
- `server/tests/conftest.py` L5 et `server/tests/test_api.py` L5 : ajouter `os.environ.setdefault("TEST_ENV", "1")` AVANT l'import de app, et porter le secret de test à 32 octets fixes : `test-0123456789abcdef0123456789abcdef` (silence en plus le warning `InsecureKeyLengthWarning`).
- Aucune autre référence au secret de test dans le repo (grep `test-secret`).

### 2. `tapitask.compose.plaintext_api_all_profiles` (medium) — docker-compose.yml L42

État actuel (vérifié, service `api`) :
```yaml
    ports:
      # Port hôte configurable : ${API_PORT} -> 8000 (conteneur)
      - "${API_PORT:-8000}:8000"
```
Le port 8000 de l'API (JWT en clair, sans TLS) est publié sur TOUTES les interfaces de l'hôte.

Fix : binder par défaut sur loopback :
```yaml
    ports:
      # API en clair : écoute loopback par défaut (reverse proxy local).
      # API_BIND=0.0.0.0 uniquement derrière un pare-feu.
      - "${API_BIND:-127.0.0.1}:${API_PORT:-8000}:8000"
```
Les ports de `caddy` (80/443, entrée TLS) et de `web` ne changent PAS.

`.env.example` (section Exposition) : ajouter
```
# Interface hôte d'écoute de l'API. 127.0.0.1 = l'API n'est joignable que
# depuis l'hôte (reverse proxy local recommandé). 0.0.0.0 = toutes interfaces,
# à n'exposer que derrière un pare-feu.
API_BIND=127.0.0.1
```

Test (nouveau fichier `server/tests/test_compose.py`) : `docker compose config` depuis la racine du repo (shellexec ; `pytest.skip` si docker absent). Avec les valeurs par défaut, le service `api` expose `127.0.0.1:8000:8000` ; avec `API_BIND=0.0.0.0`, `0.0.0.0:8000:8000`.

### 3. `tapitask.lists.list_hooks.viewer_secret_read` (medium) — app/routers/lists.py L440-449 + app/schemas.py (WebhookOut)

État actuel (vérifié) :
```python
@router.get("/{list_id}/hooks", response_model=list[WebhookOut])
async def list_hooks(list_id: UUID, principal=Depends(get_principal), session=...):
    await accessible_list(list_id, principal, session)
    result = await session.execute(select(Webhook).where(Webhook.list_id == list_id))
    return [WebhookOut(id=h.id, list_id=h.list_id, url=h.url, secret=h.secret)
            for h in result.scalars()]
```
Le secret HMAC signe les livraisons webhooks : un membre (viewer/editor) peut le lire et forger des événements.

Fix : `WebhookOut.secret` devient `str | None = None` (schemas.py) ; dans `list_hooks`, capturer la checklist retournée par `accessible_list` et n'exposer le secret qu'à **l'admin ou au propriétaire de la liste** :
```python
checklist, _ = await accessible_list(list_id, principal, session)
...
# Le secret signe les livraisons : seul le propriétaire de la liste (et un
# admin) peut le lire — un membre ou une clé API scopée ne doit pas pouvoir
# l'exfiltrer.
can_read_secret = principal.is_admin or (
    principal.list_scope is None and checklist.owner_id == principal.user_id)
return [WebhookOut(id=h.id, list_id=h.list_id, url=h.url,
                   secret=h.secret if can_read_secret else None)
        for h in result.scalars()]
```
Règle d'intention : une clé API `list_scope` (même sur sa propre liste) ne lit PAS le secret — c'est une crédention d'automation étroite, pas un compte propriétaire. `create_hook` (L425-437) continue de retourner le secret à son créateur (inchangé).

Test (test_api.py, nouveau test `test_hooks_secret_visibility`) :
- owner crée une liste + hook (`POST /lists/{id}/hooks`, secret retourné 201) ;
- owner : `GET /lists/{id}/hooks` → secret présent et égal à celui retourné ;
- guest partagé avec `role: viewer` (`POST /lists/{id}/members`, pattern L107-111) : `GET /lists/{id}/hooks` → secret `null` (ou absent), URL visible ;
- admin (bootstrap pattern de `test_admin_user_management` L261-268) : secret visible ;
- clé API scopée sur la liste (pattern `test_api_key_list_scope` L397) : secret `null`.

### 4. `tapitask.sync._accessible_list_ids.list_scope_ignored` (medium) — app/routers/sync.py L171-178

État actuel (vérifié) : `_accessible_list_ids` retourne owned+shared SANS tenir compte de `principal.list_scope` — une clé scopée sur une liste reçoit le delta de TOUTES les listes de son propriétaire (lecture cross-tenant par la voie du sync). Le check d'écriture (`accessible_list`, deps.py L133) bloque l'écriture mais pas la lecture delta.

Fix :
```python
async def _accessible_list_ids(principal: Principal, session: AsyncSession) -> list[UUID]:
    # Une clé API scopée ne voit QUE sa liste — sinon le delta-sync
    # exposerait toutes les listes du propriétaire (audit run-2).
    if principal.list_scope is not None:
        row = (await session.execute(
            select(Checklist.id).where(Checklist.id == principal.list_scope))).first()
        return [row[0]] if row is not None else []
    ... (logique existante owned+shared inchangée)
```

Test (test_api.py, nouveau test `test_sync_delta_respects_list_scope`, pattern `test_api_key_list_scope` L397) :
- user A : listes A1 + A2, items dans les deux (JWT A) ;
- clé API `read_only: true, list_scope: A1` ;
- `POST /sync` avec `since=null` (clé scopée) → les changements ne contiennent que A1 (A2 absente) ;
- `POST /sync` avec `since=<passé>` (clé scopée) → uniquement des events de A1 ;
- `POST /sync` avec un event `item.upsert` ciblant A2 (clé scopée) → l'id est dans `rejected` (403 interne), l'item n'est pas créé (vérifier via JWT A : `GET /lists/A2/items` inchangé).

### 5. (qualité high→fix) refresh accepte un user désactivé — app/routers/auth.py L160-165

État actuel (vérifié) :
```python
    user_result = await session.execute(select(User).where(User.id == UUID(payload["sub"])))
    user = user_result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid refresh token")
```
Un user désactivé (admin) peut continuer à rafraîchir des accès tant qu'il a un refresh token valide (30 jours).

Fix :
```python
    if user is None or not user.is_active:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid refresh token")
```
(Même message — pas de new-info pour le leak de présence.)

Test (test_api.py, nouveau test `test_refresh_rejects_disabled_user`, pattern `test_admin_user_management`) :
- bootstrap admin ; créer un user via `/admin/users` ; login → `refresh_token` ;
- admin `PATCH /admin/users/{id}` `{"is_active": false}` ;
- `POST /auth/refresh` avec l'ancien refresh token → 401.

### 6. `.env.example` : documenter `TEST_ENV`
```
# --- Test-only --------------------------------------------------------------
# 1 = environnement explicitement de test : autorise un JWT_SECRET < 32 octets.
# À NE JAMAIS activer en production.
# TEST_ENV=1
```

## Hors périmètre
- Fixes du lot B (clock/LWW, CGNAT, DNS pinning, WS, advisory lock, tests MCP) — spec `2026-11-16-audit-fixes-b.md`.
- XFF / SSRF / MCP / sync re-parenting : déjà corrigés dans l'arborescence, rejetés par l'audit run-2 — ne rien y toucher.
- Client Dart (app/lib/**) : pas de toolchain dart sur cette machine.
- Android (needs_validation) : hors périmètre.

## Définition de fait
- Suite complète `cd server && .venv/bin/python -m pytest --quiet` 100 % verte (38 existants + tous les nouveaux tests), SANS le warning `InsecureKeyLengthWarning`.
- `git status --short` ne montre que les fichiers de ce périmètre (config.py, conftest.py, test_api.py, test_config.py, test_compose.py, docker-compose.yml, lists.py, schemas.py, sync.py, auth.py, .env.example).
- Aucun commit, aucun push, aucune tâche réseau sortante.
