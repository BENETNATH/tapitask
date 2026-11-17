from __future__ import annotations

from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

import pytest

from app.config import settings
from app.db import SessionLocal
from app.main import app
from app.models import User


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def _user_count(email: str) -> int:
    async with SessionLocal() as session:
        result = await session.execute(select(User).where(User.email == email))
        return len(result.scalars().all())


@pytest.mark.asyncio
async def test_register_known_email_uniform_smtp_off(client):
    """SMTP off (dev/prod mode): a repeat register must return the same
    status and body shape as a fresh one — the caller learns nothing about
    account existence (Strix vuln-0003)."""
    email = "reguni@example.com"
    r1 = await client.post(
        "/auth/register", json={"email": email, "password": "FirstPassw0rd!x"})
    assert r1.status_code == 201, r1.text
    r2 = await client.post(
        "/auth/register", json={"email": email, "password": "SecondPassw0rd!x"})
    assert r2.status_code == r1.status_code, (r1.status_code, r2.status_code, r2.text)
    assert set(r2.json()) == set(r1.json())

    # the account is created exactly once, with the FIRST password
    assert await _user_count(email) == 1
    r = await client.post("/auth/login", json={"email": email, "password": "FirstPassw0rd!x"})
    assert r.status_code == 200
    r = await client.post("/auth/login", json={"email": email, "password": "SecondPassw0rd!x"})
    assert r.status_code == 401

    # the repeat response issues no credential for the existing account
    r = await client.get(
        "/auth/me", headers={"Authorization": f"Bearer {r2.json()['access_token']}"})
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_register_known_email_uniform_smtp_on(client, monkeypatch):
    """SMTP on: identical status AND body for known and unknown emails —
    'si ce compte existe, un email de vérification a été (re)envoyé'."""
    monkeypatch.setattr(settings, "SMTP_ENABLED", True)
    email = "reguni-smtp@example.com"
    r1 = await client.post(
        "/auth/register", json={"email": email, "password": "FirstPassw0rd!x"})
    assert r1.status_code == 202, r1.text
    r2 = await client.post(
        "/auth/register", json={"email": email, "password": "SecondPassw0rd!x"})
    assert r2.status_code == r1.status_code
    assert r2.json() == r1.json()

    # the account is created exactly once (no re-creation on the 2nd call)
    assert await _user_count(email) == 1
