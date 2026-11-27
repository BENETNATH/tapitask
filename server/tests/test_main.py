from __future__ import annotations

import pytest

from app import main


class FakeConn:
    def __init__(self, log):
        self.log = log

    async def execute(self, stmt):
        self.log.append(getattr(stmt, "text", str(stmt)))

    async def commit(self):
        self.log.append("commit")

    async def run_sync(self, fn):
        self.log.append("create_all")  # sans appeler fn (pas de vrai DB)


class FakeCtx:
    def __init__(self, conn):
        self.conn = conn

    async def __aenter__(self):
        return self.conn

    async def __aexit__(self, *exc):
        return False


class FakeEngine:
    dialect = type("D", (), {"name": "postgresql"})

    def __init__(self):
        self.log = []

    def connect(self):
        return FakeCtx(FakeConn(self.log))

    def begin(self):
        return FakeCtx(FakeConn(self.log))


@pytest.mark.asyncio
async def test_advisory_lock_held_during_init(monkeypatch):
    """Le lock advisory est session-scoped : un commit entre lock et unlock le
    libérait AVANT create_all — la serialisation inter-workers n'existait pas
    (audit run-2, main._init_schema)."""
    engine = FakeEngine()
    monkeypatch.setattr(main, "engine", engine)

    async def record(name):
        engine.log.append(name)

    monkeypatch.setattr(main, "_ensure_columns", lambda: record("ensure_columns"))
    monkeypatch.setattr(main, "_ensure_indexes", lambda: record("ensure_indexes"))

    await main._init_schema()

    log = engine.log
    lock = log.index("SELECT pg_advisory_lock(918273645)")
    create = log.index("create_all")
    unlock = log.index("SELECT pg_advisory_unlock(918273645)")
    assert lock < create < unlock
    assert "commit" not in log[lock:unlock], log


@pytest.mark.asyncio
async def test_ensure_indexes_recreates_changelog_server_time(tmp_path, monkeypatch):
    """/admin/audit trie sur server_time SANS filtre list_id : l'index
    composite ix_changelog_list_time est inutilisable pour ce tri. Un index
    dédié doit être (re)créé par _ensure_indexes — les bases déjà déployées
    n'ont que ce DDL, __table_args__ ne jouant qu'à create_all."""
    from app.db import Base
    from sqlalchemy import text
    from sqlalchemy.ext.asyncio import create_async_engine

    test_engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'idx.sqlite'}")
    try:
        async with test_engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
            # Simule une base déployée sans l'index : on le retire pour
            # forcer _ensure_indexes à le recréer.
            await conn.execute(text("DROP INDEX IF EXISTS ix_changelog_server_time"))
        monkeypatch.setattr(main, "engine", test_engine)
        await main._ensure_indexes()
        async with test_engine.connect() as conn:
            rows = (
                await conn.execute(text("PRAGMA index_list('change_log')"))
            ).fetchall()
    finally:
        await test_engine.dispose()
    names = [r[1] for r in rows]
    assert "ix_changelog_server_time" in names, names


@pytest.mark.asyncio
async def test_ensure_columns_idempotent_duplicate_column(tmp_path, monkeypatch):
    """sqlite : « duplicate column » reste avalé — re-courir toutes les
    migrations sur un schéma déjà complet (idempotence, workers
    concurrents) ne doit pas lever."""
    from app.db import Base
    from app.models import User
    from sqlalchemy.ext.asyncio import (
        async_sessionmaker,
        create_async_engine,
    )

    test_engine = create_async_engine(
        f"sqlite+aiosqlite:///{tmp_path / 'ensure_cols.sqlite'}"
    )
    try:
        async with test_engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        async with async_sessionmaker(test_engine)() as s:
            s.add(User(email="a@b.c", password_hash="h"))
            await s.commit()
        monkeypatch.setattr(main, "engine", test_engine)
        await main._ensure_columns()  # pas d'exception attendue
    finally:
        await test_engine.dispose()


@pytest.mark.asyncio
async def test_ensure_columns_invalid_ddl_raises(tmp_path, monkeypatch):
    """sqlite : une vraie panne DDL (NOT NULL sans défaut sur table non
    vide) DOIT remonter — avant le fix, `except Exception: pass` avalait
    aussi ça (pas seulement « colonne déjà existante »)."""
    from app.db import Base
    from app.models import User
    from sqlalchemy.exc import OperationalError
    from sqlalchemy.ext.asyncio import (
        async_sessionmaker,
        create_async_engine,
    )

    test_engine = create_async_engine(
        f"sqlite+aiosqlite:///{tmp_path / 'ensure_cols_bad.sqlite'}"
    )
    try:
        async with test_engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        async with async_sessionmaker(test_engine)() as s:
            s.add(User(email="a@b.c", password_hash="h"))
            await s.commit()
        monkeypatch.setattr(main, "engine", test_engine)
        monkeypatch.setattr(
            main,
            "MIGRATIONS",
            [("users", "bad_col", "VARCHAR(10) NOT NULL", "VARCHAR(10) NOT NULL")],
        )
        with pytest.raises(OperationalError, match="Cannot add a NOT NULL column"):
            await main._ensure_columns()
    finally:
        await test_engine.dispose()
