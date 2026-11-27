"""P1 (prod4) — smoke test PostgreSQL 19 réel.

Sauté quand TAPITASK_PG_DSN est absent (CI sans PG reste verte). Quand il
est présent, scripts/pg-smoke.sh pose AUSSI DATABASE_URL au même DSN avant
pytest : le conftest (setdefault) le conserve, et le moteur de l'app parle
vraiment à Postgres pour toute la session.

Scénarios (spec specs/2026-11-24-audit-prod4-corrections.md, P1) :
1. non-régression B3 — stamps client naïf et aware +02:00 → la valeur
   stockée côté PG (items.updated_at, TIMESTAMPTZ) est l'UTC attendu ;
2. LWW réel — un update « old offline » après un update plus récent est
   ignoré, le plus récent gagne, record_change présent ;
3. flux tokens complet B2 sur PG — register + verify-email + login + refresh.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
from app.config import settings
from app.db import SessionLocal
from app.main import _init_schema, app
from app.models import User
from app.routers import auth as auth_router
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select, text

# Skipif TAPITASK_PG_DSN absent : la CI sans PG reste verte. Quand le DSN est
# présent, scripts/pg-smoke.sh pose AUSSI DATABASE_URL au même DSN : le
# moteur de l'app parle vraiment à Postgres pour toute la session.
pytestmark = pytest.mark.skipif(
    not os.environ.get("TAPITASK_PG_DSN"),
    reason="TAPITASK_PG_DSN absent — smoke PG désactivé",
)


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest.fixture(autouse=True)
async def pg_schema():
    """Schema via le migration path de l'app (create_all +
    _ensure_columns + _ensure_indexes, advisory lock PG). Idempotent."""
    await _init_schema()
    yield


# ---- Scénario 1 : B3 — stamps client naïf / aware → UTC stocké -----------


@pytest.mark.asyncio
async def test_b3_client_stamps_stored_as_utc(client):
    """Un stamp NAÏF est supposé UTC (contrat MD-1) ; un stamp AWARE
    +02:00 est converti. Sur PG (TIMESTAMPTZ), un bind naïf serait interprété
    au fuseau de session : un décalage ±1 h/±2 h ferait échouer la
    tolérance de 1 s."""
    tokens = await client.post(
        "/auth/register", json={"email": "b3@smoke.fr", "password": "LongPassw0rd!x"}
    )
    assert tokens.status_code == 201, tokens.text
    h = {"Authorization": f"Bearer {tokens.json()['access_token']}"}
    list_id = (await client.post("/lists", json={"title": "B3"}, headers=h)).json()[
        "id"
    ]

    expected_utc = datetime.now(timezone.utc) - timedelta(seconds=3)
    naive_id, aware_id = str(uuid4()), str(uuid4())
    # même instant, deux encodages client :
    #  - naïf (supposé UTC)
    #  - aware +02:00 (converti en UTC)
    naive_iso = expected_utc.replace(tzinfo=None).isoformat()
    aware_iso = expected_utc.astimezone(timezone(timedelta(hours=2))).isoformat()
    events = [
        {
            "kind": "item.upsert",
            "id": naive_id,
            "list_id": list_id,
            "label": "naive",
            "updated_at": naive_iso,
        },
        {
            "kind": "item.upsert",
            "id": aware_id,
            "list_id": list_id,
            "label": "aware",
            "updated_at": aware_iso,
        },
    ]
    r = await client.post("/sync", json={"events": events}, headers=h)
    assert r.status_code == 200, r.text
    assert not r.json().get("rejected"), r.text

    # Lecture directe de la valeur stockée côté Postgres (TIMESTAMPTZ).
    async with SessionLocal() as session:
        rows = (
            await session.execute(
                text("SELECT id, updated_at FROM items WHERE id IN (:a, :b)"),
                {"a": naive_id, "b": aware_id},
            )
        ).all()
    assert len(rows) == 2, [tuple(r) for r in rows]
    for row in rows:
        stored = row[1]
        assert stored.tzinfo is not None, "PG doit restituer un TIMESTAMPTZ aware"
        drift = abs((stored - expected_utc).total_seconds())
        assert drift <= 1, (
            f"B3 décalage : stocké {stored.isoformat()}, attendu "
            f"{expected_utc.isoformat()} (drift {drift:.2f} s — fuite de fuseau ?)"
        )


# ---- Scénario 2 : LWW réel + record_change --------------------------------


@pytest.mark.asyncio
async def test_lww_newer_wins_and_audit(client):
    """Deux updates : le plus récent gagne ; l'« old offline » qui arrive
    APRÈS l'update serveur est ignoré (pas d'écriture) ; record_change
    présent pour l'update gagnant."""
    tokens = await client.post(
        "/auth/register", json={"email": "lww@smoke.fr", "password": "LongPassw0rd!x"}
    )
    assert tokens.status_code == 201, tokens.text
    h = {"Authorization": f"Bearer {tokens.json()['access_token']}"}
    list_id = (await client.post("/lists", json={"title": "LWW"}, headers=h)).json()[
        "id"
    ]

    now = datetime.now(timezone.utc)
    item_id = str(uuid4())
    # update récent (suffit d'être dans la tolérance ±5 s pour être stocké
    # à son horodatage, pas clamped à now)
    newer = (now + timedelta(seconds=4)).isoformat()
    older = (now + timedelta(seconds=1)).isoformat()

    r = await client.post(
        "/sync",
        json={
            "events": [
                {
                    "kind": "item.upsert",
                    "id": item_id,
                    "list_id": list_id,
                    "label": "nouveau",
                    "updated_at": newer,
                }
            ]
        },
        headers=h,
    )
    assert r.status_code == 200, r.text
    # l'« old offline » arrive ensuite : son stamp est plus ancien que
    # l'état serveur → ignoré
    r = await client.post(
        "/sync",
        json={
            "events": [
                {
                    "kind": "item.upsert",
                    "id": item_id,
                    "list_id": list_id,
                    "label": "ancien-offline",
                    "updated_at": older,
                }
            ]
        },
        headers=h,
    )
    assert r.status_code == 200, r.text

    async with SessionLocal() as session:
        label = (
            await session.execute(
                text("SELECT label FROM items WHERE id = :i"), {"i": item_id}
            )
        ).scalar_one()
        audit = (
            await session.execute(
                text(
                    "SELECT count(*) FROM change_log WHERE item_id = :i "
                    "AND kind = 'item.upsert'"
                ),
                {"i": item_id},
            )
        ).scalar_one()
    assert label == "nouveau", f"LWW : le plus récent doit gagner (label={label!r})"
    assert audit >= 1, "record_change présent pour l'update gagnant"


# ---- Scénario 3 : flux tokens complet B2 sur PG ---------------------------


@pytest.mark.asyncio
async def test_b2_full_token_flow_on_pg(client, monkeypatch):
    """register (202, zéro token) → verify-email (code lu en base) →
    login (200) → refresh (200, nouveaux tokens) — le flux complet, pas
    seulement SQLite. L'envoi SMTP est capturé (pas de réseau)."""
    captured: list = []

    async def fake_send(to, token):
        captured.append((to, token))

    monkeypatch.setattr(auth_router, "_send_verification_email", fake_send)
    monkeypatch.setattr(settings, "SMTP_ENABLED", True)

    r = await client.post(
        "/auth/register",
        json={"email": "b2flow@smoke.fr", "password": "LongPassw0rd!x"},
    )
    # B2 (D-2) : register → 202 uniforme, aucun token écrit
    assert r.status_code == 202, r.text
    assert "access_token" not in r.json()

    # code de vérification lu côté base (l'email est capturé, pas envoyé)
    async with SessionLocal() as session:
        user = (
            await session.execute(select(User).where(User.email == "b2flow@smoke.fr"))
        ).scalar_one()
    assert user.is_email_verified is False
    assert user.email_token, "email_token posé au register (SMTP on)"

    r = await client.post("/auth/verify-email", json={"token": user.email_token})
    assert r.status_code == 204, r.text
    async with SessionLocal() as session:
        user = (
            await session.execute(select(User).where(User.email == "b2flow@smoke.fr"))
        ).scalar_one()
    assert user.is_email_verified is True

    r = await client.post(
        "/auth/login", json={"email": "b2flow@smoke.fr", "password": "LongPassw0rd!x"}
    )
    assert r.status_code == 200, r.text
    access, refresh = r.json()["access_token"], r.json()["refresh_token"]
    assert access and refresh

    r = await client.post("/auth/refresh", json={"refresh_token": refresh})
    assert r.status_code == 200, r.text
    assert r.json()["access_token"] and r.json()["refresh_token"]
    assert r.json()["refresh_token"] != refresh, "rotation : le refresh est remplacé"
