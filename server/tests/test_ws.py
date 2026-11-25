from __future__ import annotations

import pytest
from app.config import settings
from app.events import hub
from app.main import app, ensure_admin_user
from httpx import ASGITransport, AsyncClient


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def register(client: AsyncClient, email: str, password: str = "LongPassw0rd!x"):
    r = await client.post("/auth/register", json={"email": email, "password": password})
    assert r.status_code == 201, r.text
    return r.json()


async def bootstrap_admin(client: AsyncClient, email: str) -> dict:
    settings.ADMIN_EMAIL = email
    settings.ADMIN_PASSWORD = "WsAdminPass1!"
    assert await ensure_admin_user() is True
    r = await client.post(
        "/auth/login", json={"email": email, "password": "WsAdminPass1!"}
    )
    assert r.status_code == 200
    settings.ADMIN_EMAIL = ""
    settings.ADMIN_PASSWORD = ""
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


async def run_ws(app, path, token, close_after=None, wait_for_message=False):
    """Pilote un endpoint websocket ASGI. Retourne la liste des messages
    envoyés par le serveur + le code de close éventuel.
    `close_after` (coroutine) est lancée APRÈS l'accept.
    `wait_for_message=True` coupe le pilote dès le 1er message (user actif
    : pas de close attendu)."""
    import asyncio
    import json as _json

    received, close_code = [], None
    in_q: asyncio.Queue = asyncio.Queue()
    await in_q.put({"type": "websocket.connect"})
    await in_q.put({"type": "websocket.receive", "text": _json.dumps({"token": token})})

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
        elif msg["type"] == "websocket.accept":  # artefact de protocole
            pass
        else:
            received.append(msg)

    scope = {
        "type": "websocket",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": path,
        "root_path": "",
        "query_string": b"",
        "headers": [(b"host", b"test")],
        "client": ("127.0.0.1", 0),
        "server": ("test", 80),
        "app": app,
    }
    task = asyncio.create_task(app(scope, receive, send))
    if close_after is not None:
        await close_after()
    for _ in range(50):
        if close_code is not None or (wait_for_message and received):
            break
        await asyncio.sleep(0.1)
    in_q.put_nowait(None)
    if not task.done():
        task.cancel()
    try:
        await asyncio.wait_for(task, timeout=5)
    except (asyncio.TimeoutError, asyncio.CancelledError):
        pass
    return received, close_code


async def _user_id(client, email) -> tuple[str, dict]:
    tokens = await register(client, email)
    r = await client.get(
        "/auth/me", headers={"Authorization": f"Bearer {tokens['access_token']}"}
    )
    assert r.status_code == 200
    return r.json()["id"], tokens


@pytest.mark.asyncio
async def test_ws_rejects_disabled_user_at_connect(client):
    """Un user désactivé ne doit pas ouvrir de session temps réel (audit
    run-2, ws.connection_auth.stale_session_after_disable)."""
    admin_h = await bootstrap_admin(client, "wsadmin1@tapitask.fr")
    user_id, tokens = await _user_id(client, "ws1@example.com")
    r = await client.patch(
        f"/admin/users/{user_id}", json={"is_active": False}, headers=admin_h
    )
    assert r.status_code == 200 and r.json()["is_active"] is False

    received, close_code = await run_ws(app, "/ws", tokens["access_token"])
    assert close_code == 4401
    assert received == []


@pytest.mark.asyncio
async def test_ws_closed_on_disable_while_connected(client, monkeypatch):
    """Un user désactivé pendant la connexion est déconnecté au prochain
    tick, sans garder sa session ouverte."""
    monkeypatch.setattr(settings, "WS_PING_INTERVAL", 0.1)
    admin_h = await bootstrap_admin(client, "wsadmin2@tapitask.fr")
    user_id, tokens = await _user_id(client, "ws2@example.com")

    async def disable():
        # désactiver une fois l'endpoint abonné (dans sa boucle queue.get,
        # aucun accès DB en cours) : pas d'accès DB concurrent
        import asyncio
        from uuid import UUID

        uid = UUID(user_id)
        for _ in range(500):
            if uid in hub._subscribers:
                break
            await asyncio.sleep(0.01)
        assert uid in hub._subscribers
        r = await client.patch(
            f"/admin/users/{user_id}", json={"is_active": False}, headers=admin_h
        )
        assert r.status_code == 200

    received, close_code = await run_ws(
        app, "/ws", tokens["access_token"], close_after=disable
    )
    # un ping peut avoir été émis entre l'accept et la désactivation :
    # l'assert porte sur le close, pas sur l'absence de ping
    assert close_code == 4401


@pytest.mark.asyncio
async def test_ws_ping_for_active_user(client, monkeypatch):
    """Comportement existant : un user actif reçoit des pings au timeout."""
    monkeypatch.setattr(settings, "WS_PING_INTERVAL", 0.1)
    _, tokens = await _user_id(client, "ws3@example.com")

    received, close_code = await run_ws(
        app, "/ws", tokens["access_token"], wait_for_message=True
    )
    assert len(received) >= 1
    assert received[0]["type"] == "websocket.send"
    import json as _json

    assert _json.loads(received[0]["text"]) == {"kind": "ping"}
    assert close_code is None


@pytest.mark.asyncio
async def test_ws_closed_when_access_token_expires(client, monkeypatch):
    """S5 (prod4) : le JWT access expire — la vérif exp au keepalive coupe
    la connexion au prochain tick (avant le fix : ouverte pour la vie)."""
    monkeypatch.setattr(settings, "WS_PING_INTERVAL", 0.1)
    user_id, _ = await _user_id(client, "ws4@example.com")
    # token qui expire ~1 s après la connexion
    from uuid import UUID

    monkeypatch.setattr(settings, "ACCESS_TOKEN_TTL", 1)
    from app.security import create_access_token

    short_token = create_access_token(UUID(user_id))

    received, close_code = await run_ws(app, "/ws", short_token)
    assert close_code == 4401
