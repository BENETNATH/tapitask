from __future__ import annotations

import pytest
from app.config import settings
from app.db import SessionLocal
from app.main import app
from app.models import User, utcnow
from app.routers import auth as auth_router
from app.security import hash_password
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select


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
    """SMTP off: un register frais émet des tokens (201). Un register répété
    sur un compte VÉRIFIÉ répond 202 uniforme (D-2, prod4) — plus de
    re-émission de tokens inerts ni de (re)envoi d'email de vérification.
    Déviation signalée : avant le lot, le repeat renvoyait 201 (tokens
    inerts) ; D-2 prescrit désormais 202 pour tout compte vérifié."""
    email = "reguni@example.com"
    r1 = await client.post(
        "/auth/register", json={"email": email, "password": "FirstPassw0rd!x"}
    )
    assert r1.status_code == 201, r1.text
    r2 = await client.post(
        "/auth/register", json={"email": email, "password": "SecondPassw0rd!x"}
    )
    # D-2 (prod4) : compte vérifié → 202 uniforme, aucun token dans le corps.
    assert r2.status_code == 202, r2.text
    assert "access_token" not in r2.json()

    # the account is created exactly once, with the FIRST password
    assert await _user_count(email) == 1
    r = await client.post(
        "/auth/login", json={"email": email, "password": "FirstPassw0rd!x"}
    )
    assert r.status_code == 200
    r = await client.post(
        "/auth/login", json={"email": email, "password": "SecondPassw0rd!x"}
    )
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_register_known_email_uniform_smtp_on(client, monkeypatch):
    """SMTP on: identical status AND body for known and unknown emails —
    'si ce compte existe, un email de vérification a été (re)envoyé'."""
    monkeypatch.setattr(settings, "SMTP_ENABLED", True)
    email = "reguni-smtp@example.com"
    r1 = await client.post(
        "/auth/register", json={"email": email, "password": "FirstPassw0rd!x"}
    )
    assert r1.status_code == 202, r1.text
    r2 = await client.post(
        "/auth/register", json={"email": email, "password": "SecondPassw0rd!x"}
    )
    assert r2.status_code == r1.status_code
    assert r2.json() == r1.json()

    # the account is created exactly once (no re-creation on the 2nd call)
    assert await _user_count(email) == 1


# ---- B2 (prod4) : register ne doit pas invalider un token existant --------


@pytest.mark.asyncio
async def test_register_verified_account_202_keeps_token_no_mail(client, monkeypatch):
    """(a) compte vérifié → 202 uniforme, email_token inchangé (sentinelle),
    zéro envoi SMTP (D-2)."""
    captured: list = []

    async def fake_send(to, token):
        captured.append((to, token))

    monkeypatch.setattr(auth_router, "_send_verification_email", fake_send)
    monkeypatch.setattr(settings, "SMTP_ENABLED", True)

    async with SessionLocal() as s:
        s.add(
            User(
                email="b2a@example.com",
                password_hash=hash_password("Passw0rd!x"),
                is_email_verified=True,
            )
        )
        await s.commit()
    # sentinelle : un token déjà posé ne doit PAS être réécrit
    async with SessionLocal() as s:
        u = (
            await s.execute(select(User).where(User.email == "b2a@example.com"))
        ).scalar_one()
        u.email_token = "sentinel-token"
        await s.commit()

    r = await client.post(
        "/auth/register", json={"email": "b2a@example.com", "password": "OtherPass!"}
    )
    assert r.status_code == 202, r.text

    async with SessionLocal() as s:
        u = (
            await s.execute(select(User).where(User.email == "b2a@example.com"))
        ).scalar_one()
        assert u.email_token == "sentinel-token", "email_token inchangé"
    assert captured == [], "aucun mail capturé"


@pytest.mark.asyncio
async def test_register_pending_email_202_keeps_token_no_mail_to_old(
    client, monkeypatch
):
    """(b) compte avec pending_email non nul → 202, email_token inchangé, et
    SURTOUT pas d'envoi à l'ancien email (le mail d'origine part vers
    pending_email, géré par change-email)."""
    captured: list = []

    async def fake_send(to, token):
        captured.append((to, token))

    monkeypatch.setattr(auth_router, "_send_verification_email", fake_send)
    monkeypatch.setattr(settings, "SMTP_ENABLED", True)

    async with SessionLocal() as s:
        u = User(
            email="b2b@example.com",
            password_hash=hash_password("Passw0rd!x"),
            is_email_verified=True,
        )
        u.pending_email = "b2b-new@example.com"
        u.email_token = "sentinel-b"
        s.add(u)
        await s.commit()

    r = await client.post(
        "/auth/register", json={"email": "b2b@example.com", "password": "OtherPass!"}
    )
    assert r.status_code == 202, r.text

    async with SessionLocal() as s:
        u = (
            await s.execute(select(User).where(User.email == "b2b@example.com"))
        ).scalar_one()
        assert u.email_token == "sentinel-b", "email_token inchangé"
        assert u.pending_email == "b2b-new@example.com", "pending_email intact"
    assert captured == [], "aucun mail (pas d'envoi à l'ancien email)"


@pytest.mark.asyncio
async def test_register_unverified_no_pending_keeps_existing_behavior(
    client, monkeypatch
):
    """(c) compte non-vérifié sans pending → comportement existant conservé :
    token réécrit + envoi SMTP."""
    captured: list = []

    async def fake_send(to, token):
        captured.append((to, token))

    monkeypatch.setattr(auth_router, "_send_verification_email", fake_send)
    monkeypatch.setattr(settings, "SMTP_ENABLED", True)

    async with SessionLocal() as s:
        u = User(
            email="b2c@example.com",
            password_hash=hash_password("Passw0rd!x"),
            is_email_verified=False,
        )
        u.email_token = "old-token"
        u.email_token_created_at = utcnow()
        s.add(u)
        await s.commit()

    r = await client.post(
        "/auth/register", json={"email": "b2c@example.com", "password": "OtherPass!"}
    )
    assert r.status_code == 202, r.text

    async with SessionLocal() as s:
        u = (
            await s.execute(select(User).where(User.email == "b2c@example.com"))
        ).scalar_one()
        assert u.email_token != "old-token", "token réécrit"
    assert len(captured) == 1, "un mail envoyé"
    assert captured[0][0] == "b2c@example.com"
