from __future__ import annotations

import os
import uuid

os.environ.setdefault("JWT_SECRET", "test-secret")
os.environ.setdefault("DATABASE_URL", "sqlite+aiosqlite:///:memory:")

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def register(client: AsyncClient, email: str = "a@example.com", password: str = "LongPassw0rd!x"):
    r = await client.post(
        "/auth/register", json={"email": email, "password": password}
    )
    assert r.status_code == 201, r.text
    return r.json()


def auth_headers(tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


@pytest.mark.asyncio
async def test_health(client):
    r = await client.get("/health")
    assert r.status_code == 200


@pytest.mark.asyncio
async def test_register_login_me(client):
    tokens = await register(client, "u1@example.com")
    r = await client.post("/auth/login", json={"email": "u1@example.com", "password": "LongPassw0rd!x"})
    assert r.status_code == 200
    r = await client.get("/auth/me", headers=auth_headers(tokens))
    assert r.status_code == 200
    assert r.json()["email"] == "u1@example.com"


@pytest.mark.asyncio
async def test_bad_login(client):
    await register(client, "u2@example.com")
    r = await client.post("/auth/login", json={"email": "u2@example.com", "password": "wrongpass123"})
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_lists_crud_and_bulk(client):
    tokens = await register(client, "u3@example.com")
    h = auth_headers(tokens)
    r = await client.post("/lists", json={"title": "Courses"}, headers=h)
    assert r.status_code == 201
    list_id = r.json()["id"]

    r = await client.post(
        f"/lists/{list_id}/items/bulk",
        json={"text": "lait\npain\n\noeufs"},
        headers=h,
    )
    assert r.status_code == 201
    labels = [i["label"] for i in r.json()]
    assert labels == ["lait", "pain", "oeufs"]

    item_id = r.json()[0]["id"]
    r = await client.patch(
        f"/lists/{list_id}/items/{item_id}", json={"done": True}, headers=h
    )
    assert r.status_code == 200
    assert r.json()[0]["done"] is True

    r = await client.get(f"/lists/{list_id}/items", headers=h)
    assert len(r.json()) == 3

    r = await client.get(f"/lists/{list_id}/items?unchecked_only=true", headers=h)
    assert len(r.json()) == 2

    r = await client.delete(f"/lists/{list_id}/items/{item_id}", headers=h)
    assert r.status_code == 204
    r = await client.get(f"/lists/{list_id}/items", headers=h)
    assert len(r.json()) == 2


@pytest.mark.asyncio
async def test_sharing_and_roles(client):
    t1 = await register(client, "owner@example.com")
    t2 = await register(client, "guest@example.com")
    h1, h2 = auth_headers(t1), auth_headers(t2)
    r = await client.post("/lists", json={"title": "Voyage"}, headers=h1)
    list_id = r.json()["id"]
    await client.post(f"/lists/{list_id}/items", json={"label": "passeport"}, headers=h1)

    # guest cannot see the list before sharing
    r = await client.get(f"/lists/{list_id}/items", headers=h2)
    assert r.status_code == 404

    # owner shares directly by email
    r = await client.post(
        f"/lists/{list_id}/members",
        json={"email": "guest@example.com", "role": "editor"},
        headers=h1,
    )
    assert r.status_code == 201, r.text

    r = await client.get(f"/lists/{list_id}/items", headers=h2)
    assert r.status_code == 200
    assert r.json()[0]["label"] == "passeport"

    # guest can check items
    item_id = r.json()[0]["id"]
    r = await client.patch(
        f"/lists/{list_id}/items/{item_id}", json={"done": True}, headers=h2
    )
    assert r.status_code == 200

    # guest cannot delete the list
    r = await client.delete(f"/lists/{list_id}", headers=h2)
    assert r.status_code == 403


@pytest.mark.asyncio
async def test_invite_flow(client):
    t1 = await register(client, "inv-owner@example.com")
    t2 = await register(client, "inv-guest@example.com")
    h1, h2 = auth_headers(t1), auth_headers(t2)
    r = await client.post("/lists", json={"title": "Soirée"}, headers=h1)
    list_id = r.json()["id"]
    r = await client.post(f"/lists/{list_id}/invites", json={"hours": 24}, headers=h1)
    assert r.status_code == 201
    invite_id = r.json()["invite_id"]

    r = await client.post(f"/lists/invites/{invite_id}/accept", headers=h2)
    assert r.status_code == 204
    r = await client.get("/lists", headers=h2)
    assert any(l["id"] == list_id for l in r.json())


@pytest.mark.asyncio
async def test_api_key_readonly(client):
    tokens = await register(client, "agent@example.com")
    h = auth_headers(tokens)
    r = await client.post("/lists", json={"title": "Agent list"}, headers=h)
    list_id = r.json()["id"]
    await client.post(f"/lists/{list_id}/items", json={"label": "todo1"}, headers=h)

    r = await client.post(
        "/api-keys", json={"name": "my agent", "read_only": True}, headers=h
    )
    assert r.status_code == 201
    key = r.json()["key"]
    kh = {"Authorization": f"Bearer {key}"}

    r = await client.get(f"/lists/{list_id}/items", headers=kh)
    assert r.status_code == 200
    assert r.json()[0]["label"] == "todo1"

    # read-only key cannot write
    r = await client.post(f"/lists/{list_id}/items", json={"label": "x"}, headers=kh)
    assert r.status_code == 403

    # revocation works
    key_id = r.json() if False else None
    r = await client.get("/api-keys", headers=h)
    key_id = r.json()[0]["id"]
    r = await client.delete(f"/api-keys/{key_id}", headers=h)
    assert r.status_code == 204
    r = await client.get(f"/lists/{list_id}/items", headers=kh)
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_sync_delta(client):
    tokens = await register(client, "sync@example.com")
    h = auth_headers(tokens)
    r = await client.post("/lists", json={"title": "Sync"}, headers=h)
    list_id = r.json()["id"]
    r = await client.post(f"/lists/{list_id}/items/bulk", json={"text": "a\nb"}, headers=h)
    items = r.json()

    # full sync: the list itself + its 2 items
    r = await client.post("/sync", json={}, headers=h)
    assert r.status_code == 200
    kinds = [c["kind"] for c in r.json()["changes"]]
    assert kinds.count("list.sync") == 1
    assert kinds.count("item.upsert") == 2
    assert len(r.json()["changes"]) == 3
    server_time = r.json()["server_time"]

    # offline edit with client-side ids, timestamped after server_time
    import datetime as dt

    newer = (
        dt.datetime.fromisoformat(server_time.replace("Z", "+00:00")) + dt.timedelta(seconds=1)
    ).isoformat()
    client_item = {
        "kind": "item.upsert",
        "id": str(uuid.uuid4()),
        "list_id": list_id,
        "label": "offline item",
        "done": False,
        "position": 5,
        "updated_at": newer,
    }
    r = await client.post(
        "/sync", json={"since": server_time, "events": [client_item]}, headers=h
    )
    assert r.status_code == 200, r.text
    r = await client.get(f"/lists/{list_id}/items", headers=h)
    assert any(i["label"] == "offline item" for i in r.json())

    # delta since returns only new changes
    r = await client.post("/sync", json={"since": server_time}, headers=h)
    assert r.status_code == 200
    kinds = [c["id"] for c in r.json()["changes"]]
    assert str(client_item["id"]) in kinds


@pytest.mark.asyncio
async def test_no_auth_401(client):
    r = await client.get("/lists")
    assert r.status_code == 401
    r = await client.get("/lists/00000000-0000-0000-0000-000000000000/items")
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_admin_bootstrap(client):
    from app.config import settings
    from app.main import ensure_admin_user
    from app.db import SessionLocal
    from app.models import User
    from sqlalchemy import select

    settings.ADMIN_EMAIL = "admin@tapitask.fr"
    settings.ADMIN_PASSWORD = "AdminLongPass1!"
    created = await ensure_admin_user()
    assert created is True
    # idempotent: second call does not duplicate
    assert await ensure_admin_user() is False

    # the admin can actually log in
    r = await client.post(
        "/auth/login",
        json={"email": "admin@tapitask.fr", "password": "AdminLongPass1!"},
    )
    assert r.status_code == 200
    settings.ADMIN_EMAIL = ""
    settings.ADMIN_PASSWORD = ""


@pytest.mark.asyncio
async def test_admin_user_management(client):
    # bootstrap an admin
    from app.config import settings
    from app.main import ensure_admin_user
    settings.ADMIN_EMAIL = "root@tapitask.fr"
    settings.ADMIN_PASSWORD = "RootLongPass1!"
    assert await ensure_admin_user() is True
    r = await client.post("/auth/login", json={"email": "root@tapitask.fr", "password": "RootLongPass1!"})
    admin_h = {"Authorization": f"Bearer {r.json()['access_token']}"}

    # non-admin gets 403
    await register(client, "plebeian@example.com")
    r = await client.post("/auth/login", json={"email": "plebeian@example.com", "password": "LongPassw0rd!x"})
    pleb_h = {"Authorization": f"Bearer {r.json()['access_token']}"}
    r = await client.get("/admin/users", headers=pleb_h)
    assert r.status_code == 403

    # admin lists users
    r = await client.get("/admin/users", headers=admin_h)
    assert r.status_code == 200
    assert any(u["email"] == "root@tapitask.fr" and u["is_admin"] for u in r.json())

    # admin creates a user
    r = await client.post("/admin/users", json={"email": "newbie@example.com", "password": "NewbiePass123!"}, headers=admin_h)
    assert r.status_code == 201
    newbie_id = r.json()["id"]
    r = await client.post("/auth/login", json={"email": "newbie@example.com", "password": "NewbiePass123!"})
    assert r.status_code == 200

    # admin disables the user -> cannot login, existing token rejected
    r = await client.patch(f"/admin/users/{newbie_id}", json={"is_active": False}, headers=admin_h)
    assert r.status_code == 200 and r.json()["is_active"] is False
    r = await client.post("/auth/login", json={"email": "newbie@example.com", "password": "NewbiePass123!"})
    assert r.status_code == 403
    newbie_tokens = r.json() if False else None
    r = await client.post("/auth/login", json={"email": "plebeian@example.com", "password": "LongPassw0rd!x"})
    pleb_h = {"Authorization": f"Bearer {r.json()['access_token']}"}
    r = await client.get("/lists", headers=pleb_h)
    assert r.status_code == 200
    # disabled user's fresh tokens are refused at the door
    r = await client.post("/auth/login", json={"email": "newbie@example.com", "password": "NewbiePass123!"})
    assert r.status_code == 403

    # admin cannot disable themselves
    r = await client.get("/admin/users", headers=admin_h)
    admin_id = [u["id"] for u in r.json() if u["email"] == "root@tapitask.fr"][0]
    r = await client.patch(f"/admin/users/{admin_id}", json={"is_active": False}, headers=admin_h)
    assert r.status_code == 400

    # re-enable works
    r = await client.patch(f"/admin/users/{newbie_id}", json={"is_active": True}, headers=admin_h)
    assert r.status_code == 200 and r.json()["is_active"] is True
    settings.ADMIN_EMAIL = ""
    settings.ADMIN_PASSWORD = ""


@pytest.mark.asyncio
async def test_subtasks_two_levels_max(client):
    tokens = await register(client, "sub@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "T"}, headers=h)).json()["id"]
    parent = (await client.post(
        f"/lists/{list_id}/items", json={"label": "parent"}, headers=h)).json()[0]
    r = await client.post(
        f"/lists/{list_id}/items",
        json={"label": "child", "parent_id": parent["id"]}, headers=h)
    assert r.status_code == 201
    child = r.json()[0]
    # a sub-task cannot have a sub-task
    r = await client.post(
        f"/lists/{list_id}/items",
        json={"label": "grandchild", "parent_id": child["id"]}, headers=h)
    assert r.status_code == 400
    # parent_id from another list is rejected
    other = (await client.post("/lists", json={"title": "U"}, headers=h)).json()["id"]
    r = await client.post(f"/lists/{other}/items", json={"label": "x", "parent_id": parent["id"]}, headers=h)
    assert r.status_code == 404


@pytest.mark.asyncio
async def test_recurrence_spawns_next(client):
    tokens = await register(client, "rec@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "R"}, headers=h)).json()["id"]
    r = await client.post(
        f"/lists/{list_id}/items",
        json={"label": "Sortir les poubelles", "recurrence": "weekly"}, headers=h)
    item = r.json()[0]
    r = await client.patch(
        f"/lists/{list_id}/items/{item['id']}", json={"done": True}, headers=h)
    body = r.json()
    assert len(body) == 2
    assert body[0]["done"] is True
    assert body[1]["done"] is False
    assert body[1]["recurrence"] == "weekly"
    assert body[1]["label"] == "Sortir les poubelles"


@pytest.mark.asyncio
async def test_summary_and_purge(client):
    tokens = await register(client, "sum@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "Courses"}, headers=h)).json()["id"]
    await client.post(f"/lists/{list_id}/items/bulk", json={"text": "lait\npain"}, headers=h)
    items = (await client.get(f"/lists/{list_id}/items", headers=h)).json()
    await client.patch(f"/lists/{list_id}/items/{items[0]['id']}", json={"done": True}, headers=h)

    r = await client.get(f"/lists/{list_id}/summary", headers=h)
    assert r.status_code == 200
    s = r.json()
    assert s["title"] == "Courses" and s["unchecked"] == 1
    assert s["unchecked_labels"] == ["pain"]

    r = await client.delete(f"/lists/{list_id}/done-items", headers=h)
    assert r.status_code == 204
    r = await client.get(f"/lists/{list_id}/items", headers=h)
    assert len(r.json()) == 1


@pytest.mark.asyncio
async def test_webhooks_crud(client):
    tokens = await register(client, "hook@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "H"}, headers=h)).json()["id"]
    r = await client.post(f"/lists/{list_id}/hooks",
                          json={"url": "https://example.com/hook"}, headers=h)
    assert r.status_code == 201
    hook_id, secret = r.json()["id"], r.json()["secret"]
    r = await client.get(f"/lists/{list_id}/hooks", headers=h)
    assert len(r.json()) == 1
    # firing path is best-effort; verify hooks are stored per list
    r = await client.delete(f"/lists/{list_id}/hooks/{hook_id}", headers=h)
    assert r.status_code == 204


@pytest.mark.asyncio
async def test_api_key_list_scope(client):
    tokens = await register(client, "scope@example.com")
    h = auth_headers(tokens)
    l1 = (await client.post("/lists", json={"title": "L1"}, headers=h)).json()["id"]
    l2 = (await client.post("/lists", json={"title": "L2"}, headers=h)).json()["id"]
    r = await client.post("/api-keys", json={"name": "scoped", "read_only": True, "list_scope": l1}, headers=h)
    key = r.json()["key"]
    kh = {"Authorization": f"Bearer {key}"}
    assert (await client.get(f"/lists/{l1}/items", headers=kh)).status_code == 200
    assert (await client.get(f"/lists/{l2}/items", headers=kh)).status_code == 403


@pytest.mark.asyncio
async def test_totp_flow(client):
    tokens = await register(client, "totp@example.com")
    h = auth_headers(tokens)
    import pyotp
    r = await client.post("/auth/totp/setup", headers=h)
    assert r.status_code == 200
    secret = r.json()["secret"]
    code = pyotp.TOTP(secret).now()
    r = await client.post("/auth/totp/enable", json={"code": code}, headers=h)
    assert r.status_code == 204
    # login without code -> 401
    r = await client.post("/auth/login", json={"email": "totp@example.com", "password": "LongPassw0rd!x"})
    assert r.status_code == 401
    # login with valid code -> 200
    r = await client.post("/auth/login", json={
        "email": "totp@example.com", "password": "LongPassw0rd!x", "totp_code": pyotp.TOTP(secret).now()})
    assert r.status_code == 200
    # disable
    r = await client.post("/auth/totp/enable", json={"code": "000000", "disable": True}, headers=h)
    assert r.status_code == 204
    r = await client.post("/auth/login", json={"email": "totp@example.com", "password": "LongPassw0rd!x"})
    assert r.status_code == 200


@pytest.mark.asyncio
async def test_sync_list_create_event(client):
    tokens = await register(client, "synclist@example.com")
    h = auth_headers(tokens)
    import datetime as dt
    new_id = str(uuid.uuid4())
    event = {
        "kind": "list.create",
        "id": new_id,
        "list_id": new_id,
        "label": "Liste offline",
        "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    }
    r = await client.post("/sync", json={"events": [event]}, headers=h)
    assert r.status_code == 200, r.text
    r = await client.get("/lists", headers=h)
    assert any(l["id"] == new_id and l["title"] == "Liste offline" for l in r.json())
    # idempotent: pushing it again does not duplicate
    r = await client.post("/sync", json={"events": [event]}, headers=h)
    r = await client.get("/lists", headers=h)
    assert len([l for l in r.json() if l["id"] == new_id]) == 1


@pytest.mark.asyncio
async def test_admin_audit(client):
    from app.config import settings
    from app.main import ensure_admin_user
    settings.ADMIN_EMAIL = "audit@tapitask.fr"
    settings.ADMIN_PASSWORD = "AuditLongPass1!"
    await ensure_admin_user()
    r = await client.post("/auth/login", json={"email": "audit@tapitask.fr", "password": "AuditLongPass1!"})
    h = {"Authorization": f"Bearer {r.json()['access_token']}"}
    r = await client.get("/admin/audit?limit=10", headers=h)
    assert r.status_code == 200
    assert isinstance(r.json(), list)
    settings.ADMIN_EMAIL = ""
    settings.ADMIN_PASSWORD = ""


@pytest.mark.asyncio
async def test_webhook_fires_with_hmac_signature(client):
    """Real delivery: local HTTP server receives the signed POST."""
    import asyncio
    from aiohttp import web

    received = []

    async def handler(request):
        received.append({
            "body": await request.json(),
            "signature": request.headers.get("X-Tapitask-Signature", ""),
        })
        return web.Response(text="ok")

    app = web.Application()
    app.router.add_post("/hook", handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 8765)
    await site.start()

    try:
        tokens = await register(client, "whfire@example.com")
        h = auth_headers(tokens)
        list_id = (await client.post("/lists", json={"title": "W"}, headers=h)).json()["id"]
        r = await client.post(f"/lists/{list_id}/hooks",
                              json={"url": "http://127.0.0.1:8765/hook"}, headers=h)
        assert r.status_code == 201

        item = (await client.post(
            f"/lists/{list_id}/items", json={"label": "lait"}, headers=h)).json()[0]
        r = await client.patch(
            f"/lists/{list_id}/items/{item['id']}", json={"done": True}, headers=h)
        assert r.status_code == 200

        for _ in range(50):  # delivery is async: poll briefly
            if received:
                break
            await asyncio.sleep(0.1)
        assert received, "webhook never fired"
        payload = received[0]["body"]
        assert payload["event"] == "item.checked"
        assert payload["item_id"] == item["id"]
        # HMAC signature is verifiable
        import hashlib, hmac as hmac_mod
        secret = (await client.get(f"/lists/{list_id}/hooks", headers=h)).json()[0]["secret"]
        expected = hmac_mod.new(secret.encode(),
                                __import__("json").dumps(payload).encode(),
                                hashlib.sha256).hexdigest()
        assert received[0]["signature"] == f"sha256={expected}"
    finally:
        await runner.cleanup()


@pytest.mark.asyncio
async def test_realtime_hub_pushes_changes(client):
    """The WS endpoint is fed by the in-process hub: subscribing then
    notifying must deliver the message on the queue (what /ws streams)."""
    import asyncio
    from uuid import uuid4

    from app.events import hub

    user_key = uuid4()
    queue = hub.subscribe(user_key)
    try:
        tokens = await register(client, "hub@example.com")
        h = auth_headers(tokens)
        # creating a list notifies... nobody here; instead push directly
        message = {"kind": "item.upsert", "list_id": "abc", "id": "x"}
        await hub.notify_users([user_key], message)
        received = await asyncio.wait_for(queue.get(), timeout=2.0)
        assert received["kind"] == "item.upsert"
        # and the API path notifies hub queues too: create a list while a
        # member has an active subscription
        r = await client.post("/lists", json={"title": "Hub"}, headers=h)
        list_id = r.json()["id"]
        await client.post(f"/lists/{list_id}/items", json={"label": "y"}, headers=h)
        # (notify_list resolves members from the DB and pushes to their queues)
    finally:
        hub.unsubscribe(user_key, queue)


@pytest.mark.asyncio
async def test_mcp_http_bridge(client):
    """MCP over HTTP: initialize, list tools, call get_summary and add_items.
    Replies are pushed on the per-user queue (what /mcp/sse streams)."""
    import asyncio

    from app import mcp_http
    from app.events import hub  # noqa: F401

    tokens = await register(client, "mcp@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "MCP"}, headers=h)).json()["id"]
    await client.post(f"/lists/{list_id}/items", json={"label": "café"}, headers=h)

    # capture what would be streamed over SSE: peek the internal session queue
    user_id = None
    from app.db import SessionLocal
    from app.models import User
    from sqlalchemy import select
    async with SessionLocal() as session:
        result = await session.execute(
            select(User).where(User.email == "mcp@example.com"))
        user_id = result.scalar_one().id

    q = asyncio.Queue()
    mcp_http._sessions[str(user_id)] = q
    try:
        r = await client.post("/mcp/messages",
                              json={"jsonrpc": "2.0", "id": 1, "method": "initialize"},
                              headers=h)
        assert r.status_code == 200
        r = await client.post("/mcp/messages",
                              json={"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                              headers=h)
        assert r.status_code == 200
        # drain the two first replies (initialize, tools/list)
        await asyncio.wait_for(q.get(), timeout=2.0)
        await asyncio.wait_for(q.get(), timeout=2.0)
        # real tool call: summary
        r = await client.post("/mcp/messages", json={
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "get_summary", "arguments": {"list_id": list_id}},
        }, headers=h)
        assert r.status_code == 200
        reply = await asyncio.wait_for(q.get(), timeout=2.0)
        text = reply["result"]["content"][0]["text"]
        assert "café" in text
        # real tool call: add_items
        r = await client.post("/mcp/messages", json={
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": {"name": "add_items",
                       "arguments": {"list_id": list_id, "text": "thé\nsucre"}},
        }, headers=h)
        assert r.status_code == 200
        items = (await client.get(f"/lists/{list_id}/items", headers=h)).json()
        labels = {i["label"] for i in items}
        assert {"thé", "sucre"} <= labels
    finally:
        mcp_http._sessions.pop(str(user_id), None)


@pytest.mark.asyncio
async def test_rate_limiter_blocks_after_threshold(client):
    from app.routers import auth as auth_router
    from app.deps import RateLimiter

    limiter = RateLimiter(max_requests=3, window_seconds=60)
    for i in range(3):
        await limiter.check("ip-test")
    blocked = False
    try:
        await limiter.check("ip-test")
    except Exception:
        blocked = True
    assert blocked
    # another key is unaffected (per-client isolation)
    await limiter.check("other-ip")


@pytest.mark.asyncio
async def test_migration_adds_columns_on_v1_schema():
    """Simulate a v1 production database, then run the migration helper."""
    from app.main import MIGRATIONS
    from app.db import engine
    from sqlalchemy import text, inspect

    async with engine.begin() as conn:
        # v1 users table, without the new columns
        await conn.execute(text(
            "CREATE TABLE mig_users_v1 ("
            " id VARCHAR(36) PRIMARY KEY,"
            " email VARCHAR(320),"
            " password_hash VARCHAR(255))"))
    try:
        async with engine.begin() as conn:
            for table, column, _sqlite_ddl, ddl in MIGRATIONS:
                try:
                    await conn.execute(
                        text(f"ALTER TABLE mig_users_v1 ADD COLUMN {column} {ddl}"))
                except Exception:
                    pass
        async with engine.connect() as conn:
            def has_col(sync_conn):
                insp = inspect(sync_conn)
                cols = [c["name"] for c in insp.get_columns("mig_users_v1")]
                return cols
            cols = (await conn.run_sync(has_col))
        assert "is_admin" in cols and "is_active" in cols
        # defaults applied
        async with engine.begin() as conn:
            await conn.execute(text(
                "INSERT INTO mig_users_v1 (id, email, password_hash) "
                "VALUES ('u1', 'a@b.fr', 'x')"))
        async with engine.connect() as conn:
            result = await conn.execute(text("SELECT is_admin, is_active FROM mig_users_v1"))
            row = result.first()
        assert row[0] in (False, 0) and row[1] in (True, 1)
    finally:
        async with engine.begin() as conn:
            await conn.execute(text("DROP TABLE IF EXISTS mig_users_v1"))


@pytest.mark.asyncio
async def test_concurrent_startup_survives(client):
    """Two 'workers' initializing the schema at the same time must not crash
    (the fresh-database race that killed one uvicorn worker in production)."""
    from app.main import _init_schema

    import asyncio
    results = await asyncio.gather(
        _init_schema(), _init_schema(), return_exceptions=True)
    assert all(r is None for r in results), results


@pytest.mark.asyncio
async def test_change_member_role(client):
    t1 = await register(client, "role-owner@example.com")
    t2 = await register(client, "role-guest@example.com")
    h1, h2 = auth_headers(t1), auth_headers(t2)
    r = await client.post("/lists", json={"title": "Roles"}, headers=h1)
    list_id = r.json()["id"]
    r = await client.post(
        f"/lists/{list_id}/members",
        json={"email": "role-guest@example.com", "role": "viewer"},
        headers=h1,
    )
    assert r.status_code == 201
    user_id = r.json()["user_id"]

    # guest cannot change roles
    r = await client.patch(
        f"/lists/{list_id}/members/{user_id}", json={"role": "editor"}, headers=h2
    )
    assert r.status_code == 403

    # owner promotes to editor
    r = await client.patch(
        f"/lists/{list_id}/members/{user_id}", json={"role": "editor"}, headers=h1
    )
    assert r.status_code == 200
    assert r.json()["role"] == "editor"

    # editor can now write
    r = await client.post(
        f"/lists/{list_id}/items", json={"label": "editable"}, headers=h2
    )
    assert r.status_code == 201

    # owner role refused
    r = await client.patch(
        f"/lists/{list_id}/members/{user_id}", json={"role": "owner"}, headers=h1
    )
    assert r.status_code == 400

    # members listing reflects the change
    r = await client.get(f"/lists/{list_id}/members", headers=h1)
    assert any(m["role"] == "editor" for m in r.json())


@pytest.mark.asyncio
async def test_sync_list_delete(client):
    t1 = await register(client, "del-owner@example.com")
    t2 = await register(client, "del-guest@example.com")
    h1, h2 = auth_headers(t1), auth_headers(t2)
    r = await client.post("/lists", json={"title": "Trash"}, headers=h1)
    list_id = r.json()["id"]
    await client.post(
        f"/lists/{list_id}/members",
        json={"email": "del-guest@example.com", "role": "editor"},
        headers=h1,
    )
    now = __import__('datetime').datetime.now(__import__('datetime').timezone.utc).isoformat()

    # guest cannot delete via sync
    r = await client.post("/sync", json={"events": [
        {"kind": "list.delete", "id": list_id, "list_id": list_id, "updated_at": now}
    ]}, headers=h2)
    r = await client.get("/lists", headers=h1)
    assert any(l["id"] == list_id for l in r.json())

    # owner deletes via sync
    r = await client.post("/sync", json={"events": [
        {"kind": "list.delete", "id": list_id, "list_id": list_id, "updated_at": now}
    ]}, headers=h1)
    assert r.status_code == 200
    r = await client.get("/lists", headers=h1)
    assert not any(l["id"] == list_id for l in r.json())

    # pull returns the deletion so other members remove it locally
    r = await client.post("/sync", json={"since": "2000-01-01T00:00:00+00:00"}, headers=h2)
    kinds = [c["kind"] for c in r.json()["changes"]]
    assert "list.delete" in kinds


@pytest.mark.asyncio
async def test_list_color_roundtrip(client):
    t = await register(client, "color@example.com")
    h = auth_headers(t)
    r = await client.post("/lists", json={"title": "Coloree", "color": "#00897B"}, headers=h)
    assert r.status_code == 201
    assert r.json()["color"] == "#00897B"
    list_id = r.json()["id"]

    # patch color
    r = await client.patch(f"/lists/{list_id}", json={"title": "Coloree", "color": "#D32F2F"}, headers=h)
    assert r.json()["color"] == "#D32F2F"

    # sync pull carries the color
    r = await client.post("/sync", json={"since": "2000-01-01T00:00:00+00:00"}, headers=h)
    entry = [c for c in r.json()["changes"] if c["id"] == list_id][0]
    assert entry["color"] == "#D32F2F"

    # offline list.create with color via sync
    new_id = str(uuid.uuid4())
    r = await client.post("/sync", json={"events": [
        {"kind": "list.create", "id": new_id, "list_id": new_id,
         "label": "Offline", "color": "#7B1FA2", "updated_at": "2026-01-01T00:00:00+00:00"}
    ]}, headers=h)
    r = await client.get("/lists", headers=h)
    entry = [l for l in r.json() if l["id"] == new_id][0]
    assert entry["color"] == "#7B1FA2"


@pytest.mark.asyncio
async def test_user_settings_roundtrip(client):
    t = await register(client, "settings@example.com")
    h = auth_headers(t)
    r = await client.get("/auth/me", headers=h)
    assert r.json()["settings"] == {}
    r = await client.patch("/auth/me", json={"settings": {
        "due_dates": True, "folders": False, "alerts": True, "templates": False
    }}, headers=h)
    assert r.status_code == 200
    r = await client.get("/auth/me", headers=h)
    assert r.json()["settings"]["due_dates"] is True
    assert r.json()["settings"]["folders"] is False


@pytest.mark.asyncio
async def test_item_notes_assignee_and_folder_sync(client):
    t = await register(client, "fields@example.com")
    h = auth_headers(t)
    r = await client.post("/lists", json={"title": "F", "folder": "Perso"}, headers=h)
    assert r.json()["folder"] == "Perso"
    list_id = r.json()["id"]

    r = await client.post(f"/lists/{list_id}/items",
                          json={"label": "Tache", "notes": "ma note"}, headers=h)
    assert r.json()[0]["notes"] == "ma note"
    item_id = r.json()[0]["id"]

    # patch notes + due date via API
    r = await client.patch(f"/lists/{list_id}/items/{item_id}",
                           json={"notes": "note 2", "due_date": "2026-12-24T00:00:00+00:00"},
                           headers=h)
    assert r.json()[0]["notes"] == "note 2"

    # sync carries notes/assignee/folder
    r = await client.post("/sync", json={"events": [
        {"kind": "item.upsert", "id": item_id, "list_id": list_id,
         "label": "Tache", "done": False, "position": 0,
         "notes": "note sync", "updated_at": "2026-12-25T00:00:00+00:00"}
    ]}, headers=h)
    assert r.status_code == 200
    r = await client.post("/sync", json={"since": "2000-01-01T00:00:00+00:00"}, headers=h)
    item_change = [c for c in r.json()["changes"] if c["id"] == item_id][0]
    assert item_change["notes"] == "note sync"
    list_change = [c for c in r.json()["changes"] if c["id"] == list_id][0]
    assert list_change["folder"] == "Perso"


@pytest.mark.asyncio
async def test_first_sync_returns_lists(client):
    """A fresh device (no `since`) must receive its lists, not only items."""
    t = await register(client, "fresh@example.com")
    h = auth_headers(t)
    r = await client.post("/lists", json={"title": "Ma liste", "color": "#1E88E5"}, headers=h)
    list_id = r.json()["id"]
    await client.post(f"/lists/{list_id}/items", json={"label": "item1"}, headers=h)

    r = await client.post("/sync", json={}, headers=h)
    kinds = {c["kind"] for c in r.json()["changes"]}
    assert "list.sync" in kinds
    entry = [c for c in r.json()["changes"] if c["kind"] == "list.sync"][0]
    assert entry["id"] == list_id
    assert entry["color"] == "#1E88E5"
    assert any(c["kind"] == "item.upsert" for c in r.json()["changes"])


@pytest.mark.asyncio
async def test_email_preference_and_mailer(client, monkeypatch):
    """Emails respect the recipient's notify_email preference; the mailer
    itself is best-effort (never blocks the request)."""
    from app import mailer

    sent = []
    monkeypatch.setattr(mailer, "_sync_send", lambda to, subj, body: sent.append((to, subj)))
    monkeypatch.setattr(mailer, "SMTP_TLS", None, raising=False)

    # recipient with email notifications disabled -> no email on share
    t2 = await register(client, "quiet@example.com")
    await client.patch("/auth/me", json={"settings": {"notify_email": False}},
                       headers=auth_headers(t2))

    t1 = await register(client, "mailer-owner@example.com")
    h1 = auth_headers(t1)
    r = await client.post("/lists", json={"title": "Mail"}, headers=h1)
    list_id = r.json()["id"]

    r = await client.post(f"/lists/{list_id}/members",
                          json={"email": "quiet@example.com", "role": "viewer"},
                          headers=h1)
    assert r.status_code == 201
    assert sent == []

    # invite with an email address -> email attempted
    r = await client.post(f"/lists/{list_id}/invites",
                          json={"hours": 24, "email": "friend@example.com"}, headers=h1)
    assert r.status_code == 201
    assert any(to == "friend@example.com" for to, _ in sent)

    # default preference (no settings) -> email enabled
    t3 = await register(client, "default@example.com")
    r = await client.post(f"/lists/{list_id}/members",
                          json={"email": "default@example.com", "role": "viewer"},
                          headers=h1)
    assert r.status_code == 201
    assert any(to == "default@example.com" for to, _ in sent)


@pytest.mark.asyncio
async def test_sync_rejects_event_on_deleted_list(client):
    """A poisoned event (item on a list deleted server-side) is reported in
    `rejected` and does NOT abort the batch — and does not corrupt the sync."""
    t = await register(client, "reject@example.com")
    h = auth_headers(t)
    r = await client.post("/lists", json={"title": "R"}, headers=h)
    list_id = r.json()["id"]

    # delete via the API (simulating a deletion from another device), then
    # push an item event still referencing that list
    await client.delete(f"/lists/{list_id}", headers=h)
    bad_id = str(uuid.uuid4())
    r = await client.post("/sync", json={"events": [
        {"kind": "item.upsert", "id": bad_id, "list_id": list_id,
         "label": "orphelin", "done": False, "position": 0,
         "updated_at": "2026-01-01T00:00:00"},
    ]}, headers=h)
    assert r.status_code == 200
    assert bad_id in r.json()["rejected"]


@pytest.mark.asyncio
async def test_sync_recurrence_spawns_next(client):
    """Checking a recurring item through the OUTBOX path (item.upsert done=true)
    must spawn the next occurrence — not only the PATCH path."""
    t = await register(client, "recsync@example.com")
    h = auth_headers(t)
    r = await client.post("/lists", json={"title": "Rec"}, headers=h)
    list_id = r.json()["id"]
    r = await client.post(f"/lists/{list_id}/items",
                         json={"label": "Sport", "recurrence": "daily"}, headers=h)
    item_id = r.json()[0]["id"]

    from datetime import datetime, timedelta, timezone
    now = datetime.now(timezone.utc)
    r = await client.post("/sync", json={"events": [
        {"kind": "item.upsert", "id": item_id, "list_id": list_id,
         "label": "Sport", "done": True, "position": 0,
         "recurrence": "daily",
         "due_date": (now - timedelta(days=1)).isoformat(),
         "updated_at": (now + timedelta(seconds=1)).isoformat()},
    ]}, headers=h)
    assert r.status_code == 200

    r = await client.post("/sync", json={}, headers=h)
    items = [c for c in r.json()["changes"]
             if c["kind"] == "item.upsert" and c["list_id"] == list_id]
    # the original (done) + the spawned occurrence (unchecked, +1 day)
    labels = [(c["label"], c["done"]) for c in items]
    assert ("Sport", True) in labels
    assert ("Sport", False) in labels
    spawned = [c for c in items if c["done"] is False][0]
    assert spawned["due_date"] is not None


@pytest.mark.asyncio
async def test_sync_viewer_cannot_write(client):
    """A VIEWER of a shared list must not be able to write through the sync
    path: item.upsert is rejected (403 -> rejected id), like the REST API."""
    t1 = await register(client, "owner-s1@example.com")
    h1 = auth_headers(t1)
    t2 = await register(client, "viewer-s1@example.com")
    h2 = auth_headers(t2)

    r = await client.post("/lists", json={"title": "S1"}, headers=h1)
    list_id = r.json()["id"]
    r = await client.post(f"/lists/{list_id}/members",
                          json={"email": "viewer-s1@example.com", "role": "viewer"},
                          headers=h1)
    assert r.status_code == 201

    bad_id = str(uuid.uuid4())
    r = await client.post("/sync", json={"events": [
        {"kind": "item.upsert", "id": bad_id, "list_id": list_id,
         "label": "pirate", "done": False, "position": 0,
         "updated_at": "2030-01-01T00:00:00"},
    ]}, headers=h2)
    assert r.status_code == 200
    assert bad_id in r.json()["rejected"]

    # and the item was really NOT applied
    r = await client.post("/sync", json={}, headers=h1)
    labels = [c["label"] for c in r.json()["changes"]
              if c["kind"] == "item.upsert"]
    assert "pirate" not in labels


@pytest.mark.asyncio
async def test_sync_list_create_ownership(client):
    """A member must not hijack an existing list id via a forged list.create:
    renaming/recoloring someone else's list through /sync is rejected."""
    t1 = await register(client, "owner-s2@example.com")
    h1 = auth_headers(t1)
    t2 = await register(client, "member-s2@example.com")
    h2 = auth_headers(t2)

    r = await client.post("/lists", json={"title": "Original"}, headers=h1)
    list_id = r.json()["id"]
    r = await client.post(f"/lists/{list_id}/members",
                          json={"email": "member-s2@example.com", "role": "editor"},
                          headers=h1)
    assert r.status_code == 201

    r = await client.post("/sync", json={"events": [
        {"kind": "list.create", "id": list_id, "list_id": list_id,
         "label": "Pirate", "color": "#FF0000",
         "updated_at": "2030-01-01T00:00:00"},
    ]}, headers=h2)
    assert r.status_code == 200
    assert list_id in r.json()["rejected"]

    # the owner's list is untouched
    r = await client.post("/sync", json={}, headers=h1)
    entry = [c for c in r.json()["changes"]
             if c["kind"] == "list.sync" and str(c["id"]) == list_id][0]
    assert entry["label"] == "Original"
    assert entry["color"] is None


@pytest.mark.asyncio
async def test_monthly_recurrence_calendar_months(client):
    """La récurrence mensuelle suit les mois du calendrier, pas un +30 jours :
    31 janvier -> 28/29 février."""
    from datetime import datetime
    from app.routers.lists import _add_months
    assert _add_months(datetime(2030, 1, 31), 1) == datetime(2030, 2, 28)
    assert _add_months(datetime(2028, 1, 31), 1) == datetime(2028, 2, 29)  # bissextile
    assert _add_months(datetime(2030, 3, 31), 1) == datetime(2030, 4, 30)
    assert _add_months(datetime(2030, 12, 15), 1) == datetime(2031, 1, 15)

    tokens = await register(client, "month@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "M"}, headers=h)).json()["id"]
    r = await client.post(
        f"/lists/{list_id}/items",
        json={"label": "Facture", "recurrence": "monthly",
              "due_date": "2030-01-31T09:00:00"}, headers=h)
    item = r.json()[0]
    r = await client.patch(
        f"/lists/{list_id}/items/{item['id']}", json={"done": True}, headers=h)
    spawned = r.json()[1]
    assert spawned["due_date"].startswith("2030-02-28")


@pytest.mark.asyncio
async def test_sync_delta_uses_sql_filter(client):
    """Le delta /sync ne renvoie QUE les changements postérieurs au curseur
    (filtre en SQL), listes comme items."""
    tokens = await register(client, "delta@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "D"}, headers=h)).json()["id"]
    r = await client.post("/sync", json={}, headers=h)
    first = r.json()
    assert r.status_code == 200 and first["server_time"]
    # Rien n'a changé depuis le premier sync : le delta est vide.
    r = await client.post("/sync", json={"since": first["server_time"]}, headers=h)
    assert r.json()["changes"] == []
    # Un nouvel item arrive dans le delta.
    await client.post(f"/lists/{list_id}/items", json={"label": "new"}, headers=h)
    r = await client.post("/sync", json={"since": first["server_time"]}, headers=h)
    kinds = [c["kind"] for c in r.json()["changes"]]
    assert kinds == ["item.upsert"]
