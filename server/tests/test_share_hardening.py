from __future__ import annotations

from uuid import UUID

from httpx import ASGITransport, AsyncClient
from sqlalchemy import select, text
from sqlalchemy.exc import IntegrityError

import pytest

from app.db import SessionLocal, engine
from app.main import app
from app.models import ListMember


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
async def test_null_byte_in_item_label_rejected(client):
    tokens = await register(client, "nullb1@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "NB"}, headers=h)).json()["id"]
    r = await client.post(f"/lists/{list_id}/items", json={"label": "bad\u0000label"}, headers=h)
    assert r.status_code == 400, (r.status_code, r.text)


@pytest.mark.asyncio
async def test_null_byte_in_list_title_rejected(client):
    tokens = await register(client, "nullb2@example.com")
    h = auth_headers(tokens)
    r = await client.post("/lists", json={"title": "bad\u0000title"}, headers=h)
    assert r.status_code == 400, (r.status_code, r.text)


@pytest.mark.asyncio
async def test_invite_redeem_by_existing_member_409(client):
    """An already-member redeeming an invite gets a clean 409, not a bare
    500 (Strix hardening item)."""
    to = await register(client, "invown2@example.com")
    tm = await register(client, "invmemb2@example.com")
    ho, hm = auth_headers(to), auth_headers(tm)
    list_id = (await client.post("/lists", json={"title": "Inv2"}, headers=ho)).json()["id"]
    i1 = (await client.post(f"/lists/{list_id}/invites", json={}, headers=ho)).json()["invite_id"]
    assert (await client.post(f"/lists/invites/{i1}/accept", json={}, headers=hm)).status_code == 204
    i2 = (await client.post(f"/lists/{list_id}/invites", json={}, headers=ho)).json()["invite_id"]
    r = await client.post(f"/lists/invites/{i2}/accept", json={}, headers=hm)
    assert r.status_code == 409, (r.status_code, r.text)
    assert "member" in r.text.lower()


@pytest.mark.asyncio
async def test_owner_self_demotion_single_membership_row(client):
    """Owner joining their own list twice: the second accept is a clean 409
    (not a 500, not a duplicate row); self-demotion x2 leaves exactly one
    membership row (Strix hardening item)."""
    to = await register(client, "demown@example.com")
    ho = auth_headers(to)
    list_id = (await client.post("/lists", json={"title": "Dem"}, headers=ho)).json()["id"]
    owner_id = (await client.get("/auth/me", headers=ho)).json()["id"]

    i1 = (await client.post(f"/lists/{list_id}/invites", json={}, headers=ho)).json()["invite_id"]
    assert (await client.post(f"/lists/invites/{i1}/accept", json={}, headers=ho)).status_code == 204
    i2 = (await client.post(f"/lists/{list_id}/invites", json={}, headers=ho)).json()["invite_id"]
    r = await client.post(f"/lists/invites/{i2}/accept", json={}, headers=ho)
    assert r.status_code == 409, (r.status_code, r.text)

    for _ in range(2):
        r = await client.patch(f"/lists/{list_id}/members/{owner_id}",
                               json={"role": "viewer"}, headers=ho)
        assert r.status_code == 200, r.text

    async with SessionLocal() as session:
        result = await session.execute(
            select(ListMember).where(ListMember.list_id == UUID(list_id),
                                     ListMember.user_id == UUID(owner_id)))
        assert len(result.scalars().all()) == 1


@pytest.mark.asyncio
async def test_membership_unique_index_migration():
    """A pre-constraint list_members table (old production DB) must get the
    unique (list_id, user_id) index from the schema migration, so repeated
    joins can never create a duplicate row."""
    from app.main import _ensure_indexes

    async with engine.begin() as conn:
        await conn.execute(text("DROP TABLE IF EXISTS list_members"))
        await conn.execute(text(
            "CREATE TABLE list_members ("
            " id UUID PRIMARY KEY, list_id UUID NOT NULL, user_id UUID NOT NULL,"
            " role VARCHAR(10), created_at TIMESTAMP)"))
    try:
        await _ensure_indexes()
        async with engine.begin() as conn:
            await conn.execute(text(
                "INSERT INTO list_members (id, list_id, user_id, role) VALUES ("
                "'a1b2c3d4-0000-0000-0000-000000000001',"
                "'11111111-0000-0000-0000-000000000001',"
                "'22222222-0000-0000-0000-000000000001', 'viewer')"))
        with pytest.raises(IntegrityError):
            async with engine.begin() as conn:
                await conn.execute(text(
                    "INSERT INTO list_members (id, list_id, user_id, role) VALUES ("
                    "'a1b2c3d4-0000-0000-0000-000000000002',"
                    "'11111111-0000-0000-0000-000000000001',"
                    "'22222222-0000-0000-0000-000000000001', 'editor')"))
    finally:
        async with engine.begin() as conn:
            await conn.execute(text("DROP TABLE IF EXISTS list_members"))
