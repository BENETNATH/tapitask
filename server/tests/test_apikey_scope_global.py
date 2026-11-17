from __future__ import annotations

from httpx import ASGITransport, AsyncClient

import pytest

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


async def make_key(client: AsyncClient, headers: dict, **fields) -> dict:
    r = await client.post("/api-keys", json={"name": "k", **fields}, headers=headers)
    assert r.status_code == 201, r.text
    return {"Authorization": f"Bearer {r.json()['key']}"}


@pytest.mark.asyncio
async def test_read_only_key_refused_on_all_mutation_routes(client):
    """A read_only credential is refused on EVERY non-GET route (Strix
    vuln-0001) — centrally, not per route: account settings, 2FA setup,
    2FA enable, and a generic list mutation all return 403."""
    tokens = await register(client, "roglobal@example.com")
    h = auth_headers(tokens)
    kh = await make_key(client, h, read_only=True)

    assert (await client.patch("/auth/me", json={"settings": {"a": 1}}, headers=kh)).status_code == 403
    assert (await client.post("/auth/totp/setup", headers=kh)).status_code == 403
    assert (await client.post("/auth/totp/enable", json={"code": "000000"}, headers=kh)).status_code == 403
    # a generic mutation route: proves the guard is global, not per-route
    assert (await client.post("/lists", json={"title": "X"}, headers=kh)).status_code == 403

    # reads remain allowed
    assert (await client.get("/auth/me", headers=kh)).status_code == 200


@pytest.mark.asyncio
async def test_read_write_key_passes_mutation_routes(client):
    import pyotp

    tokens = await register(client, "rwglobal@example.com")
    h = auth_headers(tokens)
    kh = await make_key(client, h, read_only=False)

    assert (await client.patch("/auth/me", json={"settings": {"a": 1}}, headers=kh)).status_code == 200
    r = await client.post("/auth/totp/setup", headers=kh)
    assert r.status_code == 200, r.text
    secret = r.json()["secret"]
    assert (await client.post(
        "/auth/totp/enable", json={"code": pyotp.TOTP(secret).now()}, headers=kh)).status_code == 204
    assert (await client.post("/lists", json={"title": "X"}, headers=kh)).status_code == 201
