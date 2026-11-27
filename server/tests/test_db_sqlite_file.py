"""F1 (spec 2026-11-25, D-3) : SQLite FICHIER — PRAGMA journal_mode=WAL +
busy_timeout (10 s) au connect (engine event) ; :memory: conserve le
StaticPool (inchangé — tests) sans WAL."""

from __future__ import annotations

import pytest
from app.db import create_sqlite_engine
from sqlalchemy import text
from sqlalchemy.pool import StaticPool


@pytest.mark.asyncio
async def test_sqlite_file_engine_wal_and_busy_timeout(tmp_path):
    engine = create_sqlite_engine(f"sqlite+aiosqlite:///{tmp_path / 't.db'}")
    try:
        async with engine.connect() as conn:
            mode = (await conn.execute(text("PRAGMA journal_mode"))).scalar_one()
            assert mode == "wal"
            timeout = (await conn.execute(text("PRAGMA busy_timeout"))).scalar_one()
            assert timeout > 0, "busy_timeout doit être posé au connect"
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_memory_engine_keeps_static_pool_and_no_wal():
    engine = create_sqlite_engine("sqlite+aiosqlite:///:memory:")
    try:
        assert isinstance(engine.pool, StaticPool), (
            ":memory: doit conserver le StaticPool (tests)"
        )
        async with engine.connect() as conn:
            mode = (await conn.execute(text("PRAGMA journal_mode"))).scalar_one()
            assert mode == "memory", ":memory: ne passe pas en WAL"
    finally:
        await engine.dispose()
