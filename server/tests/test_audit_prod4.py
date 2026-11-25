"""Audit prod4 (specs/2026-11-24-audit-prod4-corrections.md) — B3 unit,
M1 (notifies après savepoint), M2 (LWW + audit + notify), S5 (hygiène
serveur). Le test B3 de P1 (Postgres réel) est la preuve d'intégration ;
ici, l'unité SQLite."""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

import pytest
from app.config import settings
from app.db import SessionLocal
from app.main import app, ensure_admin_user
from app.models import (
    ChangeLog,
    Checklist,
    ListMember,
    RefreshToken,
    Role,
    utcnow,
)
from app.routers import auth as auth_router
from app.routers import sync as sync_mod
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select


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


def _iso(dt: datetime) -> str:
    return dt.isoformat()


# ---- B3 : _utc / _clamp_client_dt renvoient un aware-UTC ------------------


def test_utc_helper_naive_is_assumed_utc_aware():
    """B3 (D-3) : les binds SQL reçoivent TOUJOURS un aware — un naïf
    entrant est supposé UTC (contrat MD-1) et rendu aware, pas laissé naïf."""
    naive = datetime(2026, 11, 24, 12, 0, 0)
    out = sync_mod._utc(naive)
    assert out.tzinfo is not None
    assert out == naive.replace(tzinfo=timezone.utc)


def test_clamp_client_dt_returns_aware():
    out = sync_mod._clamp_client_dt(datetime.now(timezone.utc))
    assert out.tzinfo is not None
    assert abs((out - datetime.now(timezone.utc)).total_seconds()) <= 1


def test_utc_helper_converts_aware_input():
    plus2 = datetime(2026, 11, 24, 14, 0, 0, tzinfo=timezone(timedelta(hours=2)))
    assert sync_mod._utc(plus2) == datetime(2026, 11, 24, 12, 0, 0, tzinfo=timezone.utc)


def test_clamp_far_future_is_clamped_and_aware():
    now = datetime.now(timezone.utc)
    out = sync_mod._clamp_client_dt(now + timedelta(seconds=300))
    assert out.tzinfo is not None
    assert abs((out - now).total_seconds()) <= 1


# ---- M1 : notifies agrégées après le savepoint ----------------------------


@pytest.mark.asyncio
async def test_m1_mixed_batch_notifies_only_valid_event(client, monkeypatch):
    """M1 : lot mixte [1 event valide + 1 event refusé] → notify_list appelé
    UNIQUEMENT pour le valide ; l'échec est dans `rejected`."""
    notified: list = []

    async def spy_notify(list_id, payload):
        notified.append((list_id, payload))

    monkeypatch.setattr(sync_mod, "notify_list", spy_notify)

    tokens = await register(client, "m1a@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "M1"}, headers=h)).json()[
        "id"
    ]
    now = _iso(datetime.now(timezone.utc))
    ok_id, bad_id = str(uuid4()), str(uuid4())
    events = [
        {
            "kind": "item.upsert",
            "id": ok_id,
            "list_id": list_id,
            "label": "ok",
            "done": False,
            "position": 0,
            "updated_at": now,
        },
        {
            "kind": "item.upsert",
            "id": bad_id,
            "list_id": list_id,
            "label": "",
            "done": False,
            "position": 1,
            "updated_at": now,
        },  # rejeté
    ]
    r = await client.post("/sync", json={"events": events}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["rejected"] == [bad_id]
    assert len(notified) == 1, f"notify uniquement pour le valide : {notified}"
    assert notified[0][0] == UUID(list_id)
    assert notified[0][1]["kind"] == "item.upsert"


# ---- M2 : LWW + audit + notify sur list.rename ----------------------------


@pytest.mark.asyncio
async def test_m2_rename_lww_and_audit(client, monkeypatch):
    """M2 : état serveur plus récent que le stamp client → ignoré (pas
    d'écriture, pas d'audit, pas de notify) ; stamp plus récent → appliqué
    + entrée d'audit + notification."""
    notified: list = []

    async def spy_notify(list_id, payload):
        notified.append((list_id, payload))

    monkeypatch.setattr(sync_mod, "notify_list", spy_notify)

    tokens = await register(client, "m2@example.com")
    h = auth_headers(tokens)
    list_id = UUID(
        (await client.post("/lists", json={"title": "A"}, headers=h)).json()["id"]
    )

    # État serveur « récent » (légèrement en avant du horloge du test) :
    # un stamp client old (clamped ≤ now) doit perdre en LWW.
    async with SessionLocal() as s:
        cl = (
            await s.execute(select(Checklist).where(Checklist.id == list_id))
        ).scalar_one()
        cl.updated_at = utcnow() + timedelta(seconds=2)
        await s.commit()

    def _audit_count() -> int:
        async def _q() -> int:
            async with SessionLocal() as s:
                r = await s.execute(
                    select(ChangeLog).where(
                        ChangeLog.checklist_id == list_id,
                        ChangeLog.kind == "list.rename",
                    )
                )
                return len(r.scalars().all())

        return _q()

    before = await _audit_count()

    # (a) rename old offline → ignoré
    r = await client.post(
        "/sync",
        json={
            "events": [
                {
                    "kind": "list.rename",
                    "id": str(uuid4()),
                    "list_id": str(list_id),
                    "label": "OLD",
                    "updated_at": _iso(datetime.now(timezone.utc)),
                }
            ]
        },
        headers=h,
    )
    assert r.status_code == 200 and r.json()["rejected"] == [], r.text
    async with SessionLocal() as s:
        cl = (
            await s.execute(select(Checklist).where(Checklist.id == list_id))
        ).scalar_one()
        assert cl.title == "A", "LWW : l'old offline est ignoré"
    assert await _audit_count() == before
    assert notified == [], "pas de notification pour un événement ignoré"

    # (b) rename plus récent → appliqué + audit + notify
    r = await client.post(
        "/sync",
        json={
            "events": [
                {
                    "kind": "list.rename",
                    "id": str(uuid4()),
                    "list_id": str(list_id),
                    "label": "NEW",
                    "updated_at": _iso(
                        datetime.now(timezone.utc) + timedelta(seconds=4)
                    ),
                }
            ]
        },
        headers=h,
    )
    assert r.status_code == 200 and r.json()["rejected"] == [], r.text
    async with SessionLocal() as s:
        cl = (
            await s.execute(select(Checklist).where(Checklist.id == list_id))
        ).scalar_one()
        assert cl.title == "NEW"
    assert await _audit_count() == before + 1
    assert len(notified) == 1
    assert notified[0][0] == list_id and notified[0][1]["kind"] == "list.rename"


# ---- S5 : hygiène serveur -------------------------------------------------


@pytest.mark.asyncio
async def test_s5_auth_email_task_strong_ref():
    """S5 : les tâches mail d'auth sont conservées en référence forte
    (asyncio peut GC un task fire-and-forget sans référence vivante)."""
    ev = asyncio.Event()

    async def slow_mail():
        await ev.wait()

    auth_router._spawn_auth_email(slow_mail())
    assert len(auth_router._in_flight_emails) == 1
    task = next(iter(auth_router._in_flight_emails))
    ev.set()
    while not task.done():
        await asyncio.sleep(0.01)
    assert auth_router._in_flight_emails == set(), "purge au done callback"


async def _bootstrap_admin(client: AsyncClient, email: str) -> dict:
    settings.ADMIN_EMAIL = email
    settings.ADMIN_PASSWORD = "S5AdminPass1!"
    assert await ensure_admin_user() is True
    r = await client.post(
        "/auth/login", json={"email": email, "password": "S5AdminPass1!"}
    )
    assert r.status_code == 200
    settings.ADMIN_EMAIL = ""
    settings.ADMIN_PASSWORD = ""
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


@pytest.mark.asyncio
async def test_s5_admin_password_reset_revokes_refresh_tokens(client):
    """S5 : un reset de mdp par admin DELETE les RefreshToken de
    l'utilisateur — la session ouverte ne survit pas au changement."""
    tokens = await register(client, "s5a@example.com")
    h = auth_headers(tokens)
    user_id = (await client.get("/auth/me", headers=h)).json()["id"]

    async def _count() -> int:
        async with SessionLocal() as s:
            r = await s.execute(
                select(RefreshToken).where(RefreshToken.user_id == UUID(user_id))
            )
            return len(r.scalars().all())

    assert await _count() >= 1, "compte créé → au moins une ligne refresh"

    admin_h = await _bootstrap_admin(client, "s5admin1@tapitask.fr")
    r = await client.patch(
        f"/admin/users/{user_id}", json={"password": "NewPass123!"}, headers=admin_h
    )
    assert r.status_code == 200, r.text
    assert await _count() == 0, "tous les refresh tokens sont révoqués"

    r = await client.post(
        "/auth/login", json={"email": "s5a@example.com", "password": "LongPassw0rd!x"}
    )
    assert r.status_code == 401
    r = await client.post(
        "/auth/login", json={"email": "s5a@example.com", "password": "NewPass123!"}
    )
    assert r.status_code == 200


@pytest.mark.asyncio
async def test_s5_startup_purge_stale_refresh_tokens(client):
    """S5 : la purge au startup supprime les refresh expirés et révoqués,
    mais garde les valids."""
    from app.main import _purge_stale_refresh_tokens

    tokens = await register(client, "s5b@example.com")
    h = auth_headers(tokens)
    user_id = UUID((await client.get("/auth/me", headers=h)).json()["id"])

    async with SessionLocal() as s:
        s.add(
            RefreshToken(
                user_id=user_id,
                token_hash="stale-expired",
                expires_at=utcnow() - timedelta(hours=1),
            )
        )
        s.add(
            RefreshToken(
                user_id=user_id,
                token_hash="stale-revoked",
                expires_at=utcnow() + timedelta(days=1),
                revoked=True,
            )
        )
        await s.commit()

    await _purge_stale_refresh_tokens()

    async with SessionLocal() as s:
        r = await s.execute(select(RefreshToken).where(RefreshToken.user_id == user_id))
        hashes = [x.token_hash for x in r.scalars().all()]
    assert "stale-expired" not in hashes
    assert "stale-revoked" not in hashes
    assert all(x != "stale-expired" and x != "stale-revoked" for x in hashes)


@pytest.mark.asyncio
async def test_s5_my_lists_dedup_owner_with_membership(client):
    """S5 : un propriétaire avec une ligne ListMember (invitation auto-
    acceptée) voit sa liste UNE fois dans /lists (pas owner + member)."""
    tokens = await register(client, "s5c@example.com")
    h = auth_headers(tokens)
    user_id = UUID((await client.get("/auth/me", headers=h)).json()["id"])
    list_id = UUID(
        (await client.post("/lists", json={"title": "DUP"}, headers=h)).json()["id"]
    )

    async with SessionLocal() as s:
        s.add(ListMember(list_id=list_id, user_id=user_id, role=Role.viewer))
        await s.commit()

    r = await client.get("/lists", headers=h)
    assert r.status_code == 200
    mine = [x for x in r.json() if x["id"] == str(list_id)]
    assert len(mine) == 1, f"doublon owner+member : {r.json()}"
