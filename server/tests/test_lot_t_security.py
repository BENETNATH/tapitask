"""Lot T (specs/2026-11-24-security-audit-fixes.md) : T1–T6.

Un test par finding de l'audit sécurité 2026-11-24, côté serveur."""
from __future__ import annotations

import asyncio
import datetime as dt
import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def register(client: AsyncClient, email: str, password: str = "LongPassw0rd!x"):
    r = await client.post("/auth/register", json={"email": email, "password": password})
    assert r.status_code == 201, r.text
    return r.json()


def auth_headers(tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


# --- T1 : MCP list_lists respecte list_scope ------------------------------


@pytest.mark.asyncio
async def test_mcp_list_lists_scoped_key(client):
    """Une clé API scopée ne doit pas énumérer toutes les listes du compte :
    list_lists renvoie uniquement la liste scopée (mêmes sémantiques que
    accessible_list)."""
    from uuid import UUID

    from app.deps import Principal
    from app import mcp_http

    tokens = await register(client, "t1-scoped@example.com")
    h = auth_headers(tokens)
    l1 = (await client.post("/lists", json={"title": "A1"}, headers=h)).json()["id"]
    l2 = (await client.post("/lists", json={"title": "A2"}, headers=h)).json()["id"]

    key = (await client.post("/api-keys", json={"name": "s", "list_scope": l1},
                             headers=h)).json()["key"]
    assert key.startswith("chk_")
    # Principal tel que get_principal le construit pour cette clé scopée.
    from app.db import SessionLocal
    from app.models import ApiKey
    from app.security import hash_api_key
    from sqlalchemy import select
    async with SessionLocal() as session:
        api_key = (await session.execute(
            select(ApiKey).where(ApiKey.key_hash == hash_api_key(key)))).scalar_one()
        scoped = Principal(api_key.user_id, read_only=True, via="api_key",
                           list_scope=UUID(l1))
        unscoped = Principal(api_key.user_id, read_only=True, via="api_key")

    import json
    rows = json.loads(await mcp_http._call_tool(scoped, "list_lists", {}))
    assert [r["id"] for r in rows] == [l1]
    rows = json.loads(await mcp_http._call_tool(unscoped, "list_lists", {}))
    assert sorted(r["id"] for r in rows) == sorted([l1, l2])
    # JWT user : owned + shared inchangé.
    tokens2 = await register(client, "t1-other@example.com")
    h2 = auth_headers(tokens2)
    shared = (await client.post("/lists", json={"title": "S"}, headers=h2)).json()["id"]
    await client.post(f"/lists/{shared}/members",
                      json={"email": "t1-scoped@example.com", "role": "viewer"},
                      headers=h2)
    from app.models import User
    async with SessionLocal() as session:
        user = (await session.execute(
            select(User).where(User.email == "t1-scoped@example.com"))).scalar_one()
        jwt_rows = json.loads(await mcp_http._call_tool(
            Principal(user.id, via="jwt"), "list_lists", {}))
    ids = {r["id"] for r in jwt_rows}
    assert ids == {l1, l2, shared}
    assert {r["role"] for r in jwt_rows if r["id"] == shared} == {"viewer"}


# --- T2 : rotation de refresh atomique -------------------------------------


@pytest.mark.asyncio
async def test_refresh_rotation_atomic(client, monkeypatch, tmp_path):
    """Deux /refresh concurrents avec le même token : exactement un 200,
    l'autre 401, et l'ancien token reste inutilisable."""
    import app.db as db
    from app.db import Base
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
    from sqlalchemy.pool import NullPool

    # Un fichier + NullPool : une vraie connexion par session. Avec la base
    # in-memory (StaticPool), les deux sessions concurrentes partageraient une
    # seule connexion SQLite et le rollback du perdant annulerait l'insert
    # non-commité du gagnant.
    file_engine = create_async_engine(
        f"sqlite+aiosqlite:///{tmp_path / 'refresh_race.sqlite'}",
        poolclass=NullPool)
    async with file_engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    monkeypatch.setattr(db, "SessionLocal",
                        async_sessionmaker(file_engine, expire_on_commit=False))
    try:
        tokens = await register(client, "t2-atomic@example.com")
        ref = tokens["refresh_token"]
        r1, r2 = await asyncio.gather(
            client.post("/auth/refresh", json={"refresh_token": ref}),
            client.post("/auth/refresh", json={"refresh_token": ref}),
        )
        assert sorted((r1.status_code, r2.status_code)) == [200, 401]
        ok = r1 if r1.status_code == 200 else r2
        assert (await client.post("/auth/refresh",
                                  json={"refresh_token": ref})).status_code == 401
        # la paire émise par la prise de possession gagnante fonctionne
        new = ok.json()["refresh_token"]
        assert (await client.post("/auth/refresh",
                                  json={"refresh_token": new})).status_code == 200
    finally:
        await file_engine.dispose()


# --- T3 : change-email — mot de passe avant TOTP + rate limit ---------------


@pytest.mark.asyncio
async def test_change_email_password_checked_before_totp(client, monkeypatch):
    """Mot de passe mauvais + TOTP correct → 401 sans jamais vérifier le TOTP
    (plus d'oracle de brute-force 2FA)."""
    import pyotp

    from app.routers import auth as auth_router

    tokens = await register(client, "t3-a@example.com")
    h = auth_headers(tokens)
    setup = (await client.post("/auth/totp/setup", headers=h)).json()
    secret = setup["secret"]
    code = pyotp.TOTP(secret).now()
    assert (await client.post("/auth/totp/enable",
                              json={"code": code, "token": setup["token"]},
                              headers=h)).status_code == 204
    calls = []
    monkeypatch.setattr(auth_router, "verify_totp",
                        lambda s, c: calls.append(c) or True)
    r = await client.post("/auth/change-email", headers=h, json={
        "new_email": "t3-a-new@example.com", "password": "WrongPassw0rd!",
        "totp_code": code,
    })
    assert r.status_code == 401
    assert calls == [], "le TOTP ne doit pas être vérifié quand le mdp échoue"


@pytest.mark.asyncio
async def test_change_email_rate_limited(client, monkeypatch):
    """Le 6e appel rapide à /change-email (limite abaissée en test) → 429."""
    from app.routers import auth as auth_router

    tokens = await register(client, "t3-b@example.com")
    h = auth_headers(tokens)
    monkeypatch.setattr(auth_router._change_email_limiter, "max_requests", 5)
    auth_router._change_email_limiter.hits.clear()
    codes = []
    for i in range(6):
        r = await client.post("/auth/change-email", headers=h, json={
            "new_email": f"t3b{i}@example.com", "password": "whatever",
        })
        codes.append(r.status_code)
    assert codes[5] == 429


# --- T4 : clamp symétrique dans le sync -------------------------------------


@pytest.mark.asyncio
async def test_sync_clamps_old_client_clock(client):
    """Un item nouveau scellé 2 h dans le passé est ramené à now : il reste
    visible dans le delta des autres clients (curseur entre les deux valeurs)."""
    tokens = await register(client, "t4-oldclock@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "C"},
                                 headers=h)).json()["id"]
    r = await client.post("/sync", json={}, headers=h)
    since = r.json()["server_time"]

    item_id = str(uuid.uuid4())
    past = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=2)).isoformat()
    r = await client.post("/sync", json={"events": [
        {"kind": "item.upsert", "id": item_id, "list_id": list_id,
         "label": "past", "done": False, "updated_at": past},
    ]}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["rejected"] == []

    r = await client.get(f"/lists/{list_id}/items", headers=h)
    stored = r.json()[0]
    # updated_at stocké sans tz = UTC serveur (l'horloge locale du test n'a rien à y voir)
    stored_at = dt.datetime.fromisoformat(stored["updated_at"])
    now_utc = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
    assert abs((stored_at - now_utc).total_seconds()) <= 10, \
        f"updated_at stocké {stored_at}, attendu ≈ now (UTC)"

    # le delta d'un curseur antérieur à l'upsert contient bien l'item
    r = await client.post("/sync", json={"since": since}, headers=h)
    assert any(c["kind"] == "item.upsert" and c["id"] == item_id
               for c in r.json()["changes"])


# --- T5 : plafond de webhooks par liste -------------------------------------


@pytest.mark.asyncio
async def test_webhook_per_list_cap(client):
    """10 hooks OK, le 11e sur la même liste → 409 (plafond WEBHOOKS_MAX_PER_LIST)."""
    from app.config import settings

    assert settings.WEBHOOKS_MAX_PER_LIST == 10
    tokens = await register(client, "t5-hooks@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "H"},
                                 headers=h)).json()["id"]
    codes = []
    for i in range(11):
        r = await client.post(
            f"/lists/{list_id}/hooks",
            json={"url": f"http://hooks.example.com/h{i}"}, headers=h)
        codes.append(r.status_code)
    assert codes[:10] == [201] * 10
    assert codes[10] == 409
    # un hook sur une AUTRE liste n'est pas bloqué
    other = (await client.post("/lists", json={"title": "H2"},
                               headers=h)).json()["id"]
    assert (await client.post(f"/lists/{other}/hooks",
                              json={"url": "http://hooks.example.com/other"},
                              headers=h)).status_code == 201


# --- T6 : rate limit par principal (/sync, bulk, MCP) -----------------------


async def _principal_key_of(client: AsyncClient, email: str) -> str:
    from app.db import SessionLocal
    from app.models import User
    from sqlalchemy import select

    async with SessionLocal() as session:
        user = (await session.execute(
            select(User).where(User.email == email))).scalar_one()
    return f"jwt:{user.id}"


@pytest.mark.asyncio
async def test_principal_rate_limit_sync_and_bulk(client, monkeypatch):
    """Au-delà du seuil (abaissé en test), POST /sync et bulk items → 429,
    par principal."""
    from app import deps

    tokens = await register(client, "t6-rl@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "RL"},
                                 headers=h)).json()["id"]
    monkeypatch.setattr(deps._principal_limiter, "max_requests", 3)
    key = await _principal_key_of(client, "t6-rl@example.com")
    deps._principal_limiter.hits.clear()

    sync_codes = [
        (await client.post("/sync", json={}, headers=h)).status_code
        for _ in range(4)
    ]
    assert sync_codes == [200, 200, 200, 429], sync_codes

    deps._principal_limiter.hits.pop(key, None)
    bulk_codes = [
        (await client.post(f"/lists/{list_id}/items/bulk",
                           json={"text": "x"}, headers=h)).status_code
        for _ in range(4)
    ]
    assert bulk_codes == [201, 201, 201, 429], bulk_codes


@pytest.mark.asyncio
async def test_principal_rate_limit_mcp_messages(client, monkeypatch):
    """POST /mcp/messages passe par le même limiter par principal."""
    from app import deps
    from app import mcp_http

    tokens = await register(client, "t6-mcp@example.com")
    h = auth_headers(tokens)
    from app.db import SessionLocal
    from app.models import User
    from sqlalchemy import select

    async with SessionLocal() as session:
        uid = (await session.execute(
            select(User).where(User.email == "t6-mcp@example.com"))
              ).scalar_one().id
    mcp_http._sessions["t6-sess"] = mcp_http._Session(user_id=str(uid),
                                                       queue=asyncio.Queue())
    try:
        monkeypatch.setattr(deps._principal_limiter, "max_requests", 3)
        deps._principal_limiter.hits.clear()
        payload = {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
        codes = [
            (await client.post("/mcp/messages?sessionId=t6-sess",
                               json=payload, headers=h)).status_code
            for _ in range(4)
        ]
        assert codes == [200, 200, 200, 429], codes
    finally:
        mcp_http._sessions.pop("t6-sess", None)
