"""Audit C2.10 (A4) — due_date : le DDL de migration passe à TIMESTAMPTZ,
et un one-shot convertit les bases réellement migrées depuis v1
(`timestamp without time zone` → TIMESTAMPTZ AT TIME ZONE 'UTC').
Le one-shot est idempotent par nature : il lit information_schema, et son
effet (le changement de type) fait disparaître sa condition — pas de
registre d'état. Sur SQLite, no-op (le dialecte n'a pas de TZ).
"""

from __future__ import annotations

import pytest


def test_migration_entry_is_timestamptz():
    from app.main import MIGRATIONS

    entry = next(m for m in MIGRATIONS if m[0] == "items" and m[1] == "due_date")
    assert entry[3] == "TIMESTAMPTZ", "le DDL postgres doit être TIMESTAMPTZ"


@pytest.mark.parametrize(
    "data_type, expected",
    [
        ("timestamp without time zone", "ALTER"),  # base migrée v1 : convertir
        ("timestamp with time zone", None),  # déjà correct : no-op
        (None, None),  # colonne absente : no-op
    ],
)
def test_timestamptz_decision(data_type, expected):
    from app.main import _due_date_timestamptz_sql

    sql = _due_date_timestamptz_sql(data_type)
    if expected is None:
        assert sql is None
    else:
        assert "TIMESTAMPTZ" in sql
        assert "AT TIME ZONE 'UTC'" in sql


@pytest.mark.asyncio
async def test_ensure_columns_sqlite_noop():
    """Sur SQLite le one-shot est sauté (pas d'information_schema) : pas
    d'erreur, la colonne due_date reste utilisable (base fresh create_all)."""
    import uuid

    from sqlalchemy import inspect, select

    from app.db import SessionLocal, engine
    from app.main import _ensure_columns
    from app.models import Checklist, Item, User, utcnow

    await _ensure_columns()

    uid, lid = uuid.uuid4(), uuid.uuid4()
    async with SessionLocal() as s:
        s.add(User(id=uid, email="tz@e.com", password_hash="h"))
        s.add(Checklist(id=lid, owner_id=uid, title="T"))
        s.add(Item(id=uuid.uuid4(), list_id=lid, label="x", due_date=utcnow()))
        await s.commit()

    async with SessionLocal() as s:
        row = (
            await s.execute(select(Item.due_date).where(Item.list_id == lid))
        ).first()
    assert row[0] is not None, "due_date conservée (UTC) après le one-shot no-op"

    def col_type(sync_conn):
        insp = inspect(sync_conn)
        return [c["type"] for c in insp.get_columns("items") if c["name"] == "due_date"]

    async with engine.connect() as conn:
        types = await conn.run_sync(col_type)
    assert types, "la colonne due_date existe"
