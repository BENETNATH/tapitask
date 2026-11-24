"""Audit lot C — sync : outbox jamais bloqué (C1.1a/b/d), sémantique
null=vider (C1.2), collision verify-email (C1.1e).

Note de déviation (signalée au rapport) : la spec C1.1b cite un test
« label 300 chars → rejeté » ; 300 < limite existante (2000, ItemIn), un
label de 300 chars est donc valide et S'APPLIQUE. Les tests couvrent la
limite réelle : > 2000 chars → rejeté.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db import SessionLocal, get_session
from app.main import app
from app.models import Item, User


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def register(
    client: AsyncClient, email: str = "a@example.com", password: str = "LongPassw0rd!x"
):
    r = await client.post("/auth/register", json={"email": email, "password": password})
    assert r.status_code == 201, r.text
    return r.json()


def auth_headers(tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def ts(ms: int = 0) -> str:
    return (datetime.now(timezone.utc) + timedelta(milliseconds=ms)).isoformat()


async def new_list(client, h, title="L") -> str:
    return (await client.post("/lists", json={"title": title}, headers=h)).json()["id"]


def upsert_event(item_id, list_id, **kw) -> dict:
    base = {
        "kind": "item.upsert",
        "id": item_id,
        "list_id": list_id,
        "label": "task",
        "position": 1,
        "updated_at": ts(),
    }
    base.update(kw)
    return base


# ---- C1.1a : label vide -----------------------------------------------


@pytest.mark.asyncio
async def test_new_item_empty_label_is_rejected(client):
    tokens = await register(client, "emptylabel1@example.com")
    h = auth_headers(tokens)
    lid = await new_list(client, h)
    iid = str(uuid.uuid4())

    for label in (None, "   "):
        r = await client.post(
            "/sync", json={"events": [upsert_event(iid, lid, label=label)]}, headers=h
        )
        assert r.status_code == 200, r.text
        assert iid in r.json()["rejected"], f"label={label!r} doit être rejeté"

    items = (await client.get(f"/lists/{lid}/items", headers=h)).json()
    assert items == [], "aucun item ne doit être créé"


@pytest.mark.asyncio
async def test_existing_item_empty_label_keeps_old(client):
    tokens = await register(client, "emptylabel2@example.com")
    h = auth_headers(tokens)
    lid = await new_list(client, h)
    iid = str(uuid.uuid4())

    r = await client.post(
        "/sync",
        json={"events": [upsert_event(iid, lid, label="original", updated_at=ts(10))]},
        headers=h,
    )
    assert r.status_code == 200 and not r.json()["rejected"]

    for label in (None, "  "):
        r = await client.post(
            "/sync",
            json={
                "events": [
                    upsert_event(iid, lid, label=label, done=True, updated_at=ts(200))
                ]
            },
            headers=h,
        )
        assert r.status_code == 200, r.text
        assert iid not in r.json()["rejected"]

    items = (await client.get(f"/lists/{lid}/items", headers=h)).json()
    assert len(items) == 1
    assert items[0]["label"] == "original"
    assert items[0]["done"] is True


# ---- C1.1b : SyncEvent sans validation ne bloque pas l'outbox ----------


@pytest.mark.asyncio
async def test_oversized_label_is_rejected_not_500(client):
    tokens = await register(client, "oversize@example.com")
    h = auth_headers(tokens)
    lid = await new_list(client, h)
    iid = str(uuid.uuid4())

    r = await client.post(
        "/sync", json={"events": [upsert_event(iid, lid, label="x" * 2001)]}, headers=h
    )
    assert r.status_code == 200, r.text
    assert iid in r.json()["rejected"]


@pytest.mark.asyncio
async def test_null_byte_and_field_limits_are_rejected(client):
    tokens = await register(client, "fieldlimits@example.com")
    h = auth_headers(tokens)
    lid = await new_list(client, h)
    iid = str(uuid.uuid4())

    bad_events = [
        upsert_event(iid, lid, label="ok\x00label"),
        upsert_event(iid, lid, color="#" + "A" * 16),  # 17 > 16
        upsert_event(iid, lid, folder="f" * 101),  # > 100
        upsert_event(iid, lid, recurrence="yearly"),  # hors enum
    ]
    for ev in bad_events:
        ev["id"] = str(uuid.uuid4())
        r = await client.post("/sync", json={"events": [ev]}, headers=h)
        assert r.status_code == 200, r.text
        assert ev["id"] in r.json()["rejected"], ev
    assert (await client.get(f"/lists/{lid}/items", headers=h)).json() == []


@pytest.mark.asyncio
async def test_mixed_batch_valid_applied_invalid_rejected_one_commit(client):
    tokens = await register(client, "mixedbatch@example.com")
    h = auth_headers(tokens)
    lid = await new_list(client, h)
    good_id, bad_id = str(uuid.uuid4()), str(uuid.uuid4())

    from app.db import engine

    counts = {"n": 0}

    class SpySession(AsyncSession):
        async def commit(self):
            counts["n"] += 1
            return await super().commit()

    spy_factory = async_sessionmaker(engine, expire_on_commit=False, class_=SpySession)

    async def override():
        async with spy_factory() as s:
            yield s

    app.dependency_overrides[get_session] = override
    try:
        r = await client.post(
            "/sync",
            json={
                "events": [
                    upsert_event(good_id, lid, label="valide"),
                    upsert_event(bad_id, lid, label="y" * 2500),
                ]
            },
            headers=h,
        )
    finally:
        app.dependency_overrides.clear()

    assert r.status_code == 200, r.text
    body = r.json()
    assert bad_id in body["rejected"] and good_id not in body["rejected"]
    assert counts["n"] == 1, "un seul commit de fin de batch"

    items = (await client.get(f"/lists/{lid}/items", headers=h)).json()
    assert [i["id"] for i in items] == [good_id]
    assert items[0]["label"] == "valide"


# ---- C1.1d : _spawn_next concurrent (savepoint, commit=False) ----------


@pytest.mark.asyncio
async def test_sync_spawn_race_savepoint_absorbs_integrity_error(client, monkeypatch):
    """Chemin sync (commit=False) : deux exécutions passent le pre-check ;
    la 2e insertion doit lever IntegrityError DEDANS le savepoint — rollback
    de savepoint + re-check → None, la transaction de batch reste saine."""
    from app.routers.lists import _spawn_next

    tokens = await register(client, "synccomc2@example.com")
    h = auth_headers(tokens)
    lid = await new_list(client, h, "R")
    item = (
        await client.post(
            f"/lists/{lid}/items",
            json={"label": "Course", "recurrence": "weekly"},
            headers=h,
        )
    ).json()[0]
    r = await client.post(
        "/sync",
        json={
            "events": [
                upsert_event(
                    item["id"],
                    lid,
                    label="Course",
                    done=True,
                    recurrence="weekly",
                    updated_at=ts(),
                )
            ]
        },
        headers=h,
    )
    assert r.status_code == 200 and not r.json()["rejected"]

    class _NoRow:
        def scalar_one_or_none(self):
            return None

    async with SessionLocal() as session:
        source = (
            await session.execute(select(Item).where(Item.id == uuid.UUID(item["id"])))
        ).scalar_one()
        real_execute = session.execute
        calls = {"n": 0}

        async def blind_precheck(stmt, *a, **k):
            calls["n"] += 1
            if calls["n"] == 1:  # course perdue : le pre-check ne voit rien
                return _NoRow()
            return await real_execute(stmt, *a, **k)

        monkeypatch.setattr(session, "execute", blind_precheck)
        pending = []
        assert (
            await _spawn_next(
                session, source, source.created_by, commit=False, pending=pending
            )
            is None
        )
        # La transaction du batch est encore saine : commit normal.
        await session.commit()
        from sqlalchemy import func

        count = (
            await session.execute(
                select(func.count())
                .select_from(Item)
                .where(Item.recurrence_source_id == source.id)
            )
        ).scalar_one()
        assert count == 1
        assert pending == []  # aucune notification pour l'occurrence fantôme


# ---- C1.1e : verify-email — collision d'email ---------------------------


@pytest.mark.asyncio
async def test_verify_email_collision_409_and_pending_cleared(client):
    await register(client, "c11ea@example.com")
    async with SessionLocal() as s:
        user_a = (
            await s.execute(select(User).where(User.email == "c11ea@example.com"))
        ).scalar_one()
        user_a.pending_email = "c11eb@example.com"
        user_a.email_token = "token-a"
        await s.commit()

    await register(client, "c11eb@example.com")  # B prend l'email attendu

    r = await client.post("/auth/verify-email", json={"token": "token-a"})
    assert r.status_code == 409, r.text

    async with SessionLocal() as s:
        user_a = (
            await s.execute(select(User).where(User.email == "c11ea@example.com"))
        ).scalar_one()
        assert user_a.pending_email is None, "état périmé nettoyé"
        assert user_a.email == "c11ea@example.com"

    # B n'est pas affecté
    async with SessionLocal() as s:
        user_b = (
            await s.execute(select(User).where(User.email == "c11eb@example.com"))
        ).scalar_one()
        assert user_b.pending_email is None


# ---- C1.2 : null = vider ------------------------------------------------


@pytest.mark.asyncio
async def test_upsert_null_fields_clear(client):
    tokens = await register(client, "c12clear@example.com")
    h = auth_headers(tokens)
    lid = await new_list(client, h)
    parent = (
        await client.post(f"/lists/{lid}/items", json={"label": "parent"}, headers=h)
    ).json()[0]
    member = (
        await client.post(
            f"/lists/{lid}/items",
            json={
                "label": "child",
                "parent_id": parent["id"],
                "due_date": ts(),
                "assignee_id": str(uuid.uuid4()),
                "notes": "n1",
            },
            headers=h,
        )
    ).json()[0]

    # due_date / parent_id / assignee_id / notes → null : tout est vidé.
    r = await client.post(
        "/sync",
        json={
            "events": [
                upsert_event(
                    member["id"],
                    lid,
                    label="child",
                    parent_id=None,
                    due_date=None,
                    assignee_id=None,
                    notes=None,
                    recurrence=None,
                    updated_at=ts(500),
                )
            ]
        },
        headers=h,
    )
    assert r.status_code == 200 and not r.json()["rejected"], r.text

    items = (await client.get(f"/lists/{lid}/items", headers=h)).json()
    child = next(i for i in items if i["id"] == member["id"])
    assert child["due_date"] is None
    assert child["parent_id"] is None
    assert child["assignee_id"] is None
    assert child["notes"] is None
    assert child["recurrence"] == "none"


@pytest.mark.asyncio
async def test_patch_item_null_due_date_clears(client):
    tokens = await register(client, "c12patch@example.com")
    h = auth_headers(tokens)
    lid = await new_list(client, h)
    item = (
        await client.post(
            f"/lists/{lid}/items",
            json={"label": "t", "due_date": ts(), "notes": "keep-me"},
            headers=h,
        )
    ).json()[0]

    r = await client.patch(
        f"/lists/{lid}/items/{item['id']}", json={"due_date": None}, headers=h
    )
    assert r.status_code == 200
    items = (await client.get(f"/lists/{lid}/items", headers=h)).json()
    assert next(i for i in items if i["id"] == item["id"])["due_date"] is None
    # champ absent du body → non touché
    assert next(i for i in items if i["id"] == item["id"])["notes"] == "keep-me"


@pytest.mark.asyncio
async def test_patch_list_null_color_folder_clear(client):
    tokens = await register(client, "c12list@example.com")
    h = auth_headers(tokens)
    lid = (
        await client.post(
            "/lists",
            json={"title": "C", "color": "#AABBCC", "folder": "work"},
            headers=h,
        )
    ).json()
    r = await client.patch(
        f"/lists/{lid['id']}",
        json={"title": "C", "color": None, "folder": None},
        headers=h,
    )
    assert r.status_code == 200
    lists = (await client.get("/lists", headers=h)).json()
    me = next(l for l in lists if l["id"] == lid["id"])
    assert me["color"] is None and me["folder"] is None


@pytest.mark.asyncio
async def test_sync_list_create_null_color_folder_clears(client):
    tokens = await register(client, "c12sync@example.com")
    h = auth_headers(tokens)
    lid = await new_list(client, h, "S")
    await client.patch(
        f"/lists/{lid}",
        json={"title": "S", "color": "#112233", "folder": "f"},
        headers=h,
    )

    r = await client.post(
        "/sync",
        json={
            "events": [
                {
                    "kind": "list.create",
                    "id": lid,
                    "list_id": lid,
                    "label": "S",
                    "color": None,
                    "folder": None,
                    "updated_at": ts(400),
                }
            ]
        },
        headers=h,
    )
    assert r.status_code == 200 and not r.json()["rejected"], r.text
    lists = (await client.get("/lists", headers=h)).json()
    me = next(l for l in lists if l["id"] == lid)
    assert me["color"] is None and me["folder"] is None
    assert me["title"] == "S"
