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


@pytest.mark.asyncio
async def test_scoped_key_list_scope(client):
    """A key scoped to 1 of 3 lists (Strix vuln-0002): GET /lists returns
    only the scoped list, POST /lists is refused (403), and the scoped
    list's items stay fully accessible."""
    tokens = await register(client, "lscope@example.com")
    h = auth_headers(tokens)
    ids = []
    for title in ("L1", "L2", "L3"):
        r = await client.post("/lists", json={"title": title}, headers=h)
        ids.append(r.json()["id"])

    r = await client.post("/api-keys", json={"name": "scoped", "list_scope": ids[0]}, headers=h)
    assert r.status_code == 201, r.text
    kh = {"Authorization": f"Bearer {r.json()['key']}"}

    # the collection is filtered down to the single scoped list
    r = await client.get("/lists", headers=kh)
    assert r.status_code == 200
    assert [e["id"] for e in r.json()] == [ids[0]]

    # no list creation outside the scope
    r = await client.post("/lists", json={"title": "Outside"}, headers=kh)
    assert r.status_code == 403, r.text

    # items of the scoped list remain accessible (read + write)
    assert (await client.get(f"/lists/{ids[0]}/items", headers=kh)).status_code == 200
    r = await client.post(f"/lists/{ids[0]}/items", json={"label": "in-scope"}, headers=kh)
    assert r.status_code == 201, r.text
