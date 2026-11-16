# Spec — corrections audit run-2 (lot B) : clock LWW, CGNAT, DNS pinning, WS stale, advisory lock, tests MCP

Date : 2026-11-16 · Repo : tapitask · Suite de référence : `cd server && .venv/bin/python -m pytest --quiet`.

Ce run s'exécute **APRÈS** le lot A (`2026-11-16-audit-fixes-a.md`, déjà commité ou non — ne pas toucher à ses fichiers sauf mention explicite). TDD : test d'abord (rouge), fix minimal (vert). Surface minimale (style ponytail) : pas de refactor, pas de feature, pas de commentaire superflu. **Ne pas committer** (l'assistant commit après vérification).

## Périmètre

### 1. `tapitask.sync.client_clock_lww_cursor_poison` (medium) — app/routers/sync.py

État actuel (vérifié) : `_apply_item_upsert` L252 `item.updated_at = _naive(event.updated_at)`, même pour un horodatage client dans le futur (LWW L240, delete L268/276, list.rename L167, list.delete L150, list.create L202/212/213, upsert create L229). Un client à l'horloge future empêche tout événement ultérieur de gagner (LWW) et fait sauter le curseur du delta.

Fix : clamp serveur. Constante module + helper dans sync.py :
```python
from datetime import timedelta
from ..models import utcnow

# Un horodatage client plus de 5 s dans le futur est une horloge cassée,
# pas un événement futur : le clamp serveur protège l'ordre LWW et le
# curseur du delta (audit run-2).
SYNC_CLOCK_TOLERANCE = timedelta(seconds=5)

def _clamp_client_dt(dt: datetime) -> datetime:
    dt = _naive(dt)
    now = _naive(utcnow())
    return now if dt > now + SYNC_CLOCK_TOLERANCE else dt
```
Remplacer **chaque** écriture d'horodatage issu de l'event par `_clamp_client_dt(event.updated_at)` : L150, L167, L202, L212-213 (created_at+updated_at de la liste créée), L229 (created_at de l'item créé), L252, L276, et les COMPARAISONS LWW L240/L268 (comparer contre la valeur clampée — les valeurs stockées l'étant déjà, clamer les deux côtés est l'option la plus sûre et la plus simple).

Test (test_api.py, nouveau test `test_sync_clamps_future_client_clock`) :
- user, liste, item créés via l'API (baseline) ;
- `POST /sync` avec un event `item.upsert` (même id) dont `updated_at` = maintenant + 2h, label `poison` → 200, `rejected` vide ;
- `GET /lists/{id}/items` → l'item porte le label `poison` (l'upsert a été appliqué) MAIS son `updated_at` est ≤ maintenant + 6 s (comparer l'ISO du corps de réponse à `datetime.now(timezone.utc)`) ;
- puis un 2e event `item.upsert` avec `updated_at` = maintenant (horloge saine), label `after` → l'item porte le label `after` (l'ordre LWW n'est plus empoisonné).

### 2. `tapitask.events.fire_webhooks.cgnat_not_blocked` (low) — app/events.py L67-71

État actuel (vérifié) : le bloc SSRF couvre `is_private`, `_METADATA` (169.254.169.254), mais PAS le CGNAT `100.64.0.0/10` (Python ne le classe ni `is_private` ni `is_global`) — un webhook peut ainsi pointer vers un réseau interne CGNAT.

Fix : dans events.py, au module :
```python
_CGNAT = ipaddress.ip_network("100.64.0.0/10")  # RFC 6598
```
et dans la boucle du check : `if ip_address.is_private or ip_address in _METADATA or ip_address in _CGNAT: return False` (à adapter à la signature finale du point 3). L'allowlist `WEBHOOK_ALLOWED_HOSTS` reste prioritaire (opt-in explicite conservé).

Test (nouveau fichier `server/tests/test_events.py`, tests unitaires de la fonction, `set()` comme allowlist) :
- `http://100.64.0.1/x` → bloqué
- `http://100.128.255.254/x` → bloqué (borne haute du CGNAT)
- `http://100.63.255.255/x` → autorisé (public, juste avant le CGNAT)
- `http://100.129.0.1/x` → autorisé (public, juste après le CGNAT)
- `http://100.64.0.1/x` avec allowlist `{"100.64.0.1"}` → autorisé (opt-in explicite)

### 3. `tapitask.events.fire_webhooks.dns_rebinding_toctou` (medium) — app/events.py (check + `_fire`)

État actuel (vérifié) : le check résout le hostname (getaddrinfo), le bloque si privé ; le fetch httpx RÉ-RÉSOUT le même hostname — une seconde résolution peut renvoyer une autre adresse (rebind) et le fetch part où le check n'a pas regardé.

Fix (conçu par l'audit, à implémenter) : **résolution unique, IP épinglée**.
- `check_url` (ou `_webhook_host_allowed`) passe à renvoyer `tuple[bool, str | None]` : `(autorisé, ip_pillée)`. Sémantique du scan d'adresses inchangée (une adresse bloquée disqualifie l'hôte ; l'allowlist prime) ; l'IP pillée est la 1re adresse validée (allowlistée, sinon la 1re publique admise).
- `_fire` : si l'hôte de l'URL n'est pas une IP littérale et qu'une IP a été pillée, re-écrire la partie host de l'URL vers cette IP (IPv6 : `[ip]`) et envoyer l'en-tête `Host: <hostname original>`. IP littérale → pas de ré-écriture (comportement actuel des tests conservé). `getaddrinfo` est appelé UNE SEULE FOIS par livraison.

Tests (test_events.py) :
- Unitaires (monkeypatch `socket.getaddrinfo`) : hostname résolvant vers `1.2.3.4` → `(True, "1.2.3.4")` ; vers `10.0.0.5` → `(False, None)` ; vers `[1.2.3.4, 10.0.0.5]` → `(False, None)`.
- **Règression rebinding** (ASGI plein, conftest) : hook `http://rebind.example.invalid:8443/x` créé via l'API ; monkeypatch de `socket.getaddrinfo` : 1er appel (le check) → `1.2.3.4`, appels suivants (le rebind) → `127.0.0.1` ; allowlist `WEBHOOK_ALLOWED_HOSTS=["1.2.3.4"]` (monkeypatch de `settings.WEBHOOK_ALLOWED_HOSTS`) ; monkeypatch d'`httpx.AsyncClient.post` capturant `(url, headers)` et retournant une réponse 200 factice ; déclencher une livraison via le même chemin que `test_webhook_fires_with_hmac_signature` (création d'item). Assert : l'URL capturée contient `1.2.3.4` (pas `127.0.0.1`), l'en-tête `Host` est `rebind.example.invalid`, et `getaddrinfo` n'a été appelé qu'une fois.
- Le test existant `test_webhook_fires_with_hmac_signature` (127.0.0.1 allowlisté, IP littérale) doit rester vert sans modification.

### 4. `tapitask.ws.connection_auth.stale_session_after_disable` (low) — app/ws.py + app/config.py

État actuel (vérifié) : `websocket_endpoint` (ws.py) accepte, vérifie le token, s'abonne au hub et boucle `queue.get(timeout=30)` / ping — **aucune** re-vérification de `is_active` après l'accept. Un user désactivé garde sa session temps réel ouverte.

Fix :
- app/config.py : ajouter un setting `WS_PING_INTERVAL: float = float(os.environ.get("WS_PING_INTERVAL", "30.0"))` (même pattern que les autres settings ; `.env.example` : option `# WS_PING_INTERVAL=30`).
- ws.py : (a) APRÈS validation du token, charger le user (`SessionLocal`, déjà importé) : `user is None or not user.is_active` → `close(4401)` + return, SANS s'abonner au hub ; (b) dans la branche `except asyncio.TimeoutError` (le tick), re-charger `is_active` avant le ping : inactif → `close(4401)` + return (unsubscribe en `finally`) ; (c) `timeout=settings.WS_PING_INTERVAL` et sleep identique.

Test (nouveau fichier `server/tests/test_ws.py`) — le endpoint est un handler ASGI websocket ; le driver minimal ci-dessous pilote l'app complète (aucun client ws externe requis) :
```python
async def run_ws(app, path, token, close_after=None):
    """Pilote un endpoint websocket ASGI. Retourne la liste des messages
    envoyés par le serveur + le code de close éventuel.
    `close_after` (coroutine) est lancée en background APRÈS l'accept."""
    import asyncio, json as _json
    received, close_code = [], None
    in_q, out_q = asyncio.Queue(), asyncio.Queue()
    await out_q.put({"type": "websocket.connect"})
    await out_q.put({"type": "websocket.receive", "text": _json.dumps({"token": token})})
    async def receive():
        while True:
            m = await in_q.get()
            if m is None:
                return {"type": "websocket.disconnect"}
            return m
    async def send(msg):
        nonlocal close_code
        if msg["type"] == "websocket.close":
            close_code = msg.get("code", 1000)
        else:
            received.append(msg)
    scope = {"type": "websocket", "asgi": {"version": "3.0", "spec_version": "2.3"},
             "http_version": "1.1", "method": "GET", "scheme": "http",
             "path": path, "root_path": "", "query_string": b"",
             "headers": [(b"host", b"test")], "client": ("127.0.0.1", 0),
             "server": ("test", 80), "app": app}
    task = asyncio.create_task(app(scope, receive, send))
    if close_after is not None:
        await close_after()   # ex. : désactiver le user via l'API
    # attendre le close (ou timeout)
    for _ in range(50):
        if close_code is not None:
            break
        await asyncio.sleep(0.1)
    in_q.put_nowait(None)
    await asyncio.wait_for(task, timeout=5)
    return received, close_code
```
Tests :
- `test_ws_rejects_disabled_user_at_connect` : register+login (client conftest), désactivation via admin (pattern L261-268 + `PATCH /admin/users/{id}` `{"is_active": false}`), puis `run_ws(app, "/ws", token)` → `close_code == 4401` et aucun message reçu.
- `test_ws_closed_on_disable_while_connected` : user actif ; dans le test, `monkeypatch.setattr(settings, "WS_PING_INTERVAL", 0.1)` ; `run_ws(..., close_after=désactivation)` → `close_code == 4401` (le tick repère l'inactivité).
- Comportement existant inchangé : user actif, sans `close_after`, le serveur répond `{"kind": "ping"}` au bout du timeout — vérifier via `run_ws` avec un timeout court + lecture d'au moins un message (le driver attend le close ; ici on coupe via `in_q.put_nowait(None)` après réception d'un ping — adapter le driver si nécessaire, l'assert est : ≥1 message reçu avant fermeture).

### 5. (qualité high) advisory lock libéré AVANT l'init — app/main.py L127-149

État actuel (vérifié) :
```python
    if _is_postgres():
        async with engine.connect() as conn:
            await conn.execute(text("SELECT pg_advisory_lock(918273645)"))
            await conn.commit()      # <-- libère le lock (session-scoped, released on commit)
    try:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
    finally:
        if _is_postgres():
            ...pg_advisory_unlock...
```
Le `commit()` L141 libère le lock AVANT `create_all` — la « serialisation » entre workers n'existait pas (le bug que le lock était censé corriger : deux workers qui se concurent sur un ENUM).

Fix : le lock est tenu sur sa connection jusqu'après TOUT l'init ; pas de commit entre lock et unlock :
```python
async def _init_schema() -> None:
    if _is_postgres():
        async with engine.connect() as conn:
            await conn.execute(text("SELECT pg_advisory_lock(918273645)"))
            try:
                await _create_schema()
            finally:
                await conn.execute(text("SELECT pg_advisory_unlock(918273645)"))
                await conn.commit()
    else:
        await _create_schema()

async def _create_schema() -> None:
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    await _ensure_columns()
    await _ensure_indexes()
```
Le docstring est à mettre à jour en conséquence (le lock est tenu, pas libéré au commit).

Test (test_api.py ou nouveau test_main.py, unitaire sans Postgres — un **faux engine** qui journalise l'ordre) :
- `monkeypatch.setattr(main, "engine", FakeEngine())` où FakeEngine : `dialect.name == "postgresql"`, `connect()`/`begin()` retournant des contextes async dont `execute(stmt)` journalise le texte (les 2 appels `pg_advisory_*`), `commit()` journalise, `run_sync(fn)` journalise `create_all` (sans appeler fn) ;
- `monkeypatch` de `main._ensure_columns` / `main._ensure_indexes` (coroutines no-op journalisantes) ;
- `await main._init_schema()` ;
- assert sur l'ordre : `lock < create_all < unlock` ET aucun `commit` entre `lock` et `unlock` (avec le code actuel ce test échoue : `commit` est juste après `lock`).

### 6. (qualité high) aucune couverture cross-tenant MCP — test_api.py

État actuel (vérifié) : `test_mcp_http_bridge` (L558) couvre initialize/tools-list/get_summary/add_items sur sa propre liste — mais AUCUN test n'empêche la fuite cross-tenant via les tools MCP (audit run-2 : 21 checks rejoués manuellement, rien de permanent).

Fix : un test permanent `test_mcp_cross_tenant_isolation` (test_api.py), réutilisant le pattern de `test_mcp_http_bridge` (`mcp_http._sessions[str(user_id)] = q` + `POST /mcp/messages` + `q.get()`) et des users créés via `register` :
- A (attacker) et V (victim) ; V crée liste V1 + item i1 ; A crée liste A1 ;
- en tant que A (JWT) : `get_list(V1)` → erreur `List not found` ; `get_summary(V1)` → erreur ; `add_items(V1, ...)` → erreur ET item absent (vérifié via JWT V) ; `check_item(list_id=A1, item_id=i1, done=True)` → erreur ET i1 non modifié (V voit `done: false`) ; `list_lists` → le titre de V1 n'apparaît pas ;
- clé API scopée de A (`list_scope: A1`, pattern L397) : `get_list(V1)` → erreur ;
- clé API read-only de A (sans scope) : `add_items(A1, ...)` → erreur (refus écriture) ;
- contrôles positifs : membre viewer de V1 (partage pattern L107) — `get_list(V1)` → 200 avec le titre ; A sur sa propre liste A1 → tools écritures OK.
Les assertions d'erreur attendent le texte exact produit par `_call_tool` (`ERROR: ...`) — lire `mcp_http.py` pour le libellé réel ; l'important est : pas de fuite du titre/contenu, pas d'écriture.

### 7. `.env.example` : `# WS_PING_INTERVAL=30` (option, section dédiée ou Rate limiting — à placer près des options opérationnelles).

## Hors périmètre
- Lot A (déjà fait ou en cours) — ne pas toucher `config.py` SAUF l'ajout du setting `WS_PING_INTERVAL`, `conftest.py`, `test_config.py`, `test_compose.py`, `auth.py` (fix refresh), `lists.py` hooks, `sync.py` `_accessible_list_ids`, `docker-compose.yml`.
- Client Dart : le clamp serveur ferme la vulnérabilité (invariant forcé côté serveur) ; la correction d'horloge côté client est un durcissement de suivi, pas de cette spec.
- XFF / SSRF / MCP cross-tenant fix / sync re-parenting : déjà en place — le point 6 n'ajoute QUE des tests.

## Définition de fait
- Suite complète `cd server && .venv/bin/python -m pytest --quiet` 100 % verte (tests du lot A compris).
- `git status --short` ne montre que les fichiers de ce périmètre + ceux du lot A non encore commités.
- Aucun commit, aucun push, aucune tâche réseau sortante.
