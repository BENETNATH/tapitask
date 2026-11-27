"""Audit C2.11 — mcp_http add_items : un seul commit de fin + un seul
notify_list par tool call (et non par ligne), validation C1.1b
(null byte, label ≤ 2000) → erreur paramètre JSON-RPC -32602."""

from __future__ import annotations

import asyncio
import json

import pytest
from app.main import app
from httpx import ASGITransport, AsyncClient


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def register(client: AsyncClient, email: str):
    r = await client.post(
        "/auth/register", json={"email": email, "password": "LongPassw0rd!x"}
    )
    assert r.status_code == 201, r.text
    return r.json()


def auth_headers(tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


async def _bridge(email: str, queue):
    from app.db import SessionLocal
    from app.models import User
    from sqlalchemy import select

    from app import mcp_http

    async with SessionLocal() as s:
        user_id = (
            (await s.execute(select(User).where(User.email == email))).scalar_one().id
        )
    mcp_http._sessions["batch"] = mcp_http._Session(user_id=str(user_id), queue=queue)


async def _call(client, h, q, name, arguments, req_id=1):
    r = await client.post(
        "/mcp/messages",
        params={"sessionId": "batch"},
        json={
            "jsonrpc": "2.0",
            "id": req_id,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        },
        headers=h,
    )
    assert r.status_code == 200, r.text
    return await asyncio.wait_for(q.get(), timeout=2.0)


@pytest.mark.asyncio
async def test_add_items_one_commit_one_notify(client, monkeypatch):
    """N lignes → 1 commit + 1 notify_list (et non N commits + N notify)."""
    from sqlalchemy.ext.asyncio import AsyncSession

    commits = []
    original = AsyncSession.commit

    async def spy_commit(self, *a, **k):
        commits.append(1)
        return await original(self, *a, **k)

    monkeypatch.setattr(AsyncSession, "commit", spy_commit)

    import app.events as ev

    notifies = []

    async def spy_notify(*a, **k):
        notifies.append((a, k))

    monkeypatch.setattr(ev, "notify_list", spy_notify)

    tokens = await register(client, "mcpbatch@example.com")
    h = auth_headers(tokens)
    lid = (await client.post("/lists", json={"title": "B"}, headers=h)).json()["id"]
    q = asyncio.Queue()
    await _bridge("mcpbatch@example.com", q)
    try:
        commits.clear()
        notifies.clear()
        reply = await _call(
            client, h, q, "add_items", {"list_id": lid, "text": "thé\nsucre\nlait"}
        )
        assert "error" not in reply, reply
        created = json.loads(reply["result"]["content"][0]["text"])["created"]
        assert len(created) == 3

        items = (await client.get(f"/lists/{lid}/items", headers=h)).json()
        assert {i["label"] for i in items} == {"thé", "sucre", "lait"}
        assert len(commits) == 1, f"{len(commits)} commits (attendu : 1)"
        assert len(notifies) == 1, f"{len(notifies)} notify (attendu : 1)"
    finally:
        from app import mcp_http

        mcp_http._sessions.pop("batch", None)


@pytest.mark.asyncio
async def test_add_items_null_byte_line_is_invalid_param(client, monkeypatch):
    """Ligne avec \x00 (et label > 2000) : rejetée en -32602, rien n'est écrit."""
    import app.events as ev

    async def boom_notify(*a, **k):
        raise AssertionError("aucun notify pour un add_items rejeté")

    monkeypatch.setattr(ev, "notify_list", boom_notify)

    tokens = await register(client, "mcpnull@example.com")
    h = auth_headers(tokens)
    lid = (await client.post("/lists", json={"title": "N"}, headers=h)).json()["id"]
    q = asyncio.Queue()
    await _bridge("mcpnull@example.com", q)
    try:
        reply = await _call(
            client, h, q, "add_items", {"list_id": lid, "text": "ok\nbad\x00line"}
        )
        assert reply.get("error", {}).get("code") == -32602, reply
        items = (await client.get(f"/lists/{lid}/items", headers=h)).json()
        assert items == [], "aucune ligne ne doit être créée si une est invalide"

        reply = await _call(
            client, h, q, "add_items", {"list_id": lid, "text": "x" * 2001}
        )
        assert reply.get("error", {}).get("code") == -32602, reply
    finally:
        from app import mcp_http

        mcp_http._sessions.pop("batch", None)
